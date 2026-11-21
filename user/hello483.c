/* hello483: every queued AF_UNIX record keeps its arrival time (Linux unix_dgram_sendmsg / unix_seqpacket_sendmsg: __net_timestamp
 * on each skb when the receiver has SOCK_RCVTSTAMP; sock_recv_timestamp reports it). The kernel kept only the oldest 64 times and
 * stamped later records when they were read. Measured on the host (build with -DHOST):
 *   A. a datagram socketpair with SO_TIMESTAMPNS: 100 one-byte datagrams are queued, the test sleeps 200 ms and reads them all; each
 *      brings SCM_TIMESTAMPNS with a time before the reading started, in non-decreasing order;
 *   B. the same on a seqpacket socketpair (64 records here: its ring holds fewer small records than a datagram socket);
 *   C. MSG_PEEK on the 70th of 100 queued datagrams (after 69 were read) reports the same time as the read that follows;
 *   D. a datagram (and a seqpacket record) sent before the receiver set SO_TIMESTAMPNS has no stamp: the read reports the time of the
 *      read (__sock_recv_timestamp takes the current time for an skb without one);
 *   E. seqpacket over a listener: a record sent after connect but before accept, then (after accept, with SO_TIMESTAMPNS on the
 *      accepted socket) a second one; 200 ms later the first reads with the time of the read, the second with its send time. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long pair_(int type, int *sv) { return rc(socketpair(1, type, 0, sv)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long write_(long s, const void *b, long n) { return rc(write((int)s, b, (size_t)n)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static long now_ns(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return t.tv_sec * 1000000000L + t.tv_nsec; }
static void nap(void) { usleep(200000); }
static void close_(long s) { close((int)s); }
static long sock_(int t) { return rc(socket(1, t, 0)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s) { return rc(listen((int)s, 4)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static void unlink_(const char *p) { unlink(p); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long pair_(int type, int *sv) { return syscall4(128, 1, type, 0, (long)sv); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long write_(long s, const void *b, long n) { return syscall3(1, s, (long)b, n); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static long now_ns(void) { long t[2] = { 0, 0 }; syscall2(228, 0, (long)t); return t[0] * 1000000000L + t[1]; }
static void nap(void) { long t[2] = { 0, 200000000 }; syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
static long sock_(int t) { return syscall3(117, 1, t, 0); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s) { return syscall2(119, s, 4); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static void unlink_(const char *p) { syscall1(SYS_unlink, (long)p); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello483:   ok   " : "hello483:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int cm_ty;
static long cm_ns;
static long rcv(long s, int flags) {
    static unsigned char ctl[128];
    char d[16];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    memset(ctl, 0, sizeof ctl);
    long iov[2] = { (long)d, sizeof d };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    long r = recvmsg_(s, mh, 0x40 | flags);
    long clen;
    memcpy(&clen, mh + 40, 8);
    cm_ty = -1;
    cm_ns = 0;
    if (r >= 0 && clen >= 32) {
        long sec, nsec;
        memcpy(&cm_ty, ctl + 12, 4);
        memcpy(&sec, ctl + 16, 8);
        memcpy(&nsec, ctl + 24, 8);
        cm_ns = sec * 1000000000L + nsec;
    }
    return r;
}
/* Queue n records on sv[0] -> sv[1], sleep, read them all. Returns how many came with a stamp from before the reading started, in
 * order; *first_bad the index of the first that did not (-1). */
