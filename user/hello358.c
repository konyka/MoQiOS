/* hello358: an IPv6 UDP datagram leaves from the address its socket is bound to (Linux ip6_datagram_send / fl6.saddr =
 * sk_v6_rcv_saddr), also when it goes to ::1. Measured on the host (build with -DHOST, run in `unshare -rn` with a dummy link
 * holding 2001:db8:1::7/64 and a default route on it):
 *   A. a socket connected to [2001:db8:9::8]:9 names a global address G (not ::, ::1 or fe80::/10); MoQiOS gets one from the
 *      QEMU user network's router advertisement (fec0::/64), so the test waits up to 10 s for it;
 *   B. a socket bound to [G]:18982 sends to [::1]:18981 with sendto; the datagram arrives with source [G]:18982;
 *   C. the same socket connected to [::1]:18981 sends with sendmsg and no name; the datagram again comes from [G]:18982;
 *   D. a socket bound to [::]:18983 sends to [::1]:18981; the datagram comes from [::1]:18983. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(void) {
    long s = rc(socket(AF_INET6, SOCK_DGRAM, 0));
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long conn_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 28)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long sendmsg_(long s, const char *b, int n) {
    struct iovec v = { (void *)b, (size_t)n };
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &v;
    m.msg_iovlen = 1;
    return rc(sendmsg((int)s, &m, 0));
}
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
static long sock(void) { return syscall3(117, AF_INET6, 2, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long conn_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 28); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long sendmsg_(long s, const char *b, int n) {
    long v[2] = { (long)b, n };
    long m[7] = { 0, 0, (long)v, 1, 0, 0, 0 };
    return syscall3(129, s, (long)m, 0);
}
static long recvfrom_(long s, char *b, int n, unsigned char *from) { int l = 28; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello358:   ok   " : "hello358:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* sockaddr_in6 for :: (kind 0) or ::1 (kind 1) on `port`. */
static void mk(unsigned char *s, int kind, int port) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[23] = (unsigned char)kind;
}
static int port_of(const unsigned char *s) { return (s[2] << 8) | s[3]; }
static int same_addr(const unsigned char *a, const unsigned char *b) {
    for (int i = 8; i < 24; i++) if (a[i] != b[i]) return 0;
    return 1;
}
/* 1 for ::1, 0 for ::, 2 for fe80::/10, 3 for anything else. */
static int addr_kind(const unsigned char *s) {
    if (s[8] == 0xfe && (s[9] & 0xc0) == 0x80) return 2;
    for (int i = 8; i < 23; i++) if (s[i]) return 3;
    return s[23] == 1 ? 1 : s[23] == 0 ? 0 : 3;
}
static const char *kind_name(const unsigned char *s, const unsigned char *g) {
    if (g && same_addr(s, g)) return "G";
    int k = addr_kind(s);
    return k == 1 ? "::1" : k == 0 ? "::" : k == 2 ? "a link-local address" : "another address";
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
    print("hello358: an IPv6 UDP datagram leaves from its socket's bound address\n");
    unsigned char off[28], g[28], rx_a[28], to[28], any3[28], from[28];
    mk(off, 0, 9);
    off[8] = 0x20; off[9] = 0x01; off[10] = 0x0d; off[11] = 0xb8; off[12] = 0; off[13] = 9; off[23] = 8;
    mk(rx_a, 1, 18981); mk(to, 1, 18981); mk(any3, 0, 18983);

    long probe = sock();
    long cp = conn_(probe, off), np = name_(probe, g);
    int kg = addr_kind(g);
    for (int t = 0; t < 10000 && cp == 0 && np == 0 && kg != 3; t += 10) {
        pump(); /* SLAAC needs the router advertisement and duplicate address detection to finish */
        np = name_(probe, g);
        kg = addr_kind(g);
    }
    snprintf(msg, sizeof msg, "A: a socket connected off-link (%ld, getsockname %ld) names a global address (got %s)", cp, np,
             kind_name(g, 0));
    check(cp == 0 && np == 0 && kg == 3, msg);
    close_(probe);

    long rx = sock();
    long brx = bind_(rx, rx_a);
    long tx = sock();
    g[2] = 18982 >> 8; g[3] = 18982 & 0xff;
    for (int i = 4; i < 8; i++) g[i] = 0;
    for (int i = 24; i < 28; i++) g[i] = 0;
    long btx = bind_(tx, g);
    char buf[8];
    long sb = sendto_(tx, "bb", 2, to);
    long rb = recv_wait(rx, buf, sizeof buf, from);
    snprintf(msg, sizeof msg, "B: bound to [G]:18982 (rx %ld, tx %ld), sendto ::1 (%ld) arrives (%ld) from %s port %d (want G port 18982)",
             brx, btx, sb, rb, kind_name(from, g), port_of(from));
    check(brx == 0 && btx == 0 && sb == 2 && rb == 2 && same_addr(from, g) && port_of(from) == 18982, msg);

    long cc = conn_(tx, to);
    long sc = sendmsg_(tx, "ccc", 3);
    long rcv = recv_wait(rx, buf, sizeof buf, from);
    snprintf(msg, sizeof msg, "C: connected to ::1 (%ld), sendmsg (%ld) arrives (%ld) from %s port %d (want G port 18982)", cc, sc, rcv,
             kind_name(from, g), port_of(from));
    check(cc == 0 && sc == 3 && rcv == 3 && same_addr(from, g) && port_of(from) == 18982, msg);
    close_(tx);

    long tw = sock();
    long bw = bind_(tw, any3);
    long sd = sendto_(tw, "dddd", 4, to);
    long rd = recv_wait(rx, buf, sizeof buf, from);
    snprintf(msg, sizeof msg, "D: bound to [::]:18983 (%ld), sendto ::1 (%ld) arrives (%ld) from %s port %d (want ::1 port 18983)", bw, sd, rd,
             kind_name(from, g), port_of(from));
    check(bw == 0 && sd == 4 && rd == 4 && addr_kind(from) == 1 && port_of(from) == 18983, msg);
    close_(tw);
    close_(rx);

    print(failures ? "hello358: FAIL\n" : "hello358: PASS\n");
    return failures ? 1 : 0;
}
