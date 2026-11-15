/* hello364: the interface an IPv6 socket is bound to. bind() to an address that needs a scope (link-local unicast fe80::/10,
 * interface-local ff01::/16 and link-local ff02::/16 multicast) binds the socket to the interface in sin6_scope_id (Linux inet6_bind
 * sets sk_bound_dev_if); two sockets bound to such an address on different interfaces do not conflict (inet_bind_conflict skips a
 * pair whose bound interfaces differ), getsockname reports that interface, and a multicast datagram reaches a socket bound to another
 * interface no more (__udp_v6_is_mcast_sock). A global address ignores sin6_scope_id. A TCP socket cannot bind an IPv6 multicast
 * address (EINVAL) but an IPv4 one it can. Measured on the host (build with -DHOST, run in `unshare -rn` with a multicast dummy link
 * d0, which is interface 2 there as eth0 is in MoQiOS:
 *   ip link set lo up; ip link add d0 type dummy; ip link set d0 multicast on up; ip addr add 10.0.2.15/24 dev d0;
 *   ip -6 addr add 2001:db8:1::7/64 dev d0 nodad; ip -6 route add default via 2001:db8:1::1 dev d0; every IPv6 socket V6ONLY):
 *   S. ff01::1 with scope 0 is EINVAL, with scope 9 ENODEV;
 *   B1. on port 19401 (no SO_REUSEADDR) ff02::1%1 and ff02::1%2 both bind;
 *   B2. ff02::1%2 on 19402 twice is EADDRINUSE; ff02::1%2 then :: on 19403 EADDRINUSE; :: then ff02::1%1 on 19404 EADDRINUSE;
 *   B3. ff0e::1 then ff0e::1%2 on 19405 is EADDRINUSE (the scope of a global address is ignored);
 *   N. getsockname: ff02::1%1 names scope 1, ff02::1%2 scope 2, ff01::1%2 scope 2, ff0e::1%1 scope 0;
 *   D. A [ff02::1%1]:19406 and B [ff02::1%2]:19406 (SO_REUSEADDR); a datagram to [ff02::1%2]:19406 reaches B only;
 *   J. C on [::]:19407 joins ff0e::164 on lo only, with IPV6_MULTICAST_ALL 0; D on [::]:19407 joins it on the NIC; a datagram to
 *      [ff0e::164]:19407 leaving through the NIC reaches both (unlike IPv4, inet6_mc_check compares only the group, not the
 *      interface of the socket's membership);
 *   J2. E on [::]:19413 joins ff0e::165 on lo only: a datagram to it leaving through the NIC reaches nobody (the host is a member on
 *       lo, not on the NIC: ip6_finish_output2 loops a copy back only when the outgoing device is a member);
 *   T. an IPv6 TCP socket binding [ff02::1%2] or [ff0e::1] is EINVAL; an IPv4 TCP socket binds 239.1.1.1. */
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
static long sock6(int type) { return v6only(rc(socket(AF_INET6, type, 0))); }
static long sock4(int type) { return rc(socket(AF_INET, type, 0)); }
static long bind_(long s, const unsigned char *a, int len) { return rc(bind((int)s, (const void *)a, len)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long recv_(long s, char *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long setopt(long s, int level, int name, const void *v, int len) { return rc(setsockopt((int)s, level, name, v, len)); }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM6(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#define FAM4(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#define DGRAM SOCK_DGRAM
#define STREAM SOCK_STREAM
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
#define AF_INET6 10
#define IPPROTO_IPV6 41
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define IPV6_ADD_MEMBERSHIP 20
#define IPV6_MULTICAST_ALL 29
#define DGRAM 2
#define STREAM 1
static long sock6(int type) { return syscall3(117, AF_INET6, type, 0); }
static long sock4(int type) { return syscall3(117, AF_INET, type, 0); }
static long bind_(long s, const unsigned char *a, int len) { return syscall3(118, s, (long)a, len); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long recv_(long s, char *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long setopt(long s, int level, int name, const void *v, int len) { return syscall5(132, s, level, name, (long)v, len); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM6(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#define FAM4(a) do { (a)[0] = AF_INET; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello364:   ok   " : "hello364:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk6(unsigned char *s, const unsigned char *addr, int port, int scope) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM6(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (addr) for (int i = 0; i < 16; i++) s[8 + i] = addr[i];
    s[24] = (unsigned char)scope;
}
/* A UDP (or TCP) IPv6 socket bound to [addr%scope]:port; the negative errno when socket() or bind() fails. */
static long bound6(int type, const unsigned char *addr, int port, int scope, int reuse) {
    long s = sock6(type);
    if (s < 0) return s;
    int one = 1;
    if (reuse) setopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4);
    unsigned char a[28];
    mk6(a, addr, port, scope);
    long b = bind_(s, a, 28);
    if (b < 0) { close_(s); return b; }
    return s;
}
/* The sin6_scope_id getsockname reports for `s`, or the negative errno. */
static long scope_of(long s) {
    unsigned char a[28];
    for (int i = 0; i < 28; i++) a[i] = 0xee;
    long r = name_(s, a);
    if (r < 0) return r;
    return (long)a[24] | ((long)a[25] << 8) | ((long)a[26] << 16) | ((long)a[27] << 24);
}
static int count(long s) {
    char b[8];
    int n = 0;
    for (int t = 0; t < 10; t++) {
        pump();
        while (recv_(s, b, sizeof b) >= 0) n++;
    }
    return n;
}
static long join6(long s, const unsigned char *group, int ifindex) {
    unsigned char m[20];
    for (int i = 0; i < 20; i++) m[i] = 0;
    for (int i = 0; i < 16; i++) m[i] = group[i];
    m[16] = (unsigned char)ifindex;
    return setopt(s, IPPROTO_IPV6, IPV6_ADD_MEMBERSHIP, m, 20);
}

int main(void) {
    print("hello364: the interface an IPv6 socket is bound to\n");
    unsigned char ifl[16] = { 0xff, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char lln[16] = { 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char glb[16] = { 0xff, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char g64[16] = { 0xff, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x64 };
    unsigned char to[28];

    long s0 = bound6(DGRAM, ifl, 19400, 0, 0), s9 = bound6(DGRAM, ifl, 19400, 9, 0);
    snprintf(msg, sizeof msg, "S: ff01::1 scope 0 %ld (EINVAL), scope 9 %ld (ENODEV)", s0, s9);
    check(s0 == -22 && s9 == -19, msg);
    if (s0 >= 0) close_(s0);
    if (s9 >= 0) close_(s9);

    long b1 = bound6(DGRAM, lln, 19401, 1, 0), b2 = bound6(DGRAM, lln, 19401, 2, 0);
    snprintf(msg, sizeof msg, "B1: on 19401 ff02::1%%1 %ld and ff02::1%%2 %ld both bind", b1, b2);
    check(b1 >= 0 && b2 >= 0, msg);

    long c1 = bound6(DGRAM, lln, 19402, 2, 0), c2 = bound6(DGRAM, lln, 19402, 2, 0);
    long d1 = bound6(DGRAM, lln, 19403, 2, 0), d2 = bound6(DGRAM, 0, 19403, 0, 0);
    long e1 = bound6(DGRAM, 0, 19404, 0, 0), e2 = bound6(DGRAM, lln, 19404, 1, 0);
    snprintf(msg, sizeof msg, "B2: ff02::1%%2 twice %ld %ld; ff02::1%%2 then :: %ld %ld; :: then ff02::1%%1 %ld %ld (second of each EADDRINUSE)", c1, c2, d1, d2, e1, e2);
    check(c1 >= 0 && c2 == -98 && d1 >= 0 && d2 == -98 && e1 >= 0 && e2 == -98, msg);
    close_(c1); close_(d1); close_(e1);

    long f1 = bound6(DGRAM, glb, 19405, 0, 0), f2 = bound6(DGRAM, glb, 19405, 2, 0);
    snprintf(msg, sizeof msg, "B3: ff0e::1 then ff0e::1%%2 on 19405: %ld %ld (EADDRINUSE)", f1, f2);
    check(f1 >= 0 && f2 == -98, msg);

    long n3 = bound6(DGRAM, ifl, 19408, 2, 0), n4 = bound6(DGRAM, glb, 19409, 1, 0);
    long k1 = scope_of(b1), k2 = scope_of(b2), k3 = scope_of(n3), k4 = scope_of(n4);
    snprintf(msg, sizeof msg, "N: getsockname scope of ff02::1%%1 %ld, ff02::1%%2 %ld, ff01::1%%2 %ld, ff0e::1%%1 %ld (1 2 2 0)", k1, k2, k3, k4);
    check(k1 == 1 && k2 == 2 && k3 == 2 && k4 == 0, msg);
    close_(b1); close_(b2); close_(f1); close_(n3); close_(n4);

    long ra = bound6(DGRAM, lln, 19406, 1, 1), rb = bound6(DGRAM, lln, 19406, 2, 1);
    long tx = sock6(DGRAM);
    mk6(to, lln, 19406, 2);
    long sd = sendto_(tx, "dd", 2, to);
    int ga = count(ra), gb = count(rb);
    snprintf(msg, sizeof msg, "D: A ff02::1%%1 %ld, B ff02::1%%2 %ld on 19406; to [ff02::1%%2]:19406 %ld: A got %d, B got %d (0 1)", ra, rb, sd, ga, gb);
    check(ra >= 0 && rb >= 0 && sd == 2 && ga == 0 && gb == 1, msg);
    close_(ra); close_(rb);

    long rc_ = bound6(DGRAM, 0, 19407, 0, 1), rd = bound6(DGRAM, 0, 19407, 0, 1);
    int zero = 0;
    long jc = join6(rc_, g64, 1), za = setopt(rc_, IPPROTO_IPV6, IPV6_MULTICAST_ALL, &zero, 4), jd = join6(rd, g64, 2);
    mk6(to, g64, 19407, 0);
    long sj = sendto_(tx, "jj", 2, to);
    int gc = count(rc_), gd = count(rd);
    snprintf(msg, sizeof msg, "J: C joins ff0e::164 on lo (%ld), ALL 0 (%ld); D joins it on the NIC (%ld); a send through the NIC %ld: C got %d, D got %d (1 1)", jc, za, jd, sj, gc, gd);
    check(rc_ >= 0 && rd >= 0 && jc == 0 && za == 0 && jd == 0 && sj == 2 && gc == 1 && gd == 1, msg);
    close_(rc_); close_(rd);

    unsigned char g65[16] = { 0xff, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x65 };
    long re = bound6(DGRAM, 0, 19413, 0, 0), je = join6(re, g65, 1);
    mk6(to, g65, 19413, 0);
    long se = sendto_(tx, "ee", 2, to);
    int ge = count(re);
    snprintf(msg, sizeof msg, "J2: E joins ff0e::165 on lo only (%ld); a send through the NIC %ld: E got %d (0)", je, se, ge);
    check(re >= 0 && je == 0 && se == 2 && ge == 0, msg);
    close_(re); close_(tx);

    long t1 = bound6(STREAM, lln, 19410, 2, 0), t2 = bound6(STREAM, glb, 19411, 0, 0);
    long t4 = sock4(STREAM);
    unsigned char a4[16];
    for (int i = 0; i < 16; i++) a4[i] = 0;
    FAM4(a4);
    a4[2] = 19412 >> 8; a4[3] = 19412 & 0xff;
    a4[4] = 239; a4[5] = 1; a4[6] = 1; a4[7] = 1;
    long b4 = bind_(t4, a4, 16);
    snprintf(msg, sizeof msg, "T: IPv6 TCP binds [ff02::1%%2] %ld, [ff0e::1] %ld (EINVAL EINVAL); IPv4 TCP binds 239.1.1.1 %ld (0)", t1, t2, b4);
    check(t1 == -22 && t2 == -22 && b4 == 0, msg);
    if (t1 >= 0) close_(t1);
    if (t2 >= 0) close_(t2);
    close_(t4);

    print(failures ? "hello364: FAIL\n" : "hello364: PASS\n");
    return failures ? 1 : 0;
}
