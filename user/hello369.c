/* hello369: a TCP connect whose next hop never answers ARP or NDP fails with EHOSTUNREACH after about 3 s (Linux: the SYN waits on
 * the neighbour entry, which fails after its probes; neigh_invalidate reports the error to the socket) instead of retransmitting
 * the SYN until ETIMEDOUT. Measured on the host (build with -DHOST, run in `unshare -rn` with a veth pair whose far end has no
 * address, so nothing answers ARP or NDP:
 *   ip link set lo up; ip link add v0 type veth peer name v1; ip link set v1 up; ip link set v0 up;
 *   ip addr add 10.0.2.15/24 dev v0; ip -6 addr add 2001:db8:1::7/64 dev v0 nodad; ip route add default via 10.0.2.2 dev v0;
 *   every IPv6 socket V6ONLY):
 *   A. a non-blocking connect to the on-link 10.0.2.99 is EINPROGRESS; SO_ERROR turns to EHOSTUNREACH 2-6 s later, and reading
 *      it again gives 0;
 *   B. a blocking connect to the on-link 10.0.2.98 fails with EHOSTUNREACH 2-6 s later;
 *   C. a non-blocking connect to ::99 in our own global /64 (on-link) is EINPROGRESS and SO_ERROR turns to EHOSTUNREACH 2-6 s
 *      later. */
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
static long v6only(long s) {
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long tsock(int fam, int nb) { long s = rc(socket(fam, SOCK_STREAM | (nb ? SOCK_NONBLOCK : 0), 0)); return fam == AF_INET6 ? v6only(s) : s; }
static long usock6(void) { return v6only(rc(socket(AF_INET6, SOCK_DGRAM, 0))); }
static long connect_(long s, const unsigned char *a, int l) { return rc(connect((int)s, (const void *)a, l)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long soerror(long s) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, SO_ERROR, &v, &l)); return r < 0 ? r : v; }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a, f) do { unsigned short fam = (f); memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
#define AF_INET6 10
static long tsock(int fam, int nb) { return syscall3(117, fam, 1 | (nb ? 0x800 : 0), 0); }
static long usock6(void) { return syscall3(117, AF_INET6, 2, 0); }
static long connect_(long s, const unsigned char *a, int l) { return syscall3(124, s, (long)a, l); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long soerror(long s) { int v = -1; int l = 4; long r = syscall5(133, s, 1, 4, (long)&v, (long)&l); return r < 0 ? r : v; }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
#define EHOSTUNREACH_ 113
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello369:   ok   " : "hello369:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, int d, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[4] = 10; s[5] = 0; s[6] = 2; s[7] = (unsigned char)d;
}
/* Poll SO_ERROR on `s` for up to 8 s; returns the first nonzero value and the time it took in `*ms`. */
static long wait_error(long s, long t0, long *ms) {
    long e = 0;
    while (now_ms() - t0 < 8000) {
        e = soerror(s);
        if (e != 0) break;
        pump();
    }
    *ms = now_ms() - t0;
    return e;
}
int main(void) {
    print("hello369: a connect whose next hop never answers fails with EHOSTUNREACH\n");
    unsigned char a[28];

    long s = tsock(AF_INET, 1);
    mk4(a, 99, 19901);
    long t0 = now_ms();
    long c = connect_(s, a, 16);
    long ms = 0;
    long e = wait_error(s, t0, &ms);
    long e2 = soerror(s);
    snprintf(msg, sizeof msg, "A: non-blocking connect to 10.0.2.99 %ld, SO_ERROR %ld after %ld ms, then %ld (-115 113 2000-6000 0)", c, e, ms, e2);
    check(c == -115 && e == EHOSTUNREACH_ && ms >= 2000 && ms <= 6000 && e2 == 0, msg);
    close_(s);

    long b = tsock(AF_INET, 0);
    mk4(a, 98, 19902);
    t0 = now_ms();
    long bc = connect_(b, a, 16);
    long bms = now_ms() - t0;
    snprintf(msg, sizeof msg, "B: blocking connect to 10.0.2.98 %ld after %ld ms (-113 2000-6000)", bc, bms);
    check(bc == -EHOSTUNREACH_ && bms >= 2000 && bms <= 6000, msg);
    close_(b);

    /* Our global address: the source a datagram to an off-link global address leaves from. */
    unsigned char far[28], own[28];
    for (int i = 0; i < 28; i++) far[i] = 0;
    FAM(far, AF_INET6);
    far[3] = 9; far[8] = 0x20; far[9] = 0x01; far[10] = 0x0d; far[11] = 0xb8; far[12] = 0xff; far[13] = 0xff; far[23] = 1;
    long u = usock6();
    long uc = connect_(u, far, 28), un = name_(u, own);
    close_(u);
    int global = un == 0 && !(own[8] == 0xfe && (own[9] & 0xc0) == 0x80) && (own[8] & 0xe0) != 0;
    for (int i = 16; i < 24; i++) own[i] = 0;
    own[23] = 0x99;
    own[2] = (unsigned char)(19903 >> 8); own[3] = (unsigned char)(19903 & 0xff);
    long v = tsock(AF_INET6, 1);
    t0 = now_ms();
    long vc = connect_(v, own, 28);
    long vms = 0;
    long ve = wait_error(v, t0, &vms);
    snprintf(msg, sizeof msg, "C: own global /64 %ld/%ld (%d), non-blocking connect to ::99 there %ld, SO_ERROR %ld after %ld ms (0 0 1 -115 113 2000-6000)", uc, un, global, vc, ve, vms);
    check(uc == 0 && un == 0 && global && vc == -115 && ve == EHOSTUNREACH_ && vms >= 2000 && vms <= 6000, msg);
    close_(v);

    print(failures ? "hello369: FAIL\n" : "hello369: PASS\n");
    return failures ? 1 : 0;
}
