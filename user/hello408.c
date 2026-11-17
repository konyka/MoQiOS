/* hello408: TCP_SYNCNT and the SYN retransmission schedule (Linux tcp_sock_set_syncnt, tcp_write_timeout, tcp_model_timeout,
 * tcp_retransmit_timer with tcp_syn_linear_timeouts 4). A SYN nobody answers is sent again after 1 s, five times 1 s apart, then
 * with a doubling wait; connect fails with ETIMEDOUT once TCP_SYNCNT + 4 retransmissions went out or ((2 << TCP_SYNCNT) - 1) s
 * passed, whichever is first, or at TCP_USER_TIMEOUT when one is set. The SYN goes to a listener whose accept queue is full, which
 * drops it on both systems. Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with
 * only lo up):
 *   A. TCP_SYNCNT reads 6; 0, 128, -1 and a 2-byte value are EINVAL; 1 and 127 read back;
 *   O. TCP_SYNCNT 1: 3 SYNs about 1 s apart, ETIMEDOUT (POLLERR, SO_ERROR 110) at about 3 s;
 *   T. TCP_SYNCNT 2: 6 SYNs 1 s apart, ETIMEDOUT at about 7 s;
 *   U. TCP_SYNCNT 6 with TCP_USER_TIMEOUT 2500: 3 SYNs, ETIMEDOUT at about 2.5 s. */
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
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }

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
    print(ok ? "hello408:   ok   " : "hello408:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char seg[1600];
static long rt;
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
static void drain(void) { unsigned char a[16]; int l = 16; while (recvfrom_(rt, seg, sizeof seg, a, &l) >= 0) l = 16; }
static long full_listener(int port, long *kid) {
    long l = sock(2, 1, 0);
    unsigned char a[16];
    mk4(a, port);
    bind_(l, a, 16);
    listen_(l, 1);
    for (int i = 0; i < 2; i++) {
        kid[i] = sock(2, 1 | NONBLOCK, 0);
        connect_(kid[i], a, 16);
    }
    for (int i = 0; i < 10; i++) nap();
    return l;
}
/* Connect to the full listener on `port` with TCP_SYNCNT `cnt` (and TCP_USER_TIMEOUT `ut` when > 0), counting the SYNs the raw TCP
 * socket sees until POLLERR or `limit` ms: the ms POLLERR took (-1 if none), the SYN count and SO_ERROR in the out args. */
static long run(int port, int cnt, int ut, long limit, int *syns, int *err) {
    long c = sock(2, 1 | NONBLOCK, 0);
    seti(c, 6, 7, cnt);
    if (ut > 0) seti(c, 6, 18, ut);
    unsigned char a[16];
    mk4(a, port);
    drain();
    long t0 = now_ms();
    connect_(c, a, 16);
    *syns = 0;
    long when = -1;
    while (now_ms() - t0 < limit) {
        unsigned char f[16];
        int l = 16;
        long n;
        while ((n = recvfrom_(rt, seg, sizeof seg, f, &l)) > 0) {
            l = 16;
            int off = (seg[0] & 15) * 4;
            if ((seg[off + 2] << 8 | seg[off + 3]) == port && (seg[off + 13] & 0x12) == 0x02) (*syns)++;
        }
        if (poll_ev(c) & 8) { when = now_ms() - t0; break; }
        nap();
    }
    *err = geti(c, 1, 4);
    close_(c);
    return when;
}
int main(void) {
    print("hello408: TCP_SYNCNT and the SYN retransmission schedule\n");
    rt = sock(2, 3, 6);
    long kid[2];
    long L = full_listener(40420, kid);

    long a = sock(2, 1, 0);
    int d = geti(a, 6, 7);
    long z = seti(a, 6, 7, 0), b = seti(a, 6, 7, 128), m = seti(a, 6, 7, -1);
    short two = 3;
    long h = setopt(a, 6, 7, &two, 2);
    long o1 = seti(a, 6, 7, 1);
    int r1 = geti(a, 6, 7);
    long o127 = seti(a, 6, 7, 127);
    int r127 = geti(a, 6, 7);
    snprintf(msg, sizeof msg, "A: default %d; 0 %ld, 128 %ld, -1 %ld, 2 bytes %ld (-22 each); 1 %ld reads %d; 127 %ld reads %d", d, z, b, m, h, o1, r1, o127, r127);
    check(d == 6 && z == -22 && b == -22 && m == -22 && h == -22 && o1 == 0 && r1 == 1 && o127 == 0 && r127 == 127, msg);
    close_(a);

    int syns, err;
    long w = run(40420, 1, 0, 8000, &syns, &err);
    snprintf(msg, sizeof msg, "O: TCP_SYNCNT 1: %d SYNs, POLLERR after %ld ms, SO_ERROR %d (3, 2500..4500, 110)", syns, w, err);
    check(syns == 3 && w >= 2500 && w <= 4500 && err == 110, msg);

    w = run(40420, 2, 0, 12000, &syns, &err);
    snprintf(msg, sizeof msg, "T: TCP_SYNCNT 2: %d SYNs, POLLERR after %ld ms, SO_ERROR %d (6, 6500..9000, 110)", syns, w, err);
    check(syns == 6 && w >= 6500 && w <= 9000 && err == 110, msg);

    w = run(40420, 6, 2500, 8000, &syns, &err);
    snprintf(msg, sizeof msg, "U: TCP_SYNCNT 6 with TCP_USER_TIMEOUT 2500: %d SYNs, POLLERR after %ld ms, SO_ERROR %d (3, 2300..4000, 110)", syns, w, err);
    check(syns == 3 && w >= 2300 && w <= 4000 && err == 110, msg);

    close_(kid[0]); close_(kid[1]); close_(L); close_(rt);
    print(failures == 0 ? "hello408: PASS\n" : "hello408: FAIL\n");
    return failures == 0 ? 0 : 1;
}
