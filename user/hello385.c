/* hello385: an unbound UDP socket has no local port until it is named (net/ipv4/af_inet.c inet_send_prepare -> inet_autobind,
 * ip4_datagram_connect / ip6_datagram_connect, net/ipv4/udp.c __udp_disconnect). Measured on the host (build with -DHOST, run as
 * root in `unshare --map-auto --map-root-user -n` after `ip link set lo up`):
 *   A. a fresh IPv4 UDP socket's getsockname port is 0, and still 0 after a recv that finds nothing; the first sendto (to
 *      127.0.0.1:9) gives it a port;
 *   R. a datagram another socket sends to that port is received; after connect(AF_UNSPEC) the socket names port 0 again and a
 *      datagram to the old port is not received (EAGAIN);
 *   D. the old port is free after the disconnect: another socket binds it; the first socket's next sendto gives it another port;
 *   C. connect names a port, connect(AF_UNSPEC) gives it up (0);
 *   B. bind to port 0 names a port, which connect + connect(AF_UNSPEC) gives up; a port the user chose (40385) stays;
 *   W. a socket bound to 127.0.0.1 port 0 keeps the address and loses the port on connect(AF_UNSPEC);
 *   E. a send that fails still names the port: send without a peer (EDESTADDRREQ) and sendto with a 4-byte address (EINVAL);
 *   V. the same for IPv6: a fresh socket names port 0, sendto [::1]:9 names one, connect(AF_UNSPEC) gives it up. */
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
static void close_s(long s) { close((int)s); }
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
static void close_s(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[480];
static void check(int ok, const char *w) {
    print(ok ? "hello385:   ok   " : "hello385:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, int port, int lo) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (lo) { s[4] = 127; s[7] = 1; }
}
static void mk6(unsigned char *s, int port) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s, AF_INET6);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[23] = 1;
}
static long port_of(long s) {
    unsigned char a[28];
    long r = name_(s, a);
    if (r < 0) return r;
    return (a[2] << 8) | a[3];
}
static long unspec(long s) { unsigned char u[16] = { 0 }; return connect_(s, u, 16); }
static long recv_wait(long s) {
    char b[8];
    long r = -11;
    for (int i = 0; i < 25 && r == -11; i++) { r = recv_(s, b, sizeof b); if (r == -11) pump(); }
    return r;
}
int main(void) {
    print("hello385: an unbound UDP socket has no port until it is named\n");
    unsigned char to9[16], a[28];
    char b[8];
    mk4(to9, 9, 1);

    long s = sock4();
    long a1 = port_of(s), a2 = recv_(s, b, sizeof b), a3 = port_of(s);
    long a4 = sendto_(s, "x", 1, to9, 16), a5 = port_of(s);
    snprintf(msg, sizeof msg, "A: fresh port %ld; recv %ld, port %ld; sendto %ld, port %ld (0 -11 0 1 >0)", a1, a2, a3, a4, a5);
    check(a1 == 0 && a2 == -11 && a3 == 0 && a4 == 1 && a5 > 0, msg);

    long other = sock4();
    unsigned char back[16];
    mk4(back, (int)a5, 1);
    long r1 = sendto_(other, "hi", 2, back, 16), r2 = recv_wait(s);
    long r3 = unspec(s), r4 = port_of(s);
    long r5 = sendto_(other, "hi", 2, back, 16), r6 = recv_wait(s);
    snprintf(msg, sizeof msg, "R: to its port %ld, received %ld; disconnect %ld, port %ld; to the old port %ld, received %ld (2 2 0 0 2 -11)", r1, r2, r3, r4, r5, r6);
    check(r1 == 2 && r2 == 2 && r3 == 0 && r4 == 0 && r5 == 2 && r6 == -11, msg);

    long t = sock4();
    unsigned char old[16];
    mk4(old, (int)a5, 0);
    long d1 = bind_(t, old, 16), d2 = sendto_(s, "x", 1, to9, 16), d3 = port_of(s);
    snprintf(msg, sizeof msg, "D: another socket binds the old port %ld: %ld; next sendto %ld, port %ld (>0, differs) (0 1)", a5, d1, d2, d3);
    check(d1 == 0 && d2 == 1 && d3 > 0 && d3 != a5, msg);
    close_s(t);
    close_s(s);

    long c = sock4();
    long c1 = connect_(c, to9, 16), c2 = port_of(c), c3 = unspec(c), c4 = port_of(c);
    snprintf(msg, sizeof msg, "C: connect %ld, port %ld; disconnect %ld, port %ld (0 >0 0 0)", c1, c2, c3, c4);
    check(c1 == 0 && c2 > 0 && c3 == 0 && c4 == 0, msg);
    close_s(c);

    long u = sock4();
    unsigned char any0[16], fixed[16];
    mk4(any0, 0, 0);
    mk4(fixed, 40385, 0);
    long b1 = bind_(u, any0, 16), b2 = port_of(u);
    connect_(u, to9, 16);
    long b3 = unspec(u), b4 = port_of(u);
    long v = sock4();
    long b5 = bind_(v, fixed, 16);
    connect_(v, to9, 16);
    long b6 = unspec(v), b7 = port_of(v);
    snprintf(msg, sizeof msg, "B: bind port 0 %ld, port %ld; disconnect %ld, port %ld; bind 40385 %ld, disconnect %ld, port %ld (0 >0 0 0 0 0 40385)", b1, b2, b3, b4, b5, b6, b7);
    check(b1 == 0 && b2 > 0 && b3 == 0 && b4 == 0 && b5 == 0 && b6 == 0 && b7 == 40385, msg);
    close_s(u);
    close_s(v);

    long w = sock4();
    unsigned char lo0[16];
    mk4(lo0, 0, 1);
    long w1 = bind_(w, lo0, 16), w2 = port_of(w), w3 = unspec(w);
    long w4 = name_(w, a);
    int w5 = a[4] == 127 && a[5] == 0 && a[6] == 0 && a[7] == 1 && a[2] == 0 && a[3] == 0;
    snprintf(msg, sizeof msg, "W: bind 127.0.0.1:0 %ld, port %ld; disconnect %ld; getsockname %ld is 127.0.0.1:0 %d (0 >0 0 0 1)", w1, w2, w3, w4, w5);
    check(w1 == 0 && w2 > 0 && w3 == 0 && w4 == 0 && w5, msg);
    close_s(w);

    long e = sock4();
    long e1 = send_(e, "x", 1), e2 = port_of(e);
    long f = sock4();
    long e3 = sendto_(f, "x", 1, to9, 4), e4 = port_of(f);
    snprintf(msg, sizeof msg, "E: send without a peer %ld, port %ld; sendto with a 4-byte address %ld, port %ld (-89 >0 -22 >0)", e1, e2, e3, e4);
    check(e1 == -89 && e2 > 0 && e3 == -22 && e4 > 0, msg);
    close_s(e);
    close_s(f);

    long s6 = sock6();
    unsigned char to6[28];
    mk6(to6, 9);
    long v1 = port_of(s6), v2 = sendto_(s6, "x", 1, to6, 28), v3 = port_of(s6), v4 = unspec(s6), v5 = port_of(s6);
    snprintf(msg, sizeof msg, "V: IPv6 fresh port %ld; sendto [::1]:9 %ld, port %ld; disconnect %ld, port %ld (0 1 >0 0 0)", v1, v2, v3, v4, v5);
    check(v1 == 0 && v2 == 1 && v3 > 0 && v4 == 0 && v5 == 0, msg);
    close_s(s6);
    close_s(other);

    print(failures ? "hello385: FAIL\n" : "hello385: PASS\n");
    return failures ? 1 : 0;
}
