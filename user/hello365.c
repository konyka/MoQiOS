/* hello365: the interface an IPv6 datagram leaves through. sendto's sin6_scope_id picks the outgoing interface for an address that
 * needs a scope, ahead of the interface the socket is bound to and IPV6_MULTICAST_IF (Linux udpv6_sendmsg: flowi6_oif from the
 * scope, else sk_bound_dev_if, else mcast_oif for a group); lo carries only ::1 and an interface that does not exist is no route
 * (ENETUNREACH). connect() to an address that needs a scope binds the socket to that interface, keeps it even when the connect
 * then fails, refuses a different one (EINVAL) and refuses none at all (EINVAL); a group with no scope uses IPV6_MULTICAST_IF
 * (__ip6_datagram_connect). A link-scoped group is sent from the link-local address. Measured on the host (build with -DHOST, run
 * in `unshare -rn` with a multicast dummy link d0, which is interface 2 there as eth0 is in MoQiOS:
 *   ip link set lo up; ip link add d0 type dummy; ip link set d0 multicast on up; ip addr add 10.0.2.15/24 dev d0;
 *   ip -6 addr add 2001:db8:1::7/64 dev d0 nodad; ip -6 route add default via 2001:db8:1::1 dev d0; every IPv6 socket V6ONLY):
 *   S1. an unbound socket sends to ff02::1 with scope 0 and 2, not 1 or 9 (ENETUNREACH), to ff0e::1%9 (a global group ignores
 *       the scope), not to fe80::1%1;
 *   S2. a socket bound to [ff02::1%1] sends to ff02::1 only with scope 2, not to ff0e::1 (both lo), but to ::1;
 *   S3. with IPV6_MULTICAST_IF 1 (lo) it sends to ff02::1%2, not to ff02::1 with scope 0;
 *   S4. that send to [ff02::1:5%2] reaches a socket that joined ff02::1:5 on the NIC (the copy loops back on the NIC);
 *   R.  a datagram to [ff02::1:6%2] comes from a link-local address with scope 2;
 *   C1. connect to ff02::1 with scope 0 and no IPV6_MULTICAST_IF is EINVAL, and the socket stays unconnected (EDESTADDRREQ);
 *   C2. connect to [ff02::1%2] succeeds, send works, getsockname names a link-local address with scope 2;
 *   C3. connect to [ff02::1%9] is ENETUNREACH, then [ff02::1%2] EINVAL (the failed connect left the socket on interface 9);
 *   C4. the socket connected to [ff02::1%2] sends to ff02::1%1 no (ENETUNREACH) and to ff0e::1 yes;
 *   C5. bound to [ff02::1%1], connect to [ff02::1%2] is EINVAL and to [ff02::1%1] ENETUNREACH;
 *   C6. with IPV6_MULTICAST_IF 2 connect to ff02::1 scope 0 succeeds and names scope 2; with IPV6_MULTICAST_IF 1 it is
 *       ENETUNREACH and leaves the socket on lo, so a connect to 2001:db8:1::9 then is ENETUNREACH too; a connect to ff0e::1
 *       (no scope needed) is ENETUNREACH without binding, and 2001:db8:1::9 then succeeds;
 *   C7. connect to [2001:db8:1::9%9] succeeds (a global address ignores the scope). */
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
static long sock6(void) {
    long s = rc(socket(AF_INET6, SOCK_DGRAM, 0));
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 28)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long send_(long s, const char *b, int n) { return rc(send((int)s, b, n, 0)); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { socklen_t l = 28; return rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l)); }
static long setopt(long s, int level, int name, const void *v, int len) { return rc(setsockopt((int)s, level, name, v, len)); }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM6(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET6 10
#define IPPROTO_IPV6 41
#define IPV6_MULTICAST_IF 17
#define IPV6_ADD_MEMBERSHIP 20
static long sock6(void) { return syscall3(117, AF_INET6, 2, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 28); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long send_(long s, const char *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { int l = 28; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static long setopt(long s, int level, int name, const void *v, int len) { return syscall5(132, s, level, name, (long)v, len); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM6(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello365:   ok   " : "hello365:   FAIL ");
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
static long send6(long s, const unsigned char *addr, int port, int scope) {
    unsigned char to[28];
    mk6(to, addr, port, scope);
    return sendto_(s, "x", 1, to);
}
static long conn6(long s, const unsigned char *addr, int port, int scope) {
    unsigned char to[28];
    mk6(to, addr, port, scope);
    return connect_(s, to);
}
static long bound6(const unsigned char *addr, int port, int scope) {
    long s = sock6();
    unsigned char a[28];
    mk6(a, addr, port, scope);
    long b = bind_(s, a);
    if (b < 0) { close_(s); return b; }
    return s;
}
static long join6(long s, const unsigned char *group, int ifindex) {
    unsigned char m[20];
    for (int i = 0; i < 20; i++) m[i] = 0;
    for (int i = 0; i < 16; i++) m[i] = group[i];
    m[16] = (unsigned char)ifindex;
    return setopt(s, IPPROTO_IPV6, IPV6_ADD_MEMBERSHIP, m, 20);
}
static long scope_at(const unsigned char *a) { return (long)a[24] | ((long)a[25] << 8) | ((long)a[26] << 16) | ((long)a[27] << 24); }
static int link_local(const unsigned char *a) { return a[8] == 0xfe && (a[9] & 0xc0) == 0x80; }
/* Datagrams waiting on `s`; the source of the last one in `from`. */
static int count(long s, unsigned char *from) {
    char b[8];
    int n = 0;
    for (int t = 0; t < 10; t++) {
        pump();
        while (recvfrom_(s, b, sizeof b, from) >= 0) n++;
    }
    return n;
}
int main(void) {
    print("hello365: the interface an IPv6 datagram leaves through\n");
    unsigned char lln[16] = { 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char glb[16] = { 0xff, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char ll1[16] = { 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char g5[16] = { 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 5 };
    unsigned char g6[16] = { 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 6 };
    unsigned char lo6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char uni[16] = { 0x20, 0x01, 0x0d, 0xb8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9 };
    unsigned char from[28], name[28];
    int one = 1, two = 2;

    long sink = bound6(0, 19509, 0);
    long u = sock6();
    long a0 = send6(u, lln, 19500, 0), a2 = send6(u, lln, 19500, 2), a1 = send6(u, lln, 19500, 1), a9 = send6(u, lln, 19500, 9);
    long ag = send6(u, glb, 19500, 9), al = send6(u, ll1, 19500, 1);
    snprintf(msg, sizeof msg, "S1: unbound to ff02::1 %%0 %ld %%2 %ld %%1 %ld %%9 %ld, ff0e::1%%9 %ld, fe80::1%%1 %ld (1 1 -101 -101 1 -101)", a0, a2, a1, a9, ag, al);
    check(a0 == 1 && a2 == 1 && a1 == -101 && a9 == -101 && ag == 1 && al == -101, msg);

    long b1 = bound6(lln, 19501, 1);
    long b0 = send6(b1, lln, 19500, 0), b2 = send6(b1, lln, 19500, 2), bg = send6(b1, glb, 19500, 0), bl = send6(b1, lo6, 19509, 0);
    snprintf(msg, sizeof msg, "S2: bound to ff02::1%%1 (%ld): to ff02::1 %%0 %ld %%2 %ld, ff0e::1 %ld, ::1 %ld (-101 1 -101 1)", b1, b0, b2, bg, bl);
    check(b1 >= 0 && b0 == -101 && b2 == 1 && bg == -101 && bl == 1, msg);

    long m = sock6();
    long mo = setopt(m, IPPROTO_IPV6, IPV6_MULTICAST_IF, &one, 4);
    long m2 = send6(m, lln, 19500, 2), m0 = send6(m, lln, 19500, 0);
    snprintf(msg, sizeof msg, "S3: IPV6_MULTICAST_IF lo (%ld): to ff02::1 %%2 %ld, %%0 %ld (1 -101)", mo, m2, m0);
    check(mo == 0 && m2 == 1 && m0 == -101, msg);

    long r = bound6(0, 19502, 0), jr = join6(r, g5, 2);
    long m5 = send6(m, g5, 19502, 2);
    int gr = count(r, from);
    snprintf(msg, sizeof msg, "S4: R joins ff02::1:5 on the NIC (%ld); the IF-lo socket sends to [ff02::1:5%%2] %ld: R got %d (1)", jr, m5, gr);
    check(r >= 0 && jr == 0 && m5 == 1 && gr == 1, msg);

    long r6 = bound6(0, 19503, 0), j6 = join6(r6, g6, 2);
    long u6 = send6(u, g6, 19503, 2);
    for (int i = 0; i < 28; i++) from[i] = 0;
    int g6n = count(r6, from);
    snprintf(msg, sizeof msg, "R: to [ff02::1:6%%2] (%ld, %ld): got %d from %s scope %ld (link-local, 2)", j6, u6, g6n, link_local(from) ? "link-local" : "not link-local", scope_at(from));
    check(j6 == 0 && u6 == 1 && g6n == 1 && link_local(from) && scope_at(from) == 2, msg);
    close_(r); close_(r6); close_(m);
    long c1 = sock6();
    long c1c = conn6(c1, lln, 19509, 0), c1s = send_(c1, "x", 1);
    snprintf(msg, sizeof msg, "C1: connect to ff02::1 scope 0 %ld (EINVAL), then send %ld (EDESTADDRREQ)", c1c, c1s);
    check(c1c == -22 && c1s == -89, msg);
    close_(c1);

    long c2 = sock6();
    long c2c = conn6(c2, lln, 19509, 2), c2s = send_(c2, "x", 1);
    for (int i = 0; i < 28; i++) name[i] = 0xee;
    long c2n = name_(c2, name);
    snprintf(msg, sizeof msg, "C2: connect to [ff02::1%%2] %ld, send %ld, getsockname %ld names a %s address, scope %ld (0 1 0 link-local 2)", c2c, c2s, c2n, link_local(name) ? "link-local" : "non-link-local", scope_at(name));
    check(c2c == 0 && c2s == 1 && c2n == 0 && link_local(name) && scope_at(name) == 2, msg);

    long c3 = sock6();
    long c39 = conn6(c3, lln, 19509, 9), c32 = conn6(c3, lln, 19509, 2);
    snprintf(msg, sizeof msg, "C3: connect to [ff02::1%%9] %ld (ENETUNREACH), then [ff02::1%%2] %ld (EINVAL)", c39, c32);
    check(c39 == -101 && c32 == -22, msg);
    close_(c3);

    long c41 = send6(c2, lln, 19509, 1), c4g = send6(c2, glb, 19509, 0);
    snprintf(msg, sizeof msg, "C4: connected to [ff02::1%%2]: sendto ff02::1%%1 %ld, ff0e::1 %ld (-101 1)", c41, c4g);
    check(c41 == -101 && c4g == 1, msg);
    close_(c2);

    long c52 = conn6(b1, lln, 19509, 2), c51 = conn6(b1, lln, 19509, 1);
    snprintf(msg, sizeof msg, "C5: bound to ff02::1%%1: connect %%2 %ld (EINVAL), %%1 %ld (ENETUNREACH)", c52, c51);
    check(c52 == -22 && c51 == -101, msg);
    close_(b1);

    long c6 = sock6();
    setopt(c6, IPPROTO_IPV6, IPV6_MULTICAST_IF, &two, 4);
    long c6c = conn6(c6, lln, 19509, 0);
    for (int i = 0; i < 28; i++) name[i] = 0xee;
    name_(c6, name);
    long c6k = scope_at(name);
    long c7 = sock6();
    setopt(c7, IPPROTO_IPV6, IPV6_MULTICAST_IF, &one, 4);
    long c7l = conn6(c7, lln, 19509, 0), c7u = conn6(c7, uni, 19509, 0);
    long c9 = sock6();
    setopt(c9, IPPROTO_IPV6, IPV6_MULTICAST_IF, &one, 4);
    long c9g = conn6(c9, glb, 19509, 0), c9u = conn6(c9, uni, 19509, 0);
    snprintf(msg, sizeof msg, "C6: IF 2 connect ff02::1 %ld scope %ld; IF lo: connect ff02::1 %ld then 2001:db8:1::9 %ld; connect ff0e::1 %ld then 2001:db8:1::9 %ld (0 2 -101 -101 -101 0)", c6c, c6k, c7l, c7u, c9g, c9u);
    check(c6c == 0 && c6k == 2 && c7l == -101 && c7u == -101 && c9g == -101 && c9u == 0, msg);
    close_(c6); close_(c7); close_(c9);

    long c8 = sock6();
    long c8c = conn6(c8, uni, 19509, 9);
    snprintf(msg, sizeof msg, "C7: connect to [2001:db8:1::9%%9] %ld (0)", c8c);
    check(c8c == 0, msg);
    close_(c8); close_(u); close_(sink);

    print(failures ? "hello365: FAIL\n" : "hello365: PASS\n");
    return failures ? 1 : 0;
}
