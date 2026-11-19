/* hello432: SO_SNDTIMEO bounds a blocking TCP connect (Linux __inet_stream_connect: timeo = sock_sndtimeo(); inet_wait_for_connect
 * returns 0 once it runs out and connect() fails with the EINPROGRESS it had set). A listener with backlog 0 takes one connection
 * into its accept queue (accept limit backlog + 1) and drops the SYN of the next, so that connect() hangs in SYN_SENT until the
 * timeout; a second connect() on it is EALREADY while the handshake retries. A socket without SO_SNDTIMEO still connects to a
 * listener with room.
 * Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   A. listen(0) on 127.0.0.1: the first connect succeeds at once;
 *   B. a second socket with SO_SNDTIMEO 300 ms: connect -> -115 (EINPROGRESS) after about 300 ms; SO_ERROR 0; connect again -> -114
 *      (EALREADY);
 *   C. SO_SNDTIMEO 0 (no timeout) on a fresh socket to a second listener with backlog 4: connect -> 0. */
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
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
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
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello432:   ok   " : "hello432:   FAIL ");
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
int main(void) {
    print("hello432: SO_SNDTIMEO bounds a blocking TCP connect\n");
    unsigned char a[16], b[16];
    mk4(a, 47321);
    mk4(b, 47322);
    int one = 1;
    long l = sock(2, 1, 0);
    setopt(l, 1, 2, &one, 4);
    long bl = bind_(l, a, 16), ll = listen_(l, 0);
    long c0 = sock(2, 1, 0);
    long t0 = now_ms();
    long r0 = connect_(c0, a, 16);
    long d0 = now_ms() - t0;
    snprintf(msg, sizeof msg, "A: bind %ld, listen(0) %ld, first connect %ld in %ld ms (0, 0, 0 in <200)", bl, ll, r0, d0);
    check(bl == 0 && ll == 0 && r0 == 0 && d0 < 200, msg);

    long c1 = sock(2, 1, 0);
    long tv[2] = { 0, 300000 };
    long so = setopt(c1, 1, 21, tv, 16);
    long t1 = now_ms();
    long r1 = connect_(c1, a, 16);
    long d1 = now_ms() - t1;
    int err = -1, el = 4;
    long ge = getopt_(c1, 1, 4, &err, &el);
    long r1b = connect_(c1, a, 16);
    snprintf(msg, sizeof msg, "B: SO_SNDTIMEO %ld; connect %ld after %ld ms; SO_ERROR %ld %d; connect again %ld (0; -115 after 250..1500; 0 0; -114)", so, r1, d1,
             ge, err, r1b);
    check(so == 0 && r1 == -115 && d1 >= 250 && d1 <= 1500 && ge == 0 && err == 0 && r1b == -114, msg);

    long l2 = sock(2, 1, 0);
    setopt(l2, 1, 2, &one, 4);
    long bl2 = bind_(l2, b, 16), ll2 = listen_(l2, 4);
    long c2 = sock(2, 1, 0);
    long tz[2] = { 0, 0 };
    long so2 = setopt(c2, 1, 21, tz, 16);
    long r2 = connect_(c2, b, 16);
    snprintf(msg, sizeof msg, "C: second listener %ld %ld; SO_SNDTIMEO 0 %ld; connect %ld (0 0; 0; 0)", bl2, ll2, so2, r2);
    check(bl2 == 0 && ll2 == 0 && so2 == 0 && r2 == 0, msg);

    close_(c0);
    close_(c1);
    close_(c2);
    close_(l);
    close_(l2);
    print(failures == 0 ? "hello432: PASS\n" : "hello432: FAIL\n");
    return failures == 0 ? 0 : 1;
}
