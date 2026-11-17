/* hello406: ICMP errors for TCP (Linux tcp_v4_err, tcp_v6_err, icmp_err_convert, icmpv6_err_convert, sock_getsockopt SO_ERROR).
 * An error that quotes a segment of a connection still in SYN_SENT ends it: connect fails with the error's errno (net unreachable
 * ENETUNREACH, host unreachable EHOSTUNREACH, port unreachable ECONNREFUSED, protocol unreachable ENOPROTOOPT, time exceeded
 * EHOSTUNREACH, parameter problem EPROTO; for ICMPv6 no route ENETUNREACH, administratively prohibited EACCES, address unreachable
 * EHOSTUNREACH, port unreachable ECONNREFUSED, time exceeded EHOSTUNREACH, parameter problem EPROTO, an unknown code EPROTO). One
 * whose quoted sequence number is outside [snd_una, snd_nxt] is ignored, and so are fragmentation needed and packet too big (path
 * MTU only), source quench, redirect and destination unreachable codes past 15. On an established connection the error is soft:
 * SO_ERROR reports it once and the connection goes on. To keep this host from answering the SYN with a RST, it goes to a listener
 * whose accept queue is full, which drops it on both systems. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with only lo up):
 *   E. IPv4, one connect per error: SO_ERROR and POLLERR as listed above;
 *   I. IPv4: a port unreachable quoting sequence ISN-1 or ISN+1000, fragmentation needed, source quench, redirect and code 16 leave
 *      the connect pending (SO_ERROR 0, no POLLERR); ISN+1 (snd_nxt) counts;
 *   B. a blocking connect answered with host unreachable returns EHOSTUNREACH;
 *   S. an established connection gets a host unreachable quoting its last segment: SO_ERROR reads 113 once, then 0, and data still
 *      flows both ways;
 *   V. IPv6, one connect per error, as listed; packet too big and a sequence number past snd_nxt leave it pending. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, a, (socklen_t *)al)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static long poll_ev(long s) { struct pollfd p = { (int)s, POLLIN | POLLOUT, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : p.revents; }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
static long fork_(void) { return fork(); }
static void wait_(long pid) { int st = 0; waitpid((pid_t)pid, &st, 0); }
static void exit_(int c) { _exit(c); }
#define NONBLOCK SOCK_NONBLOCK
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return syscall6(122, s, (long)b, n, 0x40, (long)a, (long)al); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long poll_ev(long s) { struct { int fd; short ev, rev; } p = { (int)s, 1 | 4, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
static long fork_(void) { return syscall0(57); }
static void wait_(long pid) { int st = 0; syscall3(6, pid, (long)&st, 0); }
static void exit_(int c) { syscall1(2, c); }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[1200];
static void check(int ok, const char *w) {
    print(ok ? "hello406:   ok   " : "hello406:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char seg[1600];
static long rt4, rr4, rt6, ri6;
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static void mk6(unsigned char *a, int port) {
    memset(a, 0, 28);
    a[0] = 10;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[23] = 1;
}
static int soerr(long s) { int e = -7; int l = 4; long r = getopt_(s, 1, 4, &e, &l); return r < 0 ? (int)r : e; }
/* The first segment the raw TCP socket `r` sees to port `dport` (with SYN when `syn`): its length, the IP header included for v4. */
static long grab(long r, int v6, int dport, int syn) {
    unsigned char a[28];
    for (int k = 0; k < 150; k++) {
        int l = 28;
        long n = recvfrom_(r, seg, sizeof seg, a, &l);
        if (n < 0) { nap(); continue; }
        int off = v6 ? 0 : (seg[0] & 15) * 4;
        if ((seg[off + 2] << 8 | seg[off + 3]) != dport) continue;
        if (syn && !(seg[off + 13] & 2)) continue;
        return n;
    }
    return -1;
}
static void drain(long r) { unsigned char a[28]; int l = 28; while (recvfrom_(r, seg, sizeof seg, a, &l) >= 0) l = 28; }
static void bump(unsigned char *p, int delta) {
    unsigned int q = (unsigned int)(p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]) + (unsigned int)delta;
    p[0] = (unsigned char)(q >> 24); p[1] = (unsigned char)(q >> 16); p[2] = (unsigned char)(q >> 8); p[3] = (unsigned char)q;
}
/* An ICMP error of `type`/`code` 127.0.0.1 -> 127.0.0.1 quoting the IP header and 8 bytes of the segment in `seg`, its sequence
 * number moved by `delta`, sent whole through the IPPROTO_RAW socket. */
