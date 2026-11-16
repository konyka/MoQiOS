/* hello367: the interface an IPv6 TCP connect goes through. A group is ENETUNREACH whatever its scope; a link-local peer needs an
 * interface: sin6_scope_id ties the socket to it, it must match the interface a scoped bind set (EINVAL), and with neither it is
 * EINVAL. A failed route check (an interface that does not exist, or lo, which carries only ::1) is ENETUNREACH and leaves the
 * socket tied, so a later connect with another scope is EINVAL. Any other address ignores the scope (Linux tcp_v6_connect).
 * Measured on the host (build with -DHOST, run in `unshare -rn` with lo up and a multicast dummy link d0, which is interface 2
 * there as eth0 is in MoQiOS:
 *   ip link set lo up; ip link add d0 type dummy; ip link set d0 multicast on up; ip -6 addr add fe80::7/64 dev d0 nodad;
 *   every IPv6 socket V6ONLY; fe80::1 does not answer, so a non-blocking connect to it is EINPROGRESS):
 *   G.  connect to [ff02::1%2], [ff02::1] and [ff0e::1] is ENETUNREACH;
 *   N.  connect to fe80::1 with no scope is EINVAL, and the socket then connects to [fe80::1%2] (EINPROGRESS);
 *   S.  connect to [fe80::1%2] is EINPROGRESS and getsockname names a link-local address with scope 2;
 *   X.  connect to [fe80::1%9] is ENETUNREACH, then [fe80::1%2] EINVAL;
 *   L.  connect to [fe80::1%1] is ENETUNREACH;
 *   B.  bound to its own link-local address with scope 2, connect to [fe80::1%1] is EINVAL and to fe80::1 with no scope EINPROGRESS;
 *   U.  connect to [::1%9] reaches a listener on ::1 (a global or loopback peer ignores the scope). */
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
static long v6only(long s) {
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long tsock(void) { return v6only(rc(socket(AF_INET6, SOCK_STREAM, 0))); }
static long nbsock(void) { return v6only(rc(socket(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK, 0))); }
static long usock(void) { return v6only(rc(socket(AF_INET6, SOCK_DGRAM, 0))); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 28)); }
static long listen_(long s) { return rc(listen((int)s, 8)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET6 10
static long tsock(void) { return syscall3(117, AF_INET6, 1, 0); }
static long nbsock(void) { return syscall3(117, AF_INET6, 1 | 0x800, 0); }
static long usock(void) { return syscall3(117, AF_INET6, 2, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 28); }
static long listen_(long s) { return syscall2(119, s, 8); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif
#define EINPROGRESS_ (-115)
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello367:   ok   " : "hello367:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk6(unsigned char *s, const unsigned char *addr, int port, int scope) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (addr) for (int i = 0; i < 16; i++) s[8 + i] = addr[i];
    s[24] = (unsigned char)scope;
}
static long conn6(long s, const unsigned char *addr, int port, int scope) {
    unsigned char to[28];
    mk6(to, addr, port, scope);
    return connect_(s, to);
}
static long scope_at(const unsigned char *a) { return (long)a[24] | ((long)a[25] << 8) | ((long)a[26] << 16) | ((long)a[27] << 24); }
static int link_local(const unsigned char *a) { return a[8] == 0xfe && (a[9] & 0xc0) == 0x80; }
int main(void) {
    print("hello367: the interface an IPv6 TCP connect goes through\n");
    unsigned char lln[16] = { 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char glb[16] = { 0xff, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char ll1[16] = { 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char lo6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char name[28], own[28];

    long g = nbsock();
    long g2 = conn6(g, lln, 19701, 2), g0 = conn6(g, lln, 19701, 0), ge = conn6(g, glb, 19701, 0);
    snprintf(msg, sizeof msg, "G: connect to [ff02::1%%2] %ld, [ff02::1] %ld, [ff0e::1] %ld (-101 -101 -101)", g2, g0, ge);
    check(g2 == -101 && g0 == -101 && ge == -101, msg);
    close_(g);

    long n = nbsock();
    long n0 = conn6(n, ll1, 19701, 0), n2 = conn6(n, ll1, 19701, 2);
    snprintf(msg, sizeof msg, "N: connect to fe80::1 without a scope %ld, then [fe80::1%%2] %ld (-22 -115)", n0, n2);
    check(n0 == -22 && n2 == EINPROGRESS_, msg);
    close_(n);

    long s = nbsock();
    long s2 = conn6(s, ll1, 19702, 2);
    long sn = name_(s, name);
    int sll = link_local(name);
    long ss = scope_at(name);
    snprintf(msg, sizeof msg, "S: connect to [fe80::1%%2] %ld, getsockname %ld link-local %d scope %ld (-115 0 1 2)", s2, sn, sll, ss);
    check(s2 == EINPROGRESS_ && sn == 0 && sll && ss == 2, msg);
    close_(s);

    long x = nbsock();
    long x9 = conn6(x, ll1, 19703, 9), x2 = conn6(x, ll1, 19703, 2);
    snprintf(msg, sizeof msg, "X: connect to [fe80::1%%9] %ld, then [fe80::1%%2] %ld (-101 -22)", x9, x2);
    check(x9 == -101 && x2 == -22, msg);
    close_(x);

    long l = nbsock();
    long l1 = conn6(l, ll1, 19704, 1);
    snprintf(msg, sizeof msg, "L: connect to [fe80::1%%1] %ld (-101)", l1);
    check(l1 == -101, msg);
    close_(l);

    /* Our own link-local address: the source a datagram to ff02::1%2 is sent from. */
    long u = usock();
    long uc = conn6(u, lln, 19705, 2);
    long un = name_(u, own);
    close_(u);
    long b = nbsock();
    own[2] = 0; own[3] = 0;
    long bb = bind_(b, own);
    long b1 = conn6(b, ll1, 19706, 1), b0 = conn6(b, ll1, 19706, 0);
    snprintf(msg, sizeof msg, "B: own link-local %ld/%ld (%d), bind with scope 2 %ld, connect [fe80::1%%1] %ld, fe80::1 %ld (0 0 1 0 -22 -115)", uc, un, link_local(own), bb, b1, b0);
    check(uc == 0 && un == 0 && link_local(own) && scope_at(own) == 2 && bb == 0 && b1 == -22 && b0 == EINPROGRESS_, msg);
    close_(b);

    long lis = tsock();
    unsigned char la[28];
    mk6(la, lo6, 19707, 0);
    long lb = bind_(lis, la), ll = listen_(lis);
    long c = tsock();
    long c9 = conn6(c, lo6, 19707, 9);
    snprintf(msg, sizeof msg, "U: listener on ::1 (%ld %ld), connect to [::1%%9] %ld (0 0 0)", lb, ll, c9);
    check(lb == 0 && ll == 0 && c9 == 0, msg);
    close_(c); close_(lis);

    print(failures ? "hello367: FAIL\n" : "hello367: PASS\n");
    return failures ? 1 : 0;
}
