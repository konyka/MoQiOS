/* hello417: TCP_LINGER2 (Linux do_tcp_setsockopt / do_tcp_getsockopt, tcp_fin_time, tcp_close, tcp_rcv_state_process,
 * tcp_keepalive_timer). The value bounds how long an orphan (closed by its owner) waits in FIN_WAIT2 for the peer's FIN; 0 means
 * the tcp_fin_timeout default (60 s), a negative value resets the orphan instead of waiting. A socket still open waits as long as
 * the peer takes. Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   V. it reads 60 by default; 5 reads 5, 0 reads 60, 200 reads 120, 120 reads 120, -1 and -7 read -1; an optlen of 2 is EINVAL;
 *   T. linger2 1, the client closes: 300 ms later the server's shutdown still finds it (SO_ERROR 0); after 3 s the orphan is
 *      gone and the server's FIN is answered with a reset (SO_ERROR ECONNRESET, recv still reads EOF);
 *   D. without the option the orphan is still there after 3 s (SO_ERROR 0);
 *   N. linger2 -1: close resets at once, from FIN_WAIT1 once the FIN is acknowledged and directly when already in FIN_WAIT2
 *      after shutdown(SHUT_WR); the server, in CLOSE_WAIT, sees SO_ERROR EPIPE;
 *   H. linger2 1 on a half-closed socket that stays open: after 3 s the server's data still arrives;
 *   A. a connection accepted from a listener with linger2 7 reads 7. */
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
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static void close_(long s) { close((int)s); }
static long send_(long s, const void *b, long n, int fl) { return rc(send((int)s, b, (size_t)n, fl | MSG_NOSIGNAL)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static long shutdown_(long s, int h) { return rc(shutdown((int)s, h)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void close_(long s) { syscall1(11, s); }
static long send_(long s, const void *b, long n, int fl) { return syscall6(44, s, (long)b, n, fl | 0x4000, 0, 0); }
static long recv_(long s, void *b, long n) { return syscall6(45, s, (long)b, n, 0x40, 0, 0); }
static long shutdown_(long s, int h) { return syscall2(48, s, h); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
#endif
#define LINGER2 8
#define DONTWAIT 0x40
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello417:   ok   " : "hello417:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static void wait_ms(int ms) { long t0 = now_ms(); while (now_ms() - t0 < ms) nap(); }
static unsigned char a[16];
static long l;
static void pair(long *c, long *p) {
    *c = sock(2, 1, 0);
    connect_(*c, a, 16);
    *p = -11;
    for (int i = 0; i < 100 && *p < 0; i++) { *p = accept_(l); if (*p < 0) nap(); }
}
/* The client sets linger2 `lg` (999: leave it alone), optionally half-closes, closes; `ms` later the server shuts down its side.
 * Returns the server's SO_ERROR; *eof gets the server's recv. */
static int orphan(int lg, int half, int ms, long *eof) {
    long c, p;
    pair(&c, &p);
    if (p < 0) return -1000;
    if (lg != 999) seti(c, 6, LINGER2, lg);
    if (half) { shutdown_(c, 1); wait_ms(100); }
    close_(c);
    wait_ms(ms);
    shutdown_(p, 1);
    wait_ms(200);
    char b[4];
    *eof = recv_(p, b, 4);
    int e = geti(p, 1, 4);
    close_(p);
    return e;
}
int main(void) {
    print("hello417: TCP_LINGER2\n");
    long s = sock(2, 1, 0);
    int v0 = geti(s, 6, LINGER2);
    int vals[7] = { 5, 0, 200, 120, -1, -7, 1 };
    int got[7];
    long er = 0;
    for (int i = 0; i < 7; i++) { er |= seti(s, 6, LINGER2, vals[i]); got[i] = geti(s, 6, LINGER2); }
    short sh = 1;
    long e2 = setopt(s, 6, LINGER2, &sh, 2);
    snprintf(msg, sizeof msg, "V: default %d; 5 0 200 120 -1 -7 1 read %d %d %d %d %d %d %d (set %ld); optlen 2 %ld (60; 5 60 120 120 -1 -1 1; 0; -22)",
             v0, got[0], got[1], got[2], got[3], got[4], got[5], got[6], er, e2);
    check(v0 == 60 && got[0] == 5 && got[1] == 60 && got[2] == 120 && got[3] == 120 && got[4] == -1 && got[5] == -1 && got[6] == 1 && er == 0 && e2 == -22, msg);
    close_(s);

    a[0] = 2; a[2] = 40427 >> 8; a[3] = 40427 & 0xff; a[4] = 127; a[7] = 1;
    l = sock(2, 1, 0);
    seti(l, 1, 2, 1);
    bind_(l, a, 16);
    listen_(l, 8);

    long f1, f2, f3, f4, f5;
    int t1 = orphan(1, 0, 300, &f1);
    int t2 = orphan(1, 0, 3000, &f2);
    snprintf(msg, sizeof msg, "T: linger2 1 orphan: after 300 ms SO_ERROR %d recv %ld; after 3 s SO_ERROR %d recv %ld (0 0; 104 0)", t1, f1, t2, f2);
    check(t1 == 0 && f1 == 0 && t2 == 104 && f2 == 0, msg);
    int d1 = orphan(999, 0, 3000, &f3);
    snprintf(msg, sizeof msg, "D: no option, orphan after 3 s: SO_ERROR %d recv %ld (0 0)", d1, f3);
    check(d1 == 0 && f3 == 0, msg);
    int n1 = orphan(-1, 0, 300, &f4);
    int n2 = orphan(-1, 1, 300, &f5);
    snprintf(msg, sizeof msg, "N: linger2 -1: close from FIN_WAIT1 SO_ERROR %d recv %ld, from FIN_WAIT2 SO_ERROR %d recv %ld (32 0; 32 0)", n1, f4, n2, f5);
    check(n1 == 32 && f4 == 0 && n2 == 32 && f5 == 0, msg);

    long c, p;
    pair(&c, &p);
    seti(c, 6, LINGER2, 1);
    shutdown_(c, 1);
    wait_ms(3000);
    long w = send_(p, "x", 1, 0);
    wait_ms(100);
    char b[4];
    long r = recv_(c, b, 4);
    snprintf(msg, sizeof msg, "H: half-closed but open, linger2 1, after 3 s: server send %ld, client recv %ld (1 1)", w, r);
    check(w == 1 && r == 1, msg);
    if (p >= 0) close_(p);
    close_(c);

    seti(l, 6, LINGER2, 7);
    long c2, p2;
    pair(&c2, &p2);
    int va = p2 >= 0 ? geti(p2, 6, LINGER2) : (int)p2;
    snprintf(msg, sizeof msg, "A: listener 7, accepted connection reads %d (7)", va);
    check(va == 7, msg);
    if (p2 >= 0) close_(p2);
    close_(c2);
    close_(l);

    print(failures == 0 ? "hello417: PASS\n" : "hello417: FAIL\n");
    return failures == 0 ? 0 : 1;
}