static void icmp4(int type, int code, int delta) {
    int ihl = (seg[0] & 15) * 4, ql = ihl + 8, tot = 28 + ql;
    unsigned char p[120];
    memset(p, 0, sizeof p);
    p[0] = 0x45; p[2] = (unsigned char)(tot >> 8); p[3] = (unsigned char)tot; p[8] = 64; p[9] = 1;
    p[12] = 127; p[15] = 1; p[16] = 127; p[19] = 1;
    p[20] = (unsigned char)type; p[21] = (unsigned char)code;
    if (type == 3 && code == 4) p[27] = 0xc8; /* next-hop MTU 1480 */
    memcpy(p + 28, seg, (unsigned long)ql);
    bump(p + 28 + ihl + 4, delta);
    unsigned int s = 0;
    for (int i = 20; i < tot; i += 2) s += (unsigned int)(p[i] << 8 | (i + 1 < tot ? p[i + 1] : 0));
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    s = ~s & 0xffff;
    p[22] = (unsigned char)(s >> 8); p[23] = (unsigned char)s;
    unsigned char d[16];
    mk4(d, 0);
    sendto_(rr4, p, tot, d, 16);
}
/* An ICMPv6 error ::1 -> ::1 quoting the IPv6 header and the TCP header in `seg` (`n` bytes), sequence moved by `delta`; the
 * kernel fills the checksum. */
