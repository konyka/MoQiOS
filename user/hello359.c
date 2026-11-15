/* hello359: an IPv6 TCP socket's bound address takes part in port conflicts, listener choice, connection lookup, the source address
 * and getsockname (Linux inet6_bind sets sk_v6_rcv_saddr; inet6_csk_bind_conflict, inet6_lookup_listener, __inet6_lookup_established
 * and __inet6_check_established compare it). Measured on the host (build with -DHOST, run in `unshare -rn` with a dummy link holding
 * 2001:db8:1::7/64 and a default route on it; every socket IPV6_V6ONLY):
 *   G. a UDP socket connected to [2001:db8:9::8]:9 names a global address G;
 *   A. listeners on [::1]:18991 and [G]:18991 both bind and listen; [::]:18991 is EADDRINUSE;
 *   B. a SO_REUSEADDR client bound to [G]:18992 connects to [::1]:18991; the ::1 listener accepts it, the server sees peer [G]:18992,
 *      the client names [G]:18992 and its bytes arrive;
 *   C. the accepted socket names [::1]:18991; an unbound client connected to [::1]:18991 names ::1;
 *   D. a SO_REUSEADDR client bound to [::1]:18992 connects to [::1]:18991 (B's port pair and peer, another local address): the connect
 *      succeeds, the server sees peer [::1]:18992, and each server socket gets its own client's bytes;
 *   E. with only [G]:18993 listening, a connect to [::1]:18993 is ECONNREFUSED. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
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
static long sock(void) { return v6only(rc(socket(AF_INET6, SOCK_STREAM, 0))); }
static long usock(void) { return v6only(rc(socket(AF_INET6, SOCK_DGRAM, 0))); }
static long reuse(long s) { int one = 1; return rc(setsockopt((int)s, SOL_SOCKET, SO_REUSEADDR, &one, 4)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 28)); }
static long listen_(long s) { return rc(listen((int)s, 8)); }
static long accept_(long s) { return rc(accept4((int)s, 0, 0, SOCK_NONBLOCK)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long peer_(long s, unsigned char *a) { socklen_t l = 28; return rc(getpeername((int)s, (void *)a, &l)); }
static long send_(long s, const char *b, int n) { return rc(write((int)s, b, n)); }
static long recv_(long s, char *b, int n) { return rc(read((int)s, b, n)); }
static void pump(void) { struct timespec t = { 0, 10000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET6 10
static long sock(void) { return syscall3(117, AF_INET6, 1, 0); }
static long usock(void) { return syscall3(117, AF_INET6, 2, 0); }
static long reuse(long s) { int one = 1; return syscall5(132, s, 1, 2, (long)&one, 4); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 28); }
static long listen_(long s) { return syscall2(119, s, 8); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0x800); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long peer_(long s, unsigned char *a) { int l = 28; return syscall3(127, s, (long)a, (long)&l); }
static long send_(long s, const char *b, int n) { return write((int)s, b, n); }
static long recv_(long s, char *b, int n) { return read((int)s, b, n); }
static void pump(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif
#define LPORT 18991
#define CPORT 18992
#define EPORT 18993
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello359:   ok   " : "hello359:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* sockaddr_in6 on `port` for :: (kind 0), ::1 (kind 1) or the address in `g` (kind 2). */
static void mk(unsigned char *s, int kind, int port, const unsigned char *g) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (kind == 1) s[23] = 1;
    if (kind == 2) for (int i = 8; i < 24; i++) s[i] = g[i];
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
    if (same_addr(s, g)) return "G";
    int k = addr_kind(s);
    return k == 1 ? "::1" : k == 0 ? "::" : k == 2 ? "a link-local address" : "another address";
}
/* Accept from `l` for up to 10 s (a handshake frame lost on the loopback queue waits a 2 s RTO). */
static long accept_wait(long l) {
    long a = -11;
    for (int t = 0; t < 10000 && a < 0; t += 10) {
        a = accept_(l);
        if (a < 0) pump();
    }
    return a;
}
/* Read up to 3 bytes from the non-blocking accepted socket `s` within 10 s; returns 1 when they equal `want`. */
static int got(long s, const char *want) {
    char b[4] = { 0, 0, 0, 0 };
    int n = 0;
    for (int t = 0; t < 10000 && n < 3 && s >= 0; t += 10) {
        long r = recv_(s, b + n, 3 - n);
        if (r > 0) n += (int)r;
        else if (r == 0) break;
        else pump();
    }
    return n == 3 && memcmp(b, want, 3) == 0;
}
/* A SO_REUSEADDR client bound to kind:CPORT connected to `to`; *conn gets the connect result. */
static long client(int kind, const unsigned char *g, const unsigned char *to, long *conn) {
    unsigned char me[28];
    mk(me, kind, CPORT, g);
    long c = sock();
    reuse(c);
    long b = bind_(c, me);
    *conn = b == 0 ? connect_(c, to) : b;
    return c;
}

