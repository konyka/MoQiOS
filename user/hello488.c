/* hello488: IP_MINTTL and IPV6_MINHOPCOUNT filter TCP input (tcp_v4_rcv / tcp_v6_rcv). A listener with threshold 2 drops a SYN
 * arriving with TTL / hop limit 1, so a connect bounded by SO_SNDTIMEO returns EINPROGRESS; a SYN at the threshold connects.
 * Measured on the host (build with -DHOST, run in unshare --map-auto --map-root-user -n with lo up). A: IPv4; B: IPv6. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello488:   ok   " : "hello488:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
struct sin4 { unsigned short fam, port; unsigned char addr[4]; unsigned char zero[8]; };
struct sin6 { unsigned short fam, port; unsigned int flow; unsigned char addr[16]; unsigned int scope; };
static const unsigned char lo6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
static void mk4(struct sin4 *a, unsigned short port) {
    __builtin_memset(a, 0, sizeof *a);
    a->fam = 2;
    a->port = (unsigned short)((port >> 8) | (port << 8));
    a->addr[0] = 127;
    a->addr[3] = 1;
}
static void mk6(struct sin6 *a, unsigned short port) {
    __builtin_memset(a, 0, sizeof *a);
    a->fam = 10;
    a->port = (unsigned short)((port >> 8) | (port << 8));
    __builtin_memcpy(a->addr, lo6, 16);
}
static long timeout200(long s) {
    long tv[2] = { 0, 200000 };
    return setopt_(s, 1, 21, tv, 16);
}
int main(void) {
    print("hello488: IP_MINTTL / IPV6_MINHOPCOUNT filter TCP input\n");
    struct sin4 a4;
    mk4(&a4, 40880);
    long l4 = sock(2, 1, 0);
    int two = 2, one = 1;
    long as = setopt_(l4, 0, 21, &two, 4);
    long b4 = bind_(l4, &a4, sizeof a4), li4 = listen_(l4, 4);
    long c4 = sock(2, 1, 0);
    long ts4 = timeout200(c4);
    long ttl4 = setopt_(c4, 0, 2, &one, 4);
    long low4 = connect_(c4, &a4, sizeof a4);
    snprintf(msg, sizeof msg, "A: listener MINTTL %ld, bind %ld listen %ld; client timeout %ld TTL %ld; TTL 1 connect %ld (0 0 0 0 0 -115)",
             as, b4, li4, ts4, ttl4, low4);
    check(as == 0 && b4 == 0 && li4 == 0 && ts4 == 0 && ttl4 == 0 && low4 == -115, msg);
    close_(c4);
    c4 = sock(2, 1, 0);
    ttl4 = setopt_(c4, 0, 2, &two, 4);
    long high4 = connect_(c4, &a4, sizeof a4);
    long accepted4 = high4 == 0 ? accept_(l4) : -1000;
    snprintf(msg, sizeof msg, "A: TTL 2 at the threshold connects: set %ld connect %ld accept %ld (0 0 >=0)", ttl4, high4, accepted4);
    check(ttl4 == 0 && high4 == 0 && accepted4 >= 0, msg);
    close_(accepted4);
    close_(c4);
    close_(l4);

    struct sin6 a6;
    mk6(&a6, 40881);
    long l6 = sock(10, 1, 0);
    as = setopt_(l6, 41, 73, &two, 4);
    long b6 = bind_(l6, &a6, sizeof a6), li6 = listen_(l6, 4);
    long c6 = sock(10, 1, 0);
    long ts6 = timeout200(c6);
    long hops6 = setopt_(c6, 41, 16, &one, 4);
    long low6 = connect_(c6, &a6, sizeof a6);
    snprintf(msg, sizeof msg, "B: listener MINHOPCOUNT %ld, bind %ld listen %ld; client timeout %ld hops %ld; hop 1 connect %ld (0 0 0 0 0 -115)",
             as, b6, li6, ts6, hops6, low6);
    check(as == 0 && b6 == 0 && li6 == 0 && ts6 == 0 && hops6 == 0 && low6 == -115, msg);
    close_(c6);
    c6 = sock(10, 1, 0);
    hops6 = setopt_(c6, 41, 16, &two, 4);
    long high6 = connect_(c6, &a6, sizeof a6);
    long accepted6 = high6 == 0 ? accept_(l6) : -1000;
    snprintf(msg, sizeof msg, "B: hop limit 2 at the threshold connects: set %ld connect %ld accept %ld (0 0 >=0)", hops6, high6, accepted6);
    check(hops6 == 0 && high6 == 0 && accepted6 >= 0, msg);
    close_(accepted6);
    close_(c6);
    close_(l6);
    print(failures ? "hello488: FAIL\n" : "hello488: PASS\n");
    return failures ? 1 : 0;
}