static void icmp6(int type, int code, int delta, long n) {
    unsigned char p[120];
    memset(p, 0, sizeof p);
    p[0] = (unsigned char)type; p[1] = (unsigned char)code;
    if (type == 2) { p[6] = 0x05; p[7] = 0x00; } /* MTU 1280 */
    unsigned char *h = p + 8;
    h[0] = 0x60; h[5] = (unsigned char)n; h[6] = 6; h[7] = 64; h[23] = 1; h[39] = 1;
    int ql = n < 20 ? (int)n : 20;
    memcpy(h + 40, seg, (unsigned long)ql);
    bump(h + 44, delta);
    unsigned char d[28];
    mk6(d, 0);
    sendto_(ri6, p, 48 + ql, d, 28);
}
/* A listener on `port` whose accept queue is full (backlog 1: one queued child), so a new SYN gets no answer. */
static long full_listener(int v6, int port, long *child) {
    long l = sock(v6 ? 10 : 2, 1, 0);
    unsigned char a[28];
    if (v6) mk6(a, port); else mk4(a, port);
    bind_(l, a, v6 ? 28 : 16);
    listen_(l, 1);
    for (int i = 0; i < 2; i++) {
        child[i] = sock(v6 ? 10 : 2, 1 | NONBLOCK, 0);
        connect_(child[i], a, v6 ? 28 : 16);
    }
    for (int i = 0; i < 10; i++) nap();
    return l;
}
static long start(int v6, int port, long *n) {
    long s = sock(v6 ? 10 : 2, 1 | NONBLOCK, 0);
    unsigned char a[28];
    if (v6) mk6(a, port); else mk4(a, port);
    drain(v6 ? rt6 : rt4);
    connect_(s, a, v6 ? 28 : 16);
    *n = grab(v6 ? rt6 : rt4, v6, port, 1);
    return s;
}
static void settle(void) { for (int i = 0; i < 3; i++) nap(); }
int main(void) {
    print("hello406: ICMP errors for TCP\n");
    rt4 = sock(2, 3, 6); rr4 = sock(2, 3, 255); rt6 = sock(10, 3, 6); ri6 = sock(10, 3, 58);
    long kids[2], kids6[2];
    long L = full_listener(0, 40406, kids);
    long L6 = full_listener(1, 40407, kids6);

    static const int e4[][3] = { { 3, 0, 101 }, { 3, 1, 113 }, { 3, 2, 92 }, { 3, 3, 111 }, { 3, 13, 113 }, { 3, 15, 113 }, { 11, 0, 113 }, { 12, 0, 71 } };
    int ok = rt4 >= 0 && rr4 >= 0 && L >= 0;
    int at = snprintf(msg, sizeof msg, "E:");
    for (int i = 0; i < 8; i++) {
        long n;
        long s = start(0, 40406, &n);
        icmp4(e4[i][0], e4[i][1], 1);
        settle();
        long pe = poll_ev(s);
        int se = soerr(s), se2 = soerr(s);
        if (n < 0 || se != e4[i][2] || !(pe & 8) || se2 != 0) ok = 0;
        at += snprintf(msg + at, sizeof msg - (unsigned long)at, " %d/%d SO_ERROR %d then %d POLLERR %d (%d);", e4[i][0], e4[i][1], se, se2, (int)((pe & 8) != 0), e4[i][2]);
        close_(s);
    }
    check(ok, msg);

    static const int ig[][3] = { { 3, 3, -1 }, { 3, 3, 1000 }, { 3, 4, 0 }, { 4, 0, 0 }, { 5, 1, 0 }, { 3, 16, 0 } };
    ok = 1;
    at = snprintf(msg, sizeof msg, "I:");
    for (int i = 0; i < 6; i++) {
        long n;
        long s = start(0, 40406, &n);
        icmp4(ig[i][0], ig[i][1], ig[i][2]);
        settle();
        long pe = poll_ev(s);
        int se = soerr(s);
        if (n < 0 || se != 0 || (pe & 8)) ok = 0;
        at += snprintf(msg + at, sizeof msg - (unsigned long)at, " %d/%d seq%+d SO_ERROR %d POLLERR %d;", ig[i][0], ig[i][1], ig[i][2], se, (int)((pe & 8) != 0));
        close_(s);
    }
    check(ok, msg);

    drain(rt4);
    long pid = fork_();
    if (pid == 0) {
        if (grab(rt4, 0, 40406, 1) >= 0) icmp4(3, 1, 1);
        exit_(0);
    }
    long bs = sock(2, 1, 0);
    unsigned char ba[16];
    mk4(ba, 40406);
    long br = connect_(bs, ba, 16);
    wait_(pid);
    int bse = soerr(bs);
    snprintf(msg, sizeof msg, "B: a blocking connect answered with host unreachable returns %ld, SO_ERROR then %d (-113 0)", br, bse);
    check(br == -113 && bse == 0, msg);
    close_(bs);

    long sl = sock(2, 1, 0);
    unsigned char sa[16];
    mk4(sa, 40408);
    bind_(sl, sa, 16);
    listen_(sl, 4);
    drain(rt4);
    long sc = sock(2, 1, 0);
    long scr = connect_(sc, sa, 16);
    long sp = accept_(sl);
    long sh = -1;
    for (int k = 0; k < 30 && sh < 0; k++) {
        long n = grab(rt4, 0, 40408, 0);
        if (n < 0) break;
        int off = (seg[0] & 15) * 4;
        if (!(seg[off + 13] & 2)) sh = n;
    }
    icmp4(3, 1, 0);
    settle();
    int s1 = soerr(sc), s2 = soerr(sc);
    long w = sendto_(sc, "ping", 4, 0, 0);
    settle();
    unsigned char rb[16];
    int rl = 0;
    long g = recvfrom_(sp, rb, sizeof rb, 0, &rl);
    long w2 = sendto_(sp, "pong", 4, 0, 0);
    settle();
    long g2 = recvfrom_(sc, rb, sizeof rb, 0, &rl);
    snprintf(msg, sizeof msg, "S: connect %ld accept %d; host unreachable quoting the last segment (%ld): SO_ERROR %d then %d; send %ld, peer got %ld; reply %ld, got %ld (0 1 1 113 0 4 4 4 4)",
             scr, sp >= 0, sh, s1, s2, w, g, w2, g2);
    check(scr == 0 && sp >= 0 && sh > 0 && s1 == 113 && s2 == 0 && w == 4 && g == 4 && w2 == 4 && g2 == 4, msg);
    close_(sc); close_(sp); close_(sl);

    static const int e6[][4] = { { 1, 4, 0, 111 }, { 1, 0, 0, 101 }, { 1, 3, 0, 113 }, { 1, 1, 0, 13 }, { 3, 0, 0, 113 }, { 4, 0, 0, 71 }, { 1, 7, 0, 71 }, { 2, 0, 0, 0 }, { 1, 4, 1000, 0 } };
    ok = rt6 >= 0 && ri6 >= 0 && L6 >= 0;
    at = snprintf(msg, sizeof msg, "V:");
    for (int i = 0; i < 9; i++) {
        long n;
        long s = start(1, 40407, &n);
        icmp6(e6[i][0], e6[i][1], e6[i][2] + 1, n);
        settle();
        long pe = poll_ev(s);
        int se = soerr(s);
        int want_err = e6[i][3] != 0;
        if (n < 0 || se != e6[i][3] || ((pe & 8) != 0) != want_err) ok = 0;
        at += snprintf(msg + at, sizeof msg - (unsigned long)at, " %d/%d seq%+d SO_ERROR %d POLLERR %d (%d);", e6[i][0], e6[i][1], e6[i][2] + 1, se, (int)((pe & 8) != 0), e6[i][3]);
        close_(s);
    }
    check(ok, msg);

    close_(kids[0]); close_(kids[1]); close_(L);
    close_(kids6[0]); close_(kids6[1]); close_(L6);
    close_(rt4); close_(rr4); close_(rt6); close_(ri6);
    print(failures == 0 ? "hello406: PASS\n" : "hello406: FAIL\n");
    return failures == 0 ? 0 : 1;
}