int main(void) {
    print("hello359: an IPv6 TCP socket's bound address takes part in conflicts, listener choice, lookup and naming\n");
    signal(SIGPIPE, SIG_IGN); /* a send on a connection the kernel mixed up fails as EPIPE instead of killing the test */
    unsigned char off[28], g[28], n[28], p[28], s1[28], s2[28], s0[28], e2[28], e1[28];

    mk(off, 0, 9, 0);
    off[8] = 0x20; off[9] = 0x01; off[10] = 0x0d; off[11] = 0xb8; off[13] = 9; off[23] = 8;
    long probe = usock();
    long cp = connect_(probe, off), np = name_(probe, g);
    for (int t = 0; t < 10000 && cp == 0 && np == 0 && addr_kind(g) != 3; t += 10) {
        pump(); /* SLAAC needs the router advertisement and duplicate address detection to finish */
        np = name_(probe, g);
    }
    snprintf(msg, sizeof msg, "G: a UDP socket connected off-link (%ld, getsockname %ld) names a global address (got %s)", cp, np,
             addr_kind(g) == 3 ? "G" : kind_name(g, off));
    check(cp == 0 && np == 0 && addr_kind(g) == 3, msg);
    close_(probe);

    mk(s1, 1, LPORT, g); mk(s2, 2, LPORT, g); mk(s0, 0, LPORT, g);
    long l1 = sock(), l2 = sock(), l0 = sock();
    long b1 = bind_(l1, s1), b2 = bind_(l2, s2);
    long li1 = listen_(l1), li2 = listen_(l2);
    long b0 = bind_(l0, s0);
    snprintf(msg, sizeof msg, "A: [::1]:%d and [G]:%d bind (%ld, %ld) and listen (%ld, %ld); [::]:%d is EADDRINUSE (%ld)", LPORT, LPORT, b1, b2,
             li1, li2, LPORT, b0);
    check(b1 == 0 && b2 == 0 && li1 == 0 && li2 == 0 && b0 == -98, msg);
    close_(l0);

    long r1 = -1;
    long c1 = client(2, g, s1, &r1);
    long a1 = accept_wait(l1);
    long pa1 = a1 >= 0 ? peer_(a1, p) : a1, nc1 = name_(c1, n);
    int peer_g = pa1 == 0 && same_addr(p, g) && port_of(p) == CPORT, name_g = nc1 == 0 && same_addr(n, g) && port_of(n) == CPORT;
    long w1 = send_(c1, "one", 3);
    int g1 = got(a1, "one");
    snprintf(msg, sizeof msg, "B: a client bound to [G]:%d connects to [::1]:%d (%ld), the ::1 listener accepts (%ld) peer %s:%d, the client names %s:%d, "
             "its bytes arrive (%ld, %d)", CPORT, LPORT, r1, a1, kind_name(p, g), port_of(p), kind_name(n, g), port_of(n), w1, g1);
    check(r1 == 0 && a1 >= 0 && peer_g && name_g && w1 == 3 && g1, msg);

    long na1 = a1 >= 0 ? name_(a1, n) : a1;
    int a1_loop = na1 == 0 && addr_kind(n) == 1 && port_of(n) == LPORT;
    long cu = sock();
    long ru = connect_(cu, s1);
    unsigned char nu[28];
    long nuu = name_(cu, nu);
    long au = accept_wait(l1);
    snprintf(msg, sizeof msg, "C: the accepted socket names %s:%d (want ::1:%d); an unbound client connected to ::1 (%ld, accepted %ld) names %s",
             kind_name(n, g), port_of(n), LPORT, ru, au, kind_name(nu, g));
    check(a1_loop && ru == 0 && au >= 0 && nuu == 0 && addr_kind(nu) == 1, msg);
    close_(cu);
    if (au >= 0) close_(au);

    long r2 = -1;
    long c2 = client(1, g, s1, &r2);
    long a2 = accept_wait(l1);
    long pa2 = a2 >= 0 ? peer_(a2, p) : a2;
    int peer_l = pa2 == 0 && addr_kind(p) == 1 && port_of(p) == CPORT;
    long w2 = send_(c2, "two", 3);
    int g2 = got(a2, "two");
    long w1b = send_(c1, "uno", 3);
    int g1b = got(a1, "uno");
    snprintf(msg, sizeof msg, "D: a client bound to [::1]:%d connects to [::1]:%d too (%ld), accepted (%ld) with peer %s:%d, each server socket gets "
             "its own bytes (%ld %d, %ld %d)", CPORT, LPORT, r2, a2, kind_name(p, g), port_of(p), w2, g2, w1b, g1b);
    check(r2 == 0 && a2 >= 0 && peer_l && w2 == 3 && g2 && w1b == 3 && g1b, msg);

    mk(e2, 2, EPORT, g); mk(e1, 1, EPORT, g);
    long l4 = sock();
    long b4 = bind_(l4, e2), li4 = listen_(l4);
    long c5 = sock();
    long r5 = connect_(c5, e1);
    snprintf(msg, sizeof msg, "E: with only [G]:%d listening (%ld, %ld), a connect to [::1]:%d is ECONNREFUSED (%ld)", EPORT, b4, li4, EPORT, r5);
    check(b4 == 0 && li4 == 0 && r5 == -111, msg);

    close_(c5); close_(l4);
    if (a2 >= 0) close_(a2);
    close_(c2);
    if (a1 >= 0) close_(a1);
    close_(c1);
    close_(l2); close_(l1);
    print(failures ? "hello359: FAIL\n" : "hello359: PASS\n");
    return failures ? 1 : 0;
}
