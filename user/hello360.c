/* hello360: a link-scoped IPv6 address names its interface (Linux inet6_bind, ipv6_addr_type & IPV6_ADDR_LINKLOCAL needs
 * sin6_scope_id). Measured on the host (build with -DHOST, run in `unshare -rn` with a dummy link d0, which is interface 2 there as
 * eth0 is in MoQiOS; every socket IPV6_V6ONLY):
 *   L. a UDP socket connected to [fe80::2%2]:9 names a link-local address L with scope 2;
 *   A. binding [L]:19001 with scope 0 is EINVAL, scope 99 ENODEV, scope 1 (lo) EADDRNOTAVAIL, scope 2 succeeds and getsockname
 *      reports scope 2;
 *   B. binding [ff02::1]:19002 with scope 0 is EINVAL, with scope 2 succeeds;
 *   C. a TCP socket binding [L]:19003 with scope 0 is EINVAL;
 *   D. an unbound UDP socket sends to [L%2]:19001; the datagram arrives with source L, scope 2. */
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
static long usock(void) { return v6only(rc(socket(AF_INET6, SOCK_DGRAM, 0))); }
static long tsock(void) { return v6only(rc(socket(AF_INET6, SOCK_STREAM, 0))); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 28)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) {
    socklen_t l = 28;
    return rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l));
}
static void pump(void) { struct timespec t = { 0, 10000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET6 10
static long usock(void) { return syscall3(117, AF_INET6, 2, 0); }
static long tsock(void) { return syscall3(117, AF_INET6, 1, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 28); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { int l = 28; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello360:   ok   " : "hello360:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* sockaddr_in6 for `addr` (16 bytes, or :: when null) on `port` with `scope`. */
static void mk(unsigned char *s, const unsigned char *addr, int port, unsigned scope) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (addr) for (int i = 0; i < 16; i++) s[8 + i] = addr[i];
    s[24] = (unsigned char)scope; s[25] = (unsigned char)(scope >> 8); s[26] = (unsigned char)(scope >> 16); s[27] = (unsigned char)(scope >> 24);
}
static unsigned scope_of(const unsigned char *s) { return (unsigned)s[24] | ((unsigned)s[25] << 8) | ((unsigned)s[26] << 16) | ((unsigned)s[27] << 24); }
static int port_of(const unsigned char *s) { return (s[2] << 8) | s[3]; }
static int is_ll(const unsigned char *s) { return s[8] == 0xfe && (s[9] & 0xc0) == 0x80; }
static int same_addr(const unsigned char *a, const unsigned char *b) {
    for (int i = 8; i < 24; i++) if (a[i] != b[i]) return 0;
    return 1;
}
static long bind_at(long s, const unsigned char *addr, int port, unsigned scope) {
    unsigned char a[28];
    mk(a, addr, port, scope);
    return bind_(s, a);
}
static long recv_wait(long s, char *b, int n, unsigned char *from) {
    long r = -11;
    for (int t = 0; t < 5000 && r == -11; t += 10) {
        r = recvfrom_(s, b, n, from);
        if (r == -11) pump();
    }
    return r;
}

int main(void) {
    print("hello360: a link-scoped IPv6 address names its interface\n");
    unsigned char peer[16] = { 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    unsigned char mc[16] = { 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char to[28], l[28], nm[28], from[28];

    mk(to, peer, 9, 2);
    long probe = usock();
    long cp = connect_(probe, to), np = name_(probe, l);
    snprintf(msg, sizeof msg, "L: a UDP socket connected to [fe80::2%%2] (%ld, getsockname %ld) names %s with scope %u (want link-local, 2)", cp, np,
             is_ll(l) ? "a link-local address" : "another address", scope_of(l));
    check(cp == 0 && np == 0 && is_ll(l) && scope_of(l) == 2, msg);
    close_(probe);
    unsigned char *ll = l + 8;

    long a = usock();
    long a0 = bind_at(a, ll, 19001, 0), a99 = bind_at(a, ll, 19001, 99), a1 = bind_at(a, ll, 19001, 1), a2 = bind_at(a, ll, 19001, 2);
    long an = name_(a, nm);
    snprintf(msg, sizeof msg, "A: [L]:19001 with scope 0 %ld (EINVAL), 99 %ld (ENODEV), 1 %ld (EADDRNOTAVAIL), 2 %ld; getsockname %ld scope %u port %d",
             a0, a99, a1, a2, an, scope_of(nm), port_of(nm));
    check(a0 == -22 && a99 == -19 && a1 == -99 && a2 == 0 && an == 0 && same_addr(nm, l) && scope_of(nm) == 2 && port_of(nm) == 19001, msg);

    long b = usock();
    long b0 = bind_at(b, mc, 19002, 0), b2 = bind_at(b, mc, 19002, 2);
    snprintf(msg, sizeof msg, "B: [ff02::1]:19002 with scope 0 %ld (EINVAL), with scope 2 %ld", b0, b2);
    check(b0 == -22 && b2 == 0, msg);
    close_(b);

    long c = tsock();
    long c0 = bind_at(c, ll, 19003, 0);
    snprintf(msg, sizeof msg, "C: a TCP socket binding [L]:19003 with scope 0 is EINVAL (%ld)", c0);
    check(c0 == -22, msg);
    close_(c);

    long tx = usock();
    unsigned char dst[28];
    mk(dst, ll, 19001, 2);
    long sd = sendto_(tx, "dd", 2, dst);
    char buf[8];
    long rd = recv_wait(a, buf, sizeof buf, from);
    snprintf(msg, sizeof msg, "D: a datagram to [L%%2]:19001 (%ld) arrives (%ld) from %s scope %u (want L, 2)", sd, rd,
             same_addr(from, l) ? "L" : "another address", scope_of(from));
    check(sd == 2 && rd == 2 && same_addr(from, l) && scope_of(from) == 2, msg);
    close_(tx);
    close_(a);

    print(failures ? "hello360: FAIL\n" : "hello360: PASS\n");
    return failures ? 1 : 0;
}
