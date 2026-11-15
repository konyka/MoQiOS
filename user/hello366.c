/* hello366: connect(AF_UNSPEC) dissolves a UDP association. An address whose family is AF_UNSPEC (any length from the family field
 * on) disconnects the socket: the peer filter goes, getpeername is ENOTCONN, send without a destination is EDESTADDRREQ, and the
 * bound address and port stay; an address shorter than the family field is EINVAL (Linux inet_dgram_connect, __udp_disconnect).
 * The interface the socket was tied to goes as well, also one a scoped bind set. A family that does not match the socket is
 * EAFNOSUPPORT. Measured on the host (build with -DHOST, run in `unshare -rn` with lo up and a multicast dummy link d0, which is
 * interface 2 there as eth0 is in MoQiOS; every IPv6 socket V6ONLY):
 *   U1. a socket bound to 127.0.0.1:19602 and connected to :19600 drops a datagram from :19601 and takes one from :19600;
 *       AF_UNSPEC (length 16) returns 0, then getpeername is ENOTCONN, send EDESTADDRREQ, the datagram from :19601 arrives and
 *       getsockname still names 127.0.0.1:19602;
 *   U2. AF_UNSPEC with length 2 returns 0, with length 1 EINVAL;
 *   U3. U1 over IPv6 with ::1 (ports 19610-19612); getsockname names [::1%0]:19612;
 *   U4. a socket bound to [ff02::1%1] names scope 0 after AF_UNSPEC, and connect to [ff02::1%2] then succeeds;
 *   U5. connected to [ff02::1%2], after AF_UNSPEC it names :: with scope 0, and connect to [ff02::1%1] is ENETUNREACH (not EINVAL:
 *       the socket is no longer on interface 2);
 *   U6. bound to 0.0.0.0:19603 and connected to 127.0.0.1:19600 it names 127.0.0.1:19603, after AF_UNSPEC 0.0.0.0:19603;
 *   U7. an IPv6 socket connecting to an AF_INET address and an IPv4 socket to an AF_INET6 one get EAFNOSUPPORT.
 * Linux also releases an automatically chosen port on AF_UNSPEC (getsockname then names port 0); MoQiOS gives every socket its
 * port at socket(), so this test does not look at the port of a socket that never bound. */
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
static long sock4(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long sock6(void) {
    long s = rc(socket(AF_INET6, SOCK_DGRAM, 0));
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long bind_(long s, const unsigned char *a, int l) { return rc(bind((int)s, (const void *)a, l)); }
static long connect_(long s, const unsigned char *a, int l) { return rc(connect((int)s, (const void *)a, l)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long peer_(long s, unsigned char *a) { socklen_t l = 28; return rc(getpeername((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to, int l) { return rc(sendto((int)s, b, n, 0, (const void *)to, l)); }
static long send_(long s, const char *b, int n) { return rc(send((int)s, b, n, 0)); }
static long recv_(long s, char *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
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
static long sock4(void) { return syscall3(117, AF_INET, 2, 0); }
static long sock6(void) { return syscall3(117, AF_INET6, 2, 0); }
static long bind_(long s, const unsigned char *a, int l) { return syscall3(118, s, (long)a, l); }
static long connect_(long s, const unsigned char *a, int l) { return syscall3(124, s, (long)a, l); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long peer_(long s, unsigned char *a) { int l = 28; return syscall3(127, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to, int l) { return syscall6(121, s, (long)b, n, 0, (long)to, l); }
static long send_(long s, const char *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recv_(long s, char *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
static int failures;
static void check(int ok, const char *w) {
    print(ok ? "hello366:   ok   " : "hello366:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, int a0, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (a0) { s[4] = (unsigned char)a0; s[7] = 1; }
}
static void mk6(unsigned char *s, const unsigned char *addr, int port, int scope) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s, AF_INET6);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (addr) for (int i = 0; i < 16; i++) s[8 + i] = addr[i];
    s[24] = (unsigned char)scope;
}
static long unspec(long s, int len) {
    unsigned char a[28];
    for (int i = 0; i < 28; i++) a[i] = 0;
    return connect_(s, a, len);
}
static int port_of(const unsigned char *a) { return (a[2] << 8) | a[3]; }
static long scope_at(const unsigned char *a) { return (long)a[24] | ((long)a[25] << 8) | ((long)a[26] << 16) | ((long)a[27] << 24); }
static int is_zero(const unsigned char *a, int n) { for (int i = 0; i < n; i++) if (a[i]) return 0; return 1; }
static int count(long s) {
    char b[8];
    int n = 0;
    for (int t = 0; t < 10; t++) {
        pump();
        while (recv_(s, b, sizeof b) >= 0) n++;
    }
    return n;
}
static long bound4(int a0, int port) {
    unsigned char a[16];
    long s = sock4();
    mk4(a, a0, port);
    long b = bind_(s, a, 16);
    if (b < 0) { close_(s); return b; }
    return s;
}
static long bound6(const unsigned char *addr, int port, int scope) {
    unsigned char a[28];
    long s = sock6();
    mk6(a, addr, port, scope);
    long b = bind_(s, a, 28);
    if (b < 0) { close_(s); return b; }
    return s;
}
static char msg[400];
int main(void) {
    print("hello366: connect(AF_UNSPEC) dissolves a UDP association\n");
    unsigned char lo6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char lln[16] = { 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char a[28], name[28], to[28];

    long p0 = bound4(127, 19600), p1 = bound4(127, 19601), s = bound4(127, 19602);
    mk4(a, 127, 19600);
    long c = connect_(s, a, 16);
    mk4(to, 127, 19602);
    sendto_(p1, "x", 1, to, 16);
    sendto_(p0, "x", 1, to, 16);
    int before = count(s);
    long d = unspec(s, 16);
    long gp = peer_(s, name), sn = send_(s, "x", 1);
    sendto_(p1, "x", 1, to, 16);
    int after = count(s);
    long gn = name_(s, name);
    int keep = gn == 0 && name[4] == 127 && name[7] == 1 && port_of(name) == 19602;
    snprintf(msg, sizeof msg, "U1: bind %ld connect %ld, before %d (1); AF_UNSPEC %ld, getpeername %ld, send %ld, from :19601 %d, name kept %d (0 -107 -89 1 1)", s, c, before, d, gp, sn, after, keep);
    check(s >= 0 && c == 0 && before == 1 && d == 0 && gp == -107 && sn == -89 && after == 1 && keep, msg);

    connect_(s, a, 16);
    long d2 = unspec(s, 2);
    long gp2 = peer_(s, name);
    long d1 = unspec(s, 1);
    snprintf(msg, sizeof msg, "U2: AF_UNSPEC length 2 %ld then getpeername %ld, length 1 %ld (0 -107 -22)", d2, gp2, d1);
    check(d2 == 0 && gp2 == -107 && d1 == -22, msg);
    close_(s); close_(p0); close_(p1);

    long q0 = bound6(lo6, 19610, 0), q1 = bound6(lo6, 19611, 0), t = bound6(lo6, 19612, 0);
    mk6(a, lo6, 19610, 0);
    long c6 = connect_(t, a, 28);
    mk6(to, lo6, 19612, 0);
    sendto_(q1, "x", 1, to, 28);
    sendto_(q0, "x", 1, to, 28);
    int before6 = count(t);
    long d6 = unspec(t, 28);
    long gp6 = peer_(t, name), sn6 = send_(t, "x", 1);
    sendto_(q1, "x", 1, to, 28);
    int after6 = count(t);
    long gn6 = name_(t, name);
    int keep6 = gn6 == 0 && name[23] == 1 && is_zero(name + 8, 15) && port_of(name) == 19612 && scope_at(name) == 0;
    snprintf(msg, sizeof msg, "U3: bind %ld connect %ld, before %d (1); AF_UNSPEC %ld, getpeername %ld, send %ld, from :19611 %d, name kept %d (0 -107 -89 1 1)", t, c6, before6, d6, gp6, sn6, after6, keep6);
    check(t >= 0 && c6 == 0 && before6 == 1 && d6 == 0 && gp6 == -107 && sn6 == -89 && after6 == 1 && keep6, msg);
    close_(t); close_(q0); close_(q1);

    long b = bound6(lln, 19604, 1);
    long bd = unspec(b, 28);
    long bn = name_(b, name);
    long bs = scope_at(name);
    mk6(a, lln, 19609, 2);
    long bc = connect_(b, a, 28);
    snprintf(msg, sizeof msg, "U4: bound to [ff02::1%%1] (%ld): AF_UNSPEC %ld, name %ld scope %ld, connect [ff02::1%%2] %ld (0 0 0 0)", b, bd, bn, bs, bc);
    check(b >= 0 && bd == 0 && bn == 0 && bs == 0 && bc == 0, msg);
    close_(b);

    long m = sock6();
    mk6(a, lln, 19609, 2);
    long mc = connect_(m, a, 28);
    long md = unspec(m, 28);
    long mn = name_(m, name);
    int mwild = mn == 0 && is_zero(name + 8, 16) && scope_at(name) == 0;
    mk6(a, lln, 19609, 1);
    long m1 = connect_(m, a, 28);
    snprintf(msg, sizeof msg, "U5: connect [ff02::1%%2] %ld, AF_UNSPEC %ld, names :: scope 0 %d, connect [ff02::1%%1] %ld (0 0 1 -101)", mc, md, mwild, m1);
    check(mc == 0 && md == 0 && mwild && m1 == -101, msg);
    close_(m);

    long w = bound4(0, 19603);
    mk4(a, 127, 19600);
    long wc = connect_(w, a, 16);
    long wn = name_(w, name);
    int wcon = wn == 0 && name[4] == 127 && name[7] == 1 && port_of(name) == 19603;
    long wd = unspec(w, 16);
    long wn2 = name_(w, name);
    int wwild = wn2 == 0 && is_zero(name + 4, 4) && port_of(name) == 19603;
    snprintf(msg, sizeof msg, "U6: bound 0.0.0.0:19603 connect %ld names 127.0.0.1 %d, AF_UNSPEC %ld names 0.0.0.0:19603 %d (0 1 0 1)", wc, wcon, wd, wwild);
    check(wc == 0 && wcon && wd == 0 && wwild, msg);
    close_(w);

    long v6 = sock6(), v4 = sock4();
    mk4(a, 127, 19600);
    long x6 = connect_(v6, a, 16);
    mk6(to, lo6, 19610, 0);
    long x4 = connect_(v4, to, 28);
    snprintf(msg, sizeof msg, "U7: IPv6 socket to AF_INET %ld, IPv4 socket to AF_INET6 %ld (-97 -97)", x6, x4);
    check(x6 == -97 && x4 == -97, msg);
    close_(v6); close_(v4);

    print(failures ? "hello366: FAIL\n" : "hello366: PASS\n");
    return failures ? 1 : 0;
}
