/* hello500: multicast group membership on raw sockets (Linux ipv6_sock_mc_join/drop and ip_mc_join_group/leave_group work for any
 * inet socket). With only lo up: A IPv6 join on lo 0, again EADDRINUSE, on interface 0 ENODEV (no route), drop 0, again EADDRNOTAVAIL,
 * a non-multicast group EINVAL; B the IPv4 counterparts. Measured with -DHOST in a new network namespace (CAP_NET_RAW). */
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
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello500:   ok   " : "hello500:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long m6(long s, int opt, const unsigned char *group, unsigned int ifx) {
    unsigned char m[20];
    memcpy(m, group, 16);
    m[16] = (unsigned char)ifx; m[17] = (unsigned char)(ifx >> 8); m[18] = 0; m[19] = 0;
    return setopt_(s, 41, opt, m, 20);
}
static long m4(long s, int opt, const unsigned char *group, unsigned int ifx) {
    unsigned char m[12];
    memset(m, 0, 12);
    memcpy(m, group, 4);
    m[8] = (unsigned char)ifx;
    return setopt_(s, 0, opt, m, 12);
}
int main(void) {
    print("hello500: multicast membership on raw sockets\n");
    static const unsigned char g6[16] = { 0xff, 0x02, [13] = 1, [14] = 0, [15] = 3 };
    static const unsigned char g6b[16] = { 0xff, 0x05, [15] = 7 };
    static const unsigned char u6[16] = { [15] = 1 };
    long r6 = sock(10, 3, 58);
    long a = m6(r6, 20, g6, 1), b = m6(r6, 20, g6, 1), c = m6(r6, 20, g6b, 99), d = m6(r6, 21, g6, 1), e = m6(r6, 21, g6, 1), f = m6(r6, 20, u6, 1);
    snprintf(msg, sizeof msg, "A: IPv6 raw %ld: join lo %ld, again %ld, if 99 %ld, drop %ld, again %ld, non-multicast %ld (>=0 0 -98 -19 0 -99 -22)", r6, a, b, c, d, e, f);
    check(r6 >= 0 && a == 0 && b == -98 && c == -19 && d == 0 && e == -99 && f == -22, msg);
    close_(r6);
    static const unsigned char g4[4] = { 224, 1, 2, 3 };
    static const unsigned char u4[4] = { 10, 0, 0, 1 };
    long r4 = sock(2, 3, 1);
    long g = m4(r4, 35, g4, 1), h = m4(r4, 35, g4, 1), i = m4(r4, 36, g4, 1), k = m4(r4, 36, g4, 1), l = m4(r4, 35, u4, 1);
    snprintf(msg, sizeof msg, "B: IPv4 raw %ld: join lo %ld, again %ld, drop %ld, again %ld, non-multicast %ld (>=0 0 -98 0 -99 -22)", r4, g, h, i, k, l);
    check(r4 >= 0 && g == 0 && h == -98 && i == 0 && k == -99 && l == -22, msg);
    close_(r4);
    print(failures ? "hello500: FAIL\n" : "hello500: PASS\n");
    return failures ? 1 : 0;
}
