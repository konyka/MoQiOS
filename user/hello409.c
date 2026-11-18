/* hello409: zero-window probes and TCP_USER_TIMEOUT (Linux tcp_probe_timer, tcp_xmit_probe_skb, tcp_rtx_probe0_timed_out). A sender whose peer stops reading
 * fills the peer's receive window and then probes it. RFC 1122 4.2.2.17: the connection stays open as long as the peer answers
 * the probes; with TCP_USER_TIMEOUT set it ends once the window has stayed shut that long. Measured on the host (build with
 * -DHOST, run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   K. without TCP_USER_TIMEOUT, a peer with SO_RCVBUF 2048 that never reads: the sender is still open 20 s later (no POLLERR,
 *      SO_ERROR 0), and once the peer reads everything arrives;
 *   U. with TCP_USER_TIMEOUT 2000: POLLERR after 2 to 5 s, SO_ERROR 110 (ETIMEDOUT). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long accept_(long s) { return rc(accept4((int)s, 0, 0, SOCK_NONBLOCK)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, MSG_NOSIGNAL, a, (socklen_t)al)); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, a, (socklen_t *)al)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static long poll_ev(long s) { struct pollfd p = { (int)s, POLLIN | POLLOUT, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : p.revents; }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void close_(long s) { close((int)s); }
#define NONBLOCK SOCK_NONBLOCK
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0x800); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0x4000, (long)a, al); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return syscall6(122, s, (long)b, n, 0x40, (long)a, (long)al); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long poll_ev(long s) { struct { int fd; short ev, rev; } p = { (int)s, 1 | 4, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void close_(long s) { syscall1(11, s); }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello409:   ok   " : "hello409:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
/* A connected pair on `port`: the peer has SO_RCVBUF `rcvbuf` (set on the listener, before the handshake). */
static long pair(int port, int rcvbuf, long *peer) {
    long l = sock(2, 1, 0);
    seti(l, 1, 2, 1);
    seti(l, 1, 8, rcvbuf);
    unsigned char a[16];
    mk4(a, port);
    bind_(l, a, 16);
    listen_(l, 4);
    long c = sock(2, 1 | NONBLOCK, 0);
    connect_(c, a, 16);
    *peer = -1;
    for (int i = 0; i < 100 && *peer < 0; i++) { nap(); *peer = accept_(l); }
    close_(l);
    return c;
}
static char buf[8192];
/* Fill the send side for about 1 s (until the window is shut and the send buffer full): the bytes queued. */
static long fill(long c) {
    long tot = 0, t0 = now_ms();
    while (now_ms() - t0 < 1000) {
        long w = sendto_(c, buf, sizeof buf, 0, 0);
        if (w > 0) tot += w; else nap();
    }
    return tot;
}
static long wait_err(long s, long limit) {
    long t0 = now_ms();
    while (now_ms() - t0 < limit) {
        if (poll_ev(s) & 8) return now_ms() - t0;
        nap();
    }
    return -1;
}
int main(void) {
    print("hello409: zero-window probes and TCP_USER_TIMEOUT\n");
    memset(buf, 'z', sizeof buf);
    int port = 40430 + (int)(sock(2, 2, 0) & 7) * 4;

    long p;
    long c = pair(port, 2048, &p);
    long q = fill(c);
    long e = wait_err(c, 20000);
    int se = geti(c, 1, 4);
    long got = 0, t0 = now_ms();
    while (got < q && now_ms() - t0 < 20000) {
        unsigned char r[4096];
        int rl = 0;
        long n = recvfrom_(p, r, sizeof r, 0, &rl);
        if (n > 0) got += n; else nap();
    }
    snprintf(msg, sizeof msg, "K: peer %ld; %ld bytes queued; POLLERR after %ld ms in 20 s, SO_ERROR %d; the peer then reads %ld (-1 0, all)", p, q, e, se, got);
    check(p >= 0 && q > 0 && e == -1 && se == 0 && got == q, msg);
    close_(c);
    close_(p);

    c = pair(port + 1, 2048, &p);
    seti(c, 6, 18, 2000);
    q = fill(c);
    e = wait_err(c, 8000);
    se = geti(c, 1, 4);
    snprintf(msg, sizeof msg, "U: peer %ld; %ld bytes queued; with TCP_USER_TIMEOUT 2000 POLLERR after %ld ms (counted from the window filling), SO_ERROR %d (1000..5000, 110)", p, q, e, se);
    check(p >= 0 && q > 0 && e >= 1000 && e <= 5000 && se == 110, msg);
    close_(c);
    close_(p);

    print(failures == 0 ? "hello409: PASS\n" : "hello409: FAIL\n");
    return failures == 0 ? 0 : 1;
}
