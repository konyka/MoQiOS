/* hello416: TCP_NOTSENT_LOWAT (Linux do_tcp_setsockopt / do_tcp_getsockopt, tcp_stream_memory_free, tcp_poll). The value is kept as
 * given and read back; 0 means the sysctl default (tcp_notsent_lowat, UINT_MAX: no limit). A send may queue more only while the
 * bytes written but not yet sent are below it; poll and epoll report the socket writable only while twice those bytes are below
 * it. Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   V. it reads 0 by default; 4096 reads 4096, -5 is accepted and reads -5, 0 reads 0; an optlen of 2 is EINVAL;
 *   P. with u unsent bytes (the peer does not read): POLLOUT without the option; not with 1024 (and a non-blocking send of 100
 *      is EAGAIN, nothing queued); POLLOUT again with 4u, not with 2u, again with 2u + 1;
 *   B. with 1024, a blocking send under SO_SNDTIMEO 300 ms fails with EAGAIN after it;
 *   W. once the peer drains everything nothing is unsent, POLLOUT is back and a blocking send of 3000 queues all of it;
 *   A. a connection accepted from a listener with 777 reads 777. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
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
static long ioctl_(long s, unsigned long r, void *v) { return rc(ioctl((int)s, r, v)); }
static long poll_out(long s) { struct pollfd p = { (int)s, POLLOUT, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : (p.revents & POLLOUT) != 0; }
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
static long ioctl_(long s, unsigned long r, void *v) { return syscall3(165, s, (long)r, (long)v); }
static long poll_out(long s) { struct { int fd; short ev, rev; } p = { (int)s, 4, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (p.rev & 4) != 0; }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
#endif
#define LOWAT 25
#define DONTWAIT 0x40
static int failures;
static char msg[900];
static char buf[20000];
static void check(int ok, const char *w) {
    print(ok ? "hello416:   ok   " : "hello416:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static int unsent(long s) { int v = -1; long r = ioctl_(s, 0x894B, &v); return r < 0 ? (int)r : v; }
int main(void) {
    print("hello416: TCP_NOTSENT_LOWAT\n");
    long s = sock(2, 1, 0);
    int v0 = geti(s, 6, LOWAT);
    long e1 = seti(s, 6, LOWAT, 4096); int v1 = geti(s, 6, LOWAT);
    long e2 = seti(s, 6, LOWAT, -5); int v2 = geti(s, 6, LOWAT);
    long e3 = seti(s, 6, LOWAT, 0); int v3 = geti(s, 6, LOWAT);
    short sh = 1;
    long e4 = setopt(s, 6, LOWAT, &sh, 2);
    snprintf(msg, sizeof msg, "V: default %d; 4096 %ld reads %d, -5 %ld reads %d, 0 %ld reads %d; optlen 2 %ld (0; 4096, -5, 0; -22)", v0, e1, v1, e2, v2, e3, v3, e4);
    check(v0 == 0 && e1 == 0 && v1 == 4096 && e2 == 0 && v2 == -5 && e3 == 0 && v3 == 0 && e4 == -22, msg);
    close_(s);

    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 40433 >> 8; a[3] = 40433 & 0xff; a[4] = 127; a[7] = 1;
    long l = sock(2, 1, 0);
    seti(l, 1, 8, 4096);
    bind_(l, a, 16);
    listen_(l, 4);
    long c = sock(2, 1, 0);
    seti(c, 6, 1, 1);
    long cr = connect_(c, a, 16);
    long p = -11;
    for (int i = 0; i < 100 && p < 0; i++) { p = accept_(l); if (p < 0) nap(); }
    long total = 0;
    while (total < 12000) { long r = send_(c, buf, 1000, DONTWAIT); if (r <= 0) break; total += r; }
    for (int i = 0; i < 5; i++) nap();
    int u = unsent(c);
    long po0 = poll_out(c);
    seti(c, 6, LOWAT, 1024);
    long po1 = poll_out(c);
    long sr = send_(c, buf, 100, DONTWAIT);
    int u1 = unsent(c);
    seti(c, 6, LOWAT, 4 * u); long po4 = poll_out(c);
    seti(c, 6, LOWAT, 2 * u); long po2 = poll_out(c);
    seti(c, 6, LOWAT, 2 * u + 1); long po21 = poll_out(c);
    snprintf(msg, sizeof msg, "P: connect %ld accept %ld, sent %ld, unsent %d: POLLOUT %ld; lowat 1024 POLLOUT %ld, send %ld, unsent %d; 4u %ld, 2u %ld, 2u+1 %ld (0 >=0 12000 >1024: 1; 0 -11 same; 1 0 1)", cr, p, total, u, po0, po1, sr, u1, po4, po2, po21);
    check(cr == 0 && p >= 0 && total == 12000 && u > 1024 && po0 == 1 && po1 == 0 && sr == -11 && u1 == u && po4 == 1 && po2 == 0 && po21 == 1, msg);

    seti(c, 6, LOWAT, 1024);
    long tv[2] = { 0, 300000 };
    setopt(c, 1, 21, tv, 16);
    long t0 = now_ms();
    long br = send_(c, buf, 100, 0);
    long bms = now_ms() - t0;
    snprintf(msg, sizeof msg, "B: lowat 1024, SO_SNDTIMEO 300 ms: blocking send %ld after %ld ms (-11, 250..1500)", br, bms);
    check(br == -11 && bms >= 250 && bms <= 1500, msg);

    long got = 0;
    for (int i = 0; i < 100 && got < 12000; i++) { long n = recv_(p, buf, sizeof buf); if (n > 0) got += n; else nap(); }
    for (int i = 0; i < 5; i++) nap();
    int u2 = unsent(c);
    long po3 = poll_out(c);
    long wr = send_(c, buf, 3000, 0);
    snprintf(msg, sizeof msg, "W: peer drained %ld, unsent %d, POLLOUT %ld, blocking send of 3000 %ld (12000, 0, 1, 3000)", got, u2, po3, wr);
    check(got == 12000 && u2 == 0 && po3 == 1 && wr == 3000, msg);
    if (p >= 0) close_(p);
    close_(c);

    seti(l, 6, LOWAT, 777);
    long c2 = sock(2, 1, 0);
    connect_(c2, a, 16);
    long p2 = -11;
    for (int i = 0; i < 100 && p2 < 0; i++) { p2 = accept_(l); if (p2 < 0) nap(); }
    int va = p2 >= 0 ? geti(p2, 6, LOWAT) : (int)p2;
    snprintf(msg, sizeof msg, "A: listener 777, accepted connection reads %d (777)", va);
    check(va == 777, msg);
    if (p2 >= 0) close_(p2);
    close_(c2);
    close_(l);

    print(failures == 0 ? "hello416: PASS\n" : "hello416: FAIL\n");
    return failures == 0 ? 0 : 1;
}
