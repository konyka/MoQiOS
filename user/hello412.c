/* hello412: a connection accept() returns starts with the listening socket's options (Linux sk_clone_lock copies the whole sock,
 * inet_csk_clone_lock and tcp_create_openreq_child keep the TCP settings): only the error, SO_PRIORITY (sk_clone_lock clears sk_err,
 * sk_err_soft and sk_priority) and the connection state are its own.
 * Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up):
 *   I. a listener with TCP_USER_TIMEOUT 1500, TCP_RTO_MAX_MS 2000, TCP_SYNCNT 3, TCP_KEEPIDLE 30, TCP_KEEPINTVL 7, TCP_KEEPCNT 4,
 *      SO_KEEPALIVE, TCP_NODELAY, SO_PRIORITY 3, IP_TOS 0x10, IP_TTL 33 and SO_RCVTIMEO 1.5 s: the accepted socket reads them all
 *      back but SO_PRIORITY, which reads 0;
 *   D. a listener left alone: the accepted socket reads the defaults (0, 120000, 6, 7200, 75, 9, 0, 0, 0, 0, 64, 0);
 *   C. setting an option on the accepted socket leaves the listener alone (TCP_USER_TIMEOUT 900 there, 1500 on the listener). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
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
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello412:   ok   " : "hello412:   FAIL ");
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
static long rcvtimeo_ms(long s) { long tv[2] = { -7, -7 }; int l = 16; long r = getopt_(s, 1, 20, tv, &l); return r < 0 ? r : tv[0] * 1000 + tv[1] / 1000; }
/* The options hello412 looks at, in the order the messages list them. */
static void read_opts(long s, long *v) {
    v[0] = geti(s, 6, 18); v[1] = geti(s, 6, 44); v[2] = geti(s, 6, 7); v[3] = geti(s, 6, 4); v[4] = geti(s, 6, 5);
    v[5] = geti(s, 6, 6); v[6] = geti(s, 1, 9); v[7] = geti(s, 6, 1); v[8] = geti(s, 1, 12); v[9] = geti(s, 0, 1);
    v[10] = geti(s, 0, 2); v[11] = rcvtimeo_ms(s);
}
static void fmt(char *o, const long *v) {
    snprintf(o, 200, "%ld %ld %ld %ld %ld %ld %ld %ld %ld 0x%lx %ld %ld", v[0], v[1], v[2], v[3], v[4], v[5], (long)(v[6] != 0), (long)(v[7] != 0), v[8], v[9], v[10], v[11]);
}
/* A listener on `port` and the socket accept() returns for one connection to it: the accepted socket, or a negative errno. */
static long pair(long l, int port, long *client) {
    unsigned char a[16];
    mk4(a, port);
    long b = bind_(l, a, 16);
    if (b < 0) return b;
    long n = listen_(l, 4);
    if (n < 0) return n;
    *client = sock(2, 1, 0);
    long c = connect_(*client, a, 16);
    if (c < 0) return c;
    return accept_(l);
}
int main(void) {
    print("hello412: an accepted connection starts with the listener's options\n");
    char got[200], want[200];

    long l = sock(2, 1, 0), cl = -1;
    seti(l, 6, 18, 1500); seti(l, 6, 44, 2000); seti(l, 6, 7, 3); seti(l, 6, 4, 30); seti(l, 6, 5, 7); seti(l, 6, 6, 4);
    seti(l, 1, 9, 1); seti(l, 6, 1, 1); seti(l, 1, 12, 3); seti(l, 0, 1, 0x10); seti(l, 0, 2, 33);
    long tv[2] = { 1, 500000 };
    setopt(l, 1, 20, tv, 16);
    long a = pair(l, 40412, &cl);
    long v[12];
    if (a >= 0) read_opts(a, v); else memset(v, 0, sizeof v);
    fmt(got, v);
    long w[12] = { 1500, 2000, 3, 30, 7, 4, 1, 1, 0, 0x10, 33, 1500 };
    fmt(want, w);
    snprintf(msg, sizeof msg, "I: accepted %ld reads %s (%s)", a, got, want);
    check(a >= 0 && strcmp(got, want) == 0, msg);

    long cs = a >= 0 ? seti(a, 6, 18, 900) : -1;
    int ca = a >= 0 ? geti(a, 6, 18) : -1, clv = geti(l, 6, 18);
    snprintf(msg, sizeof msg, "C: TCP_USER_TIMEOUT 900 on the accepted socket %ld, it reads %d, the listener %d (0 900 1500)", cs, ca, clv);
    check(cs == 0 && ca == 900 && clv == 1500, msg);
    if (a >= 0) close_(a);
    close_(cl); close_(l);

    long d = sock(2, 1, 0), dc = -1;
    long da = pair(d, 40413, &dc);
    if (da >= 0) read_opts(da, v); else memset(v, 0, sizeof v);
    fmt(got, v);
    long dw[12] = { 0, 120000, 6, 7200, 75, 9, 0, 0, 0, 0, 64, 0 };
    fmt(want, dw);
    snprintf(msg, sizeof msg, "D: accepted %ld from a plain listener reads %s (%s)", da, got, want);
    check(da >= 0 && strcmp(got, want) == 0, msg);
    if (da >= 0) close_(da);
    close_(dc); close_(d);

    print(failures == 0 ? "hello412: PASS\n" : "hello412: FAIL\n");
    return failures == 0 ? 0 : 1;
}
