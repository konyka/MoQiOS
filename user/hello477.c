/* hello477: SO_TIMESTAMP and SO_TIMESTAMPNS on AF_UNIX sockets (Linux unix_dgram_recvmsg and unix_seqpacket_recvmsg call
 * sock_recv_cmsgs before scm_recv_unix; unix_stream_read_generic does not). Measured on the host (build with -DHOST):
 *   A. a datagram socketpair with SO_TIMESTAMP: a datagram brings one SOL_SOCKET / SCM_TIMESTAMP (29) of cmsg_len 32 with the
 *      current time;
 *   B. with SO_TIMESTAMPNS instead: SCM_TIMESTAMPNS (35);
 *   C. a stream socketpair with SO_TIMESTAMP: no control message;
 *   D. a seqpacket socketpair with SO_TIMESTAMP: SCM_TIMESTAMP;
 *   E. a datagram queued before SO_TIMESTAMP was set still brings one;
 *   F. SO_TIMESTAMP and SO_PASSCRED together: SCM_TIMESTAMP first, then SCM_CREDENTIALS (2, cmsg_len 28), controllen 64. */
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
static long now_s(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return t.tv_sec; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long pair_(int type, int *sv) { return syscall4(128, 1, type, 0, (long)sv); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long write_(long s, const void *b, long n) { return syscall3(1, s, (long)b, n); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static long now_s(void) { long t[2] = { 0, 0 }; syscall2(228, 0, (long)t); return t[0]; }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello477:   ok   " : "hello477:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long clen;
static int n_cm, cm_ty[4];
static long cm_len[4], cm_sec;
static long rcv(long s) {
    static unsigned char ctl[128];
    char d[16];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    memset(ctl, 0, sizeof ctl);
    long iov[2] = { (long)d, sizeof d };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    long r = recvmsg_(s, mh, 0x40);
    memcpy(&clen, mh + 40, 8);
    n_cm = 0;
    cm_sec = 0;
    for (long off = 0; r >= 0 && off + 16 <= clen && n_cm < 4;) {
        long len; int ty;
        memcpy(&len, ctl + off, 8); memcpy(&ty, ctl + off + 12, 4);
        if (len < 16) break;
        if (n_cm == 0 && len >= 24) memcpy(&cm_sec, ctl + off + 16, 8);
        cm_ty[n_cm] = ty;
        cm_len[n_cm] = len;
        n_cm++;
        off += (len + 7) & ~7L;
    }
    return r;
}
static int recent(void) { long n = now_s(); return cm_sec > 0 && cm_sec <= n && cm_sec >= n - 5; }
int main(void) {
    print("hello477: SO_TIMESTAMP on AF_UNIX sockets\n");
    int one = 1;
    int d[2], st[2], sp[2], e[2];
    long p1 = pair_(2, d);
    setopt_(d[1], 1, 29, &one, 4);
    write_(d[0], "a", 1);
    long a1 = rcv(d[1]);
    int a_ok = a1 == 1 && n_cm == 1 && cm_ty[0] == 29 && cm_len[0] == 32 && recent();
    snprintf(msg, sizeof msg, "A: datagram pair %ld; read %ld, %d messages, type %d len %ld, time recent %d (0 1 1 29 32 1)", p1, a1, n_cm, n_cm ? cm_ty[0] : -1, n_cm ? cm_len[0] : -1, recent());
    check(p1 == 0 && a_ok, msg);

    setopt_(d[1], 1, 35, &one, 4);
    write_(d[0], "b", 1);
    long b1 = rcv(d[1]);
    snprintf(msg, sizeof msg, "B: SO_TIMESTAMPNS: read %ld, type %d (1 35)", b1, n_cm ? cm_ty[0] : -1);
    check(b1 == 1 && n_cm == 1 && cm_ty[0] == 35, msg);

    long p2 = pair_(1, st);
    setopt_(st[1], 1, 29, &one, 4);
    write_(st[0], "c", 1);
    long c1 = rcv(st[1]);
    snprintf(msg, sizeof msg, "C: stream pair %ld; read %ld, controllen %ld (0 1 0)", p2, c1, clen);
    check(p2 == 0 && c1 == 1 && clen == 0, msg);

    long p3 = pair_(5, sp);
    setopt_(sp[1], 1, 29, &one, 4);
    write_(sp[0], "d", 1);
    long d1 = rcv(sp[1]);
    snprintf(msg, sizeof msg, "D: seqpacket pair %ld; read %ld, type %d (0 1 29)", p3, d1, n_cm ? cm_ty[0] : -1);
    check(p3 == 0 && d1 == 1 && n_cm == 1 && cm_ty[0] == 29, msg);

    pair_(2, e);
    write_(e[0], "e", 1);
    setopt_(e[1], 1, 29, &one, 4);
    long e1 = rcv(e[1]);
    snprintf(msg, sizeof msg, "E: queued before SO_TIMESTAMP: read %ld, type %d, time recent %d (1 29 1)", e1, n_cm ? cm_ty[0] : -1, recent());
    check(e1 == 1 && n_cm == 1 && cm_ty[0] == 29 && recent(), msg);

    setopt_(e[1], 1, 16, &one, 4);
    write_(e[0], "f", 1);
    long f1 = rcv(e[1]);
    snprintf(msg, sizeof msg, "F: with SO_PASSCRED: read %ld, controllen %ld, types %d %d, lens %ld %ld (1 64 29 2 32 28)", f1, clen, n_cm > 0 ? cm_ty[0] : -1, n_cm > 1 ? cm_ty[1] : -1,
             n_cm > 0 ? cm_len[0] : -1, n_cm > 1 ? cm_len[1] : -1);
    check(f1 == 1 && clen == 64 && n_cm == 2 && cm_ty[0] == 29 && cm_ty[1] == 2 && cm_len[0] == 32 && cm_len[1] == 28, msg);

    print(failures ? "hello477: FAIL\n" : "hello477: PASS\n");
    return failures ? 1 : 0;
}
