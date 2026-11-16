/* hello374: IPv6 ping sockets (socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)), Linux net/ipv6/ping.c over net/ipv4/ping.c. The user
 * writes an ICMPv6 echo request; the kernel puts the socket's ident in the id field and computes the checksum over the IPv6
 * pseudo-header; the echo replies whose id is that ident come back on the socket. IPv4 and IPv6 ping sockets share the ident table
 * but a reply only goes to a socket of its own family (ping_lookup). The test opens net.ipv4.ping_group_range to group 0 itself and
 * puts the old range back. Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up):
 *   S. socket(AF_INET6, SOCK_DGRAM, 58) works and reports SO_PROTOCOL 58, SO_DOMAIN 10; protocol 1 on AF_INET6 and 58 on AF_INET are
 *      EPROTONOSUPPORT; with the range empty socket(AF_INET6, SOCK_DGRAM, 58) is EACCES;
 *   P. a fresh socket names [::]:0; an echo request to ::1 comes back as an echo reply (type 129) with the same sequence number and
 *      data, the socket's ident as id, a checksum valid over the ::1 pseudo-header, from ::1 (address length 28); the socket then
 *      names its ident;
 *   E. a message shorter than 8 bytes, type 8 (the IPv4 echo request), code 1, an address shorter than 28 bytes are EINVAL; an
 *      AF_INET address EAFNOSUPPORT; no address on an unconnected socket EDESTADDRREQ; recv on an empty socket EAGAIN;
 *   B. bind [::]:4374 names it, a second bind is EINVAL; binding ff02::1 is EINVAL, 2001:db8::1 EADDRNOTAVAIL, an AF_INET address
 *      EAFNOSUPPORT, 24 bytes EINVAL; binding [::1]:4376 names ::1;
 *   C. a ping socket connected to ::1 sends with send() and gets the reply; getpeername on it is ENOTCONN, as on a connected IPv4
 *      ping socket (inet6_getname / inet_getname want a peer port, and a ping socket has none);
 *   F. an IPv6 socket bound to ident 4375 and an IPv4 one bound to it after: the IPv6 reply goes to the IPv6 socket and the IPv4 one
 *      gets nothing, and the other way round. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock_(int d, int p) { return rc(socket(d, SOCK_DGRAM, p)); }
static long bind_(long s, const unsigned char *a, int l) { return rc(bind((int)s, (const void *)a, l)); }
static long connect_(long s, const unsigned char *a, int l) { return rc(connect((int)s, (const void *)a, l)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long peer_(long s, unsigned char *a) { socklen_t l = 28; return rc(getpeername((int)s, (void *)a, &l)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return rc(sendto((int)s, b, n, 0, (const void *)to, l)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, 0)); }
static long recvfrom_(long s, void *b, int n, unsigned char *from, long *flen) { socklen_t l = (socklen_t)*flen; long r = rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l)); *flen = l; return r; }
static long getint(long s, int opt) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, opt, &v, &l)); return r < 0 ? r : v; }
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
#define SO_PROTOCOL 38
#define SO_DOMAIN 39
static long sock_(int d, int p) { return syscall3(117, d, 2, p); }
static long bind_(long s, const unsigned char *a, int l) { return syscall3(118, s, (long)a, l); }
static long connect_(long s, const unsigned char *a, int l) { return syscall3(124, s, (long)a, l); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long peer_(long s, unsigned char *a) { int l = 28; return syscall3(127, s, (long)a, (long)&l); }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return syscall6(121, s, (long)b, n, 0, (long)to, l); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recvfrom_(long s, void *b, int n, unsigned char *from, long *flen) { int l = (int)*flen; long r = syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); *flen = l; return r; }
static long getint(long s, int opt) { int v = -1; int l = 4; long r = syscall5(133, s, 1, opt, (long)&v, (long)&l); return r < 0 ? r : v; }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
static char range_saved[48];
static long range_fd(int wr) {
#ifdef HOST
    return rc(open("/proc/sys/net/ipv4/ping_group_range", wr ? O_WRONLY : O_RDONLY));
#else
    return syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", wr ? 1 : 0, 0);
#endif
}
static long range_io(long fd, char *b, int n, int wr) {
#ifdef HOST
    return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n));
#else
    return syscall3(wr ? 1 : 10, fd, (long)b, n);
#endif
}
static long set_range(const char *t) {
    long fd = range_fd(1);
    if (fd < 0) return fd;
    int n = 0;
    while (t[n] && t[n] != '\n') n++;
    long w = range_io(fd, (char *)t, n, 1);
    close_(fd);
    return w;
}
static long save_range(void) {
    long fd = range_fd(0);
    if (fd < 0) return fd;
    long n = range_io(fd, range_saved, sizeof range_saved - 1, 0);
    close_(fd);
    if (n <= 0) return -1;
    range_saved[n] = 0;
    return n;
}
static int failures;
static char msg[480];
static void check(int ok, const char *w) {
    print(ok ? "hello374:   ok   " : "hello374:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk6(unsigned char *s, const unsigned char *ip, int port) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s, AF_INET6);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (ip) for (int i = 0; i < 16; i++) s[8 + i] = ip[i];
}
static void mk4(unsigned char *s, const unsigned char *ip, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (ip) for (int i = 0; i < 4; i++) s[4 + i] = ip[i];
}
static int port_of(const unsigned char *a) { return (a[2] << 8) | a[3]; }
static int is_lo6(const unsigned char *a) {
    for (int i = 0; i < 15; i++) if (a[i]) return 0;
    return a[15] == 1;
}
static int is_any6(const unsigned char *a) {
    for (int i = 0; i < 16; i++) if (a[i]) return 0;
    return 1;
}
/* The ICMPv6 checksum of `b` (n bytes) between ::1 and ::1 is valid. */
static int csum6_ok(const unsigned char *b, long n) {
    unsigned long acc = 1 + 1 + (unsigned long)(n >> 16) + (unsigned long)(n & 0xffff) + 58;
    long i = 0;
    for (; i + 1 < n; i += 2) acc += ((unsigned long)b[i] << 8) | b[i + 1];
    if (i < n) acc += (unsigned long)b[i] << 8;
    while (acc >> 16) acc = (acc & 0xffff) + (acc >> 16);
    return acc == 0xffff;
}
static long wait_msg(long s, unsigned char *b, int n, unsigned char *from, long *flen) {
    long r = -11;
    for (int t = 0; t < 50; t++) {
        long l = *flen;
        r = recvfrom_(s, b, n, from, &l);
        if (r != -11) { *flen = l; break; }
        pump();
    }
    return r;
}
int main(void) {
    print("hello374: IPv6 ping sockets\n");
    long saved = save_range();
    unsigned char lo6[16] = { 0 }, grp6[16] = { 0xff, 2 }, doc6[16] = { 0x20, 0x01, 0x0d, 0xb8 }, lo4[4] = { 127, 0, 0, 1 };
    lo6[15] = 1; grp6[15] = 1; doc6[15] = 1;
    unsigned char a[32], from[32], name[28];
    unsigned char req[16] = { 128, 0, 0, 0, 0, 0, 0, 9, 'p', 'i', 'n', 'g', '3', '7', '4', '!' }, rep[64];
    unsigned char req4[16] = { 8, 0, 0, 0, 0, 0, 0, 5, 'v', '4', 'p', 'i', 'n', 'g', '!', '!' };

    long sa = set_range("1 0");
    long s0 = sock_(AF_INET6, 58);
    if (s0 >= 0) close_(s0);
    long sr = set_range("0 0");
    long s = sock_(AF_INET6, 58);
    long sp = getint(s, SO_PROTOCOL), sd = getint(s, SO_DOMAIN);
    long x1 = sock_(AF_INET6, 1), x2 = sock_(AF_INET, 58);
    if (x1 >= 0) close_(x1);
    if (x2 >= 0) close_(x2);
    snprintf(msg, sizeof msg, "S: empty range %ld; range 0 0 %ld, socket %d, SO_PROTOCOL %ld SO_DOMAIN %ld; AF_INET6 proto 1 %ld, AF_INET proto 58 %ld (-13 >=0 58 10 -93 -93)", s0, sr, s >= 0, sp, sd, x1, x2);
    check(sa == 3 && s0 == -13 && sr == 3 && s >= 0 && sp == 58 && sd == 10 && x1 == -93 && x2 == -93, msg);

    long n0 = name_(s, name);
    int fresh = n0 == 0 && name[0] == AF_INET6 && port_of(name) == 0 && is_any6(name + 8);
    mk6(a, lo6, 0);
    long s1 = sendto_(s, req, 16, a, 28);
    long flen = 32;
    for (int i = 0; i < 32; i++) from[i] = 0xee;
    long r1 = wait_msg(s, rep, sizeof rep, from, &flen);
    name_(s, name);
    int ident = port_of(name);
    int body = r1 == 16 && rep[0] == 129 && rep[1] == 0 && rep[7] == 9 && memcmp(rep + 8, req + 8, 8) == 0;
    int idok = r1 == 16 && ((rep[4] << 8) | rep[5]) == ident && ident != 0;
    int src = flen == 28 && from[0] == AF_INET6 && port_of(from) == 0 && is_lo6(from + 8) && from[28] == 0xee;
    snprintf(msg, sizeof msg, "P: fresh name [::]:0 %d; send %ld, reply %ld body %d id %d csum %d from ::1/28 %d; ident %d (1 16 16 1 1 1 1 >0)", fresh, s1, r1, body, idok, r1 > 0 && csum6_ok(rep, r1), src, ident);
    check(fresh && s1 == 16 && r1 == 16 && body && idok && csum6_ok(rep, r1) && src && ident != 0, msg);

    unsigned char bad[16];
    memcpy(bad, req, 16);
    long e1 = sendto_(s, req, 7, a, 28);
    bad[0] = 8;
    long e2 = sendto_(s, bad, 16, a, 28);
    bad[0] = 128; bad[1] = 1;
    long e3 = sendto_(s, bad, 16, a, 28);
    long e4 = sendto_(s, req, 16, a, 24);
    unsigned char a4[16];
    mk4(a4, lo4, 0);
    long e5 = sendto_(s, req, 16, a4, 28);
    long e6 = send_(s, req, 16);
    flen = 32;
    long e7 = recvfrom_(s, rep, sizeof rep, from, &flen);
    snprintf(msg, sizeof msg, "E: short %ld, type 8 %ld, code 1 %ld, address of 24 bytes %ld, AF_INET %ld, no address %ld, empty recv %ld (-22 -22 -22 -22 -97 -89 -11)", e1, e2, e3, e4, e5, e6, e7);
    check(e1 == -22 && e2 == -22 && e3 == -22 && e4 == -22 && e5 == -97 && e6 == -89 && e7 == -11, msg);
    close_(s);

    long b = sock_(AF_INET6, 58);
    mk6(a, 0, 4374);
    long bb = bind_(b, a, 28);
    name_(b, name);
    int bport = port_of(name);
    mk6(a, 0, 4377);
    long bb2 = bind_(b, a, 28);
    long b2 = sock_(AF_INET6, 58);
    mk6(a, grp6, 4376);
    long bg = bind_(b2, a, 28);
    mk6(a, doc6, 4376);
    long bd = bind_(b2, a, 28);
    mk4(a4, 0, 4376);
    long bf = bind_(b2, a4, 28);
    mk6(a, lo6, 4376);
    long bs = bind_(b2, a, 24);
    long bl = bind_(b2, a, 28);
    name_(b2, name);
    int lname = port_of(name) == 4376 && is_lo6(name + 8);
    snprintf(msg, sizeof msg, "B: bind [::]:4374 %ld names %d, again %ld; ff02::1 %ld, 2001:db8::1 %ld, AF_INET %ld, 24 bytes %ld; [::1]:4376 %ld names it %d (0 4374 -22 -22 -99 -97 -22 0 1)", bb, bport, bb2, bg, bd, bf, bs, bl, lname);
    check(bb == 0 && bport == 4374 && bb2 == -22 && bg == -22 && bd == -99 && bf == -97 && bs == -22 && bl == 0 && lname, msg);
    close_(b); close_(b2);

    long c = sock_(AF_INET6, 58);
    mk6(a, lo6, 0);
    long cc = connect_(c, a, 28);
    long cp = peer_(c, name);
    long cs = send_(c, req, 12);
    flen = 32;
    long cr = wait_msg(c, rep, sizeof rep, from, &flen);
    long c4 = sock_(AF_INET, 1);
    mk4(a4, lo4, 0);
    long cc4 = connect_(c4, a4, 16);
    long cp4 = peer_(c4, name);
    close_(c4);
    snprintf(msg, sizeof msg, "C: connect to ::1 %ld, getpeername %ld, send %ld, reply %ld type %d; IPv4 connect %ld getpeername %ld (0 -107 12 12 129 0 -107)", cc, cp, cs, cr, cr > 0 ? rep[0] : -1, cc4, cp4);
    check(cc == 0 && cp == -107 && cs == 12 && cr == 12 && rep[0] == 129 && cc4 == 0 && cp4 == -107, msg);
    close_(c);

    long f6 = sock_(AF_INET6, 58), f4 = sock_(AF_INET, 1);
    mk6(a, 0, 4375);
    long fb6 = bind_(f6, a, 28);
    mk4(a4, 0, 4375);
    long fb4 = bind_(f4, a4, 16);
    mk6(a, lo6, 0);
    long fs6 = sendto_(f6, req, 16, a, 28);
    flen = 32;
    long fr6 = wait_msg(f6, rep, sizeof rep, from, &flen);
    long l = 32;
    long fx4 = recvfrom_(f4, rep, sizeof rep, from, &l);
    mk4(a4, lo4, 0);
    long fs4 = sendto_(f4, req4, 16, a4, 16);
    flen = 32;
    long fr4 = wait_msg(f4, rep, sizeof rep, from, &flen);
    int t4 = fr4 == 16 && rep[0] == 0;
    l = 32;
    long fx6 = recvfrom_(f6, rep, sizeof rep, from, &l);
    snprintf(msg, sizeof msg, "F: IPv6 and IPv4 on ident 4375: bind %ld %ld; IPv6 send %ld reply %ld, IPv4 sees %ld; IPv4 send %ld reply %ld type 0 %d, IPv6 sees %ld (0 0 16 16 -11 16 16 1 -11)", fb6, fb4, fs6, fr6, fx4, fs4, fr4, t4, fx6);
    check(fb6 == 0 && fb4 == 0 && fs6 == 16 && fr6 == 16 && fx4 == -11 && fs4 == 16 && t4 && fx6 == -11, msg);
    close_(f6); close_(f4);

    if (saved > 0) set_range(range_saved);
    else { print("hello374:   FAIL could not read net.ipv4.ping_group_range\n"); failures++; }
    print(failures ? "hello374: FAIL\n" : "hello374: PASS\n");
    return failures ? 1 : 0;
}
