/* hello400: getsockopt and setsockopt at a level the socket does not know (Linux): an IPv4 TCP, UDP or raw socket hands any level
 * but SOL_SOCKET and its own to ip_getsockopt, which answers EOPNOTSUPP for a level other than SOL_IP (ip_setsockopt: ENOPROTOOPT);
 * an IPv6 socket's ipv6_getsockopt / ipv6_setsockopt answer ENOPROTOOPT; AF_UNIX has no getsockopt / setsockopt beyond SOL_SOCKET,
 * so do_sock_getsockopt / do_sock_setsockopt answer EOPNOTSUPP both ways. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with only lo up), option 1000 at each level:
 *   T. IPv4 TCP: get at SOL_UDP (17), SOL_RAW (255), SOL_ICMPV6 (58), level 1000 and SOL_IPV6 (41) is -95; set at each is -92;
 *      an unknown SOL_TCP option and an unknown SOL_IP one are -92 both ways;
 *   U. IPv4 UDP: get at SOL_TCP, SOL_RAW, SOL_ICMPV6, 1000, SOL_IPV6 is -95, set -92; SOL_UDP and SOL_IP options are -92;
 *   R. IPv4 raw: get at SOL_TCP, SOL_UDP, SOL_ICMPV6, 1000, SOL_IPV6 is -95, set -92; an unknown SOL_RAW option is -92;
 *   6. IPv6 TCP, UDP and raw: every one of these levels is -92 both ways;
 *   X. AF_UNIX stream, datagram and seqpacket: every one of these levels, SOL_IP included, is -95 both ways. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello400:   ok   " : "hello400:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long g(long s, int lv) { int v[16]; int l = 4; return getopt_(s, lv, 1000, v, &l); }
static long st(long s, int lv) { int v = 0; return setopt(s, lv, 1000, &v, 4); }
static const int levels[] = { 6, 17, 255, 58, 1000, 0, 41 };
#define NLEV 7
/* Each level's get and set on socket `s` against `want_get[i]` / `want_set[i]`, written into msg after `tag`. */
static int sweep(const char *tag, long s, const long *want_get, const long *want_set) {
    int ok = s >= 0;
    int at = snprintf(msg, sizeof msg, "%s: socket %ld;", tag, s);
    for (int i = 0; i < NLEV; i++) {
        long a = g(s, levels[i]), b = st(s, levels[i]);
        if (a != want_get[i] || b != want_set[i]) ok = 0;
        at += snprintf(msg + at, sizeof msg - (unsigned long)at, " %d: %ld %ld (%ld %ld)", levels[i], a, b, want_get[i], want_set[i]);
    }
    return ok;
}
int main(void) {
    print("hello400: getsockopt and setsockopt at a level the socket does not know\n");
    static const long all92[NLEV] = { -92, -92, -92, -92, -92, -92, -92 };
    static const long all95[NLEV] = { -95, -95, -95, -95, -95, -95, -95 };
    static const long tcp4[NLEV] = { -92, -95, -95, -95, -95, -92, -95 };
    static const long udp4[NLEV] = { -95, -92, -95, -95, -95, -92, -95 };
    static const long raw4[NLEV] = { -95, -95, -92, -95, -95, -92, -95 };
    long s = sock(2, 1, 0);
    check(sweep("T", s, tcp4, all92), msg);
    close_(s);
    s = sock(2, 2, 0);
    check(sweep("U", s, udp4, all92), msg);
    close_(s);
    s = sock(2, 3, 1);
    check(sweep("R", s, raw4, all92), msg);
    close_(s);
    long a = sock(10, 1, 0), b = sock(10, 2, 0), c = sock(10, 3, 58);
    int ok6 = sweep("6 tcp", a, all92, all92);
    char keep[900];
    snprintf(keep, sizeof keep, "%s", msg);
    ok6 = sweep("udp", b, all92, all92) && ok6;
    char keep2[900];
    snprintf(keep2, sizeof keep2, "%s", msg);
    ok6 = sweep("raw", c, all92, all92) && ok6;
    char all[2800];
    snprintf(all, sizeof all, "%s | %s | %s", keep, keep2, msg);
    check(ok6, all);
    close_(a); close_(b); close_(c);
    long x = sock(1, 1, 0), y = sock(1, 2, 0), z = sock(1, 5, 0);
    int okx = sweep("X stream", x, all95, all95);
    snprintf(keep, sizeof keep, "%s", msg);
    okx = sweep("dgram", y, all95, all95) && okx;
    snprintf(keep2, sizeof keep2, "%s", msg);
    okx = sweep("seqpacket", z, all95, all95) && okx;
    snprintf(all, sizeof all, "%s | %s | %s", keep, keep2, msg);
    check(okx, all);
    close_(x); close_(y); close_(z);
    print(failures == 0 ? "hello400: PASS\n" : "hello400: FAIL\n");
    return failures == 0 ? 0 : 1;
}