static int run(int type, int n, int *first_bad, long *bad_ns, long *read_at) {
    int sv[2], one = 1;
    if (pair_(type, sv) != 0) return -1;
    setopt_(sv[1], 1, 35, &one, 4);
    long before = now_ns();
    for (int i = 0; i < n; i++) write_(sv[0], "x", 1);
    nap();
    long start = now_ns();
    *read_at = start - before;
    int good = 0;
    long prev = 0;
    *first_bad = -1;
    for (int i = 0; i < n; i++) {
        long r = rcv(sv[1], 0);
        int ok = r == 1 && cm_ty == 35 && cm_ns >= before - 1000000 && cm_ns < start && cm_ns >= prev;
        if (ok) good++;
        else if (*first_bad < 0) { *first_bad = i; *bad_ns = cm_ns - before; }
        prev = cm_ns;
    }
    close_(sv[0]);
    close_(sv[1]);
    return good;
}
int main(void) {
    print("hello483: every queued AF_UNIX record keeps its arrival time\n");
    int bad;
    long bad_ns = 0, at = 0;
    int g = run(2, 100, &bad, &bad_ns, &at);
    snprintf(msg, sizeof msg, "A: datagrams stamped before the read %d of 100 (100); first bad %d at +%ld ns, read at +%ld ns", g, bad, bad_ns, at);
    check(g == 100, msg);
    g = run(5, 64, &bad, &bad_ns, &at);
    snprintf(msg, sizeof msg, "B: seqpacket records stamped before the read %d of 64 (64); first bad %d at +%ld ns", g, bad, bad_ns);
    check(g == 64, msg);

    int sv[2], one = 1;
    pair_(2, sv);
    setopt_(sv[1], 1, 35, &one, 4);
    long before = now_ns();
    for (int i = 0; i < 100; i++) write_(sv[0], "y", 1);
    nap();
    long start = now_ns();
    for (int i = 0; i < 69; i++) rcv(sv[1], 0);
    long pk = rcv(sv[1], 2);
    long peek_ns = cm_ns;
    long rd = rcv(sv[1], 0);
    snprintf(msg, sizeof msg, "C: peek %ld, read %ld, same time %d, before the read %d (1 1 1 1)", pk, rd, peek_ns == cm_ns, peek_ns >= before && peek_ns < start);
    check(pk == 1 && rd == 1 && peek_ns == cm_ns && peek_ns >= before && peek_ns < start, msg);
    close_(sv[0]);
    close_(sv[1]);
    for (int k = 0; k < 2; k++) {
        int type = k ? 5 : 2;
        pair_(type, sv);
        write_(sv[0], "z", 1);
        nap();
        setopt_(sv[1], 1, 35, &one, 4);
        long t1 = now_ns();
        long r = rcv(sv[1], 0);
        long t2 = now_ns();
        snprintf(msg, sizeof msg, "D: %s sent before SO_TIMESTAMPNS: read %ld, type %d, stamped at the read %d (1 35 1)", k ? "seqpacket" : "datagram", r, cm_ty,
                 cm_ns >= t1 - 1000000 && cm_ns <= t2 + 1000000);
        check(r == 1 && cm_ty == 35 && cm_ns >= t1 - 1000000 && cm_ns <= t2 + 1000000, msg);
        close_(sv[0]);
        close_(sv[1]);
    }

    struct { unsigned short fam; char path[30]; } addr = { 1, "/tmp/hello483.sock" };
    unlink_(addr.path);
    long l = sock_(5);
    long b = bind_(l, &addr, sizeof addr);
    long li = listen_(l);
    long c = sock_(5);
    long cn = connect_(c, &addr, sizeof addr);
    write_(c, "1", 1);
    long a = accept_(l);
    setopt_(a, 1, 35, &one, 4);
    long sent2 = now_ns();
    write_(c, "2", 1);
    nap();
    long t1 = now_ns();
    long r1 = rcv(a, 0);
    long ns1 = cm_ns;
    long r2 = rcv(a, 0);
    long ns2 = cm_ns;
    int first_at_read = ns1 >= t1 - 1000000;
    int second_at_send = ns2 >= sent2 - 1000000 && ns2 < t1;
    snprintf(msg, sizeof msg, "E: bind %ld listen %ld connect %ld accept %d; reads %ld %ld, first at the read %d, second at its send %d (0 0 0 1 1 1 1 1)", b, li, cn, a >= 0,
             r1, r2, first_at_read, second_at_send);
    check(b == 0 && li == 0 && cn == 0 && a >= 0 && r1 == 1 && r2 == 1 && first_at_read && second_at_send, msg);
    close_(a);
    close_(c);
    close_(l);
    unlink_(addr.path);
    print(failures ? "hello483: FAIL\n" : "hello483: PASS\n");
    return failures ? 1 : 0;
}
