/* hello371: IPv4 ping sockets (socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)), Linux net/ipv4/ping.c. The user writes an ICMP echo
 * request; the kernel puts the socket's ident in the id field and checksums it; the echo replies whose id is that ident come back
 * on the socket, from the address that answered. Also: recvfrom on an IPv4 datagram socket reports a 16-byte sockaddr_in.
 * The test opens net.ipv4.ping_group_range to group 0 itself (hello373) and puts the old range back. Measured on the host (build
 * with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up and a veth pair whose far end has no address:
 *   ip link set lo up; ip link add v0 type veth peer name v1; ip link set v1 up; ip link set v0 up;
 *   ip addr add 10.0.2.15/24 dev v0; ip route add default via 10.0.2.2 dev v0):
 *   P. a ping socket names port 0 and reports SO_PROTOCOL 1; an echo request to 127.0.0.1 comes back as an echo reply with the
 *      same sequence number and data, the socket's ident as id, a valid checksum, from 127.0.0.1 (address length 16); the socket
 *      then names its ident;
 *   O. an echo request to our own address (the NIC's) is answered from that address;
 *   E. a message shorter than 8 bytes, a type other than echo request, a code other than 0, an address shorter than 16 bytes are
 *      EINVAL; an AF_INET6 address EAFNOSUPPORT; no address on an unconnected socket EDESTADDRREQ; recv on an empty socket EAGAIN;
 *   B. bind to ident 4371 names it, a second bind is EINVAL; another ping socket binds 4371 too (both have SO_REUSEADDR), one with
 *      SO_REUSEADDR cleared gets EADDRINUSE; a UDP socket on port 4371 does not conflict; binding 10.0.2.99 or 224.0.0.1 is
 *      EADDRNOTAVAIL;
 *   C. a connected ping socket sends with send() and gets the reply;
 *   U. a UDP recvfrom with a 32-byte buffer reports length 16 with sin_zero cleared, with an 8-byte buffer still reports 16. */
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
static long psock(void) { return rc(socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)); }
static long usock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long bind_(long s, const unsigned char *a, int l) { return rc(bind((int)s, (const void *)a, l)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long name_(long s, unsigned char *a) { socklen_t l = 16; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return rc(sendto((int)s, b, n, 0, (const void *)to, l)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, 0)); }
static long recvfrom_(long s, void *b, int n, unsigned char *from, long *flen) { socklen_t l = (socklen_t)*flen; long r = rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l)); *flen = l; return r; }
static long getint(long s, int opt) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, opt, &v, &l)); return r < 0 ? r : v; }
static long setint(long s, int opt, int v) { return rc(setsockopt((int)s, SOL_SOCKET, opt, &v, 4)); }
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
#define SO_REUSEADDR 2
#define SO_PROTOCOL 38
static long psock(void) { return syscall3(117, AF_INET, 2, 1); }
static long usock(void) { return syscall3(117, AF_INET, 2, 0); }
static long bind_(long s, const unsigned char *a, int l) { return syscall3(118, s, (long)a, l); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long name_(long s, unsigned char *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return syscall6(121, s, (long)b, n, 0, (long)to, l); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recvfrom_(long s, void *b, int n, unsigned char *from, long *flen) { int l = (int)*flen; long r = syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); *flen = l; return r; }
static long getint(long s, int opt) { int v = -1; int l = 4; long r = syscall5(133, s, 1, opt, (long)&v, (long)&l); return r < 0 ? r : v; }
static long setint(long s, int opt, int v) { return syscall5(132, s, 1, opt, (long)&v, 4); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
/* Ping sockets need the caller's group in net.ipv4.ping_group_range (empty by default): open it to group 0 for the test and put
 * back what was there (on the host the namespace starts with the default range, as MoQiOS does). */
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
static long open_ping_range(void) {
    long fd = range_fd(0);
    if (fd < 0) return fd;
    long n = range_io(fd, range_saved, sizeof range_saved - 1, 0);
    close_(fd);
    if (n <= 0) return -1;
    range_saved[n] = 0;
    fd = range_fd(1);
    if (fd < 0) return fd;
    char zero[] = "0 0";
    long w = range_io(fd, zero, 3, 1);
    close_(fd);
    return w;
}
static void restore_ping_range(void) {
    long fd = range_fd(1);
    if (fd < 0) return;
    int n = 0;
    while (range_saved[n] && range_saved[n] != '\n') n++;
    range_io(fd, range_saved, n, 1);
    close_(fd);
}
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello371:   ok   " : "hello371:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, const unsigned char *ip, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (ip) for (int i = 0; i < 4; i++) s[4 + i] = ip[i];
}
static int port_of(const unsigned char *a) { return (a[2] << 8) | a[3]; }
static int csum_ok(const unsigned char *b, long n) {
    unsigned long acc = 0;
    long i = 0;
    for (; i + 1 < n; i += 2) acc += ((unsigned long)b[i] << 8) | b[i + 1];
    if (i < n) acc += (unsigned long)b[i] << 8;
    while (acc >> 16) acc = (acc & 0xffff) + (acc >> 16);
    return acc == 0xffff;
}
/* Wait up to 1 s for a message on `s`; returns its length (or a negative errno) with the source in `from`. */
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
    print("hello371: IPv4 ping sockets\n");
    long range_rc = open_ping_range();
    unsigned char lo4[4] = { 127, 0, 0, 1 }, gw[4] = { 10, 0, 2, 2 }, far[4] = { 10, 0, 2, 99 }, grp[4] = { 224, 0, 0, 1 };
    unsigned char a[32], from[32], name[16], own[4];
    unsigned char req[16] = { 8, 0, 0, 0, 0, 0, 0, 7, 'p', 'i', 'n', 'g', '3', '7', '1', '!' }, rep[64];

    long p = psock();
    long n0 = name_(p, name);
    int port0 = port_of(name);
    long proto = getint(p, SO_PROTOCOL);
    mk4(a, lo4, 0);
    long s1 = sendto_(p, req, 16, a, 16);
    long flen = 32;
    for (int i = 0; i < 32; i++) from[i] = 0xee;
    long r1 = wait_msg(p, rep, sizeof rep, from, &flen);
    long n1 = name_(p, name);
    int ident = port_of(name);
    int body = r1 == 16 && rep[0] == 0 && rep[1] == 0 && rep[7] == 7 && memcmp(rep + 8, req + 8, 8) == 0;
    int idok = r1 == 16 && ((rep[4] << 8) | rep[5]) == ident && ident != 0;
    int src = flen == 16 && from[4] == 127 && from[7] == 1 && from[8] == 0 && from[15] == 0;
    snprintf(msg, sizeof msg, "P: fresh name %ld port %d, SO_PROTOCOL %ld; send %ld, reply %ld body %d id %d csum %d from 127.0.0.1/16 %d; name %ld ident %d (0 0 1 16 16 1 1 1 1 0 >0)", n0, port0, proto, s1, r1, body, idok, r1 > 0 && csum_ok(rep, r1), src, n1, ident);
    check(n0 == 0 && port0 == 0 && proto == 1 && s1 == 16 && r1 == 16 && body && idok && csum_ok(rep, r1) && src && n1 == 0 && ident != 0, msg);

    /* Our own address: the source a datagram to the gateway leaves from. */
    long g = usock();
    mk4(a, gw, 19971);
    connect_(g, a);
    name_(g, name);
    close_(g);
    for (int i = 0; i < 4; i++) own[i] = name[4 + i];
    mk4(a, own, 0);
    long s2 = sendto_(p, req, 12, a, 16);
    flen = 32;
    long r2 = wait_msg(p, rep, sizeof rep, from, &flen);
    int src2 = r2 == 12 && from[4] == own[0] && from[5] == own[1] && from[6] == own[2] && from[7] == own[3];
    snprintf(msg, sizeof msg, "O: echo request to our own address %d.%d.%d.%d: send %ld, reply %ld from it %d (12 12 1)", own[0], own[1], own[2], own[3], s2, r2, src2);
    check(s2 == 12 && r2 == 12 && src2, msg);

    unsigned char bad[16];
    memcpy(bad, req, 16);
    mk4(a, lo4, 0);
    long e1 = sendto_(p, req, 7, a, 16);
    bad[0] = 0;
    long e2 = sendto_(p, bad, 16, a, 16);
    bad[0] = 8; bad[1] = 1;
    long e3 = sendto_(p, bad, 16, a, 16);
    long e4 = sendto_(p, req, 16, a, 8);
    unsigned char a6[28];
    for (int i = 0; i < 28; i++) a6[i] = 0;
    FAM(a6, AF_INET6);
    long e5 = sendto_(p, req, 16, a6, 28);
    long e6 = send_(p, req, 16);
    flen = 32;
    long e7 = recvfrom_(p, rep, sizeof rep, from, &flen);
    snprintf(msg, sizeof msg, "E: short %ld, type 0 %ld, code 1 %ld, address of 8 bytes %ld, AF_INET6 %ld, no address %ld, empty recv %ld (-22 -22 -22 -22 -97 -89 -11)", e1, e2, e3, e4, e5, e6, e7);
    check(e1 == -22 && e2 == -22 && e3 == -22 && e4 == -22 && e5 == -97 && e6 == -89 && e7 == -11, msg);
    close_(p);

    long b = psock();
    mk4(a, 0, 4371);
    long bb = bind_(b, a, 16);
    long bn = name_(b, name);
    int bport = port_of(name);
    mk4(a, 0, 4372);
    long bb2 = bind_(b, a, 16);
    long b2 = psock();
    mk4(a, 0, 4371);
    long bs = bind_(b2, a, 16);
    long b3 = psock();
    setint(b3, SO_REUSEADDR, 0);
    long bx = bind_(b3, a, 16);
    long u = usock();
    long bu = bind_(u, a, 16);
    long b4 = psock();
    mk4(a, far, 4373);
    long bf = bind_(b4, a, 16);
    mk4(a, grp, 4373);
    long bg = bind_(b4, a, 16);
    snprintf(msg, sizeof msg, "B: bind 4371 %ld names %d, bind again %ld; another %ld; one without SO_REUSEADDR %ld; UDP on 4371 %ld; 10.0.2.99 %ld, 224.0.0.1 %ld (0 4371 -22 0 -98 0 -99 -99)", bb, bport, bb2, bs, bx, bu, bf, bg);
    check(bb == 0 && bn == 0 && bport == 4371 && bb2 == -22 && bs == 0 && bx == -98 && bu == 0 && bf == -99 && bg == -99, msg);
    close_(b); close_(b2); close_(b3); close_(u); close_(b4);

    long c = psock();
    mk4(a, lo4, 0);
    long cc = connect_(c, a);
    long cs = send_(c, req, 10);
    flen = 32;
    long cr = wait_msg(c, rep, sizeof rep, from, &flen);
    snprintf(msg, sizeof msg, "C: connect to 127.0.0.1 %ld, send %ld, reply %ld type %d (0 10 10 0)", cc, cs, cr, cr > 0 ? rep[0] : -1);
    check(cc == 0 && cs == 10 && cr == 10 && rep[0] == 0, msg);
    close_(c);

    long ur = usock(), us = usock();
    mk4(a, lo4, 19972);
    bind_(ur, a, 16);
    sendto_(us, "hi", 2, a, 16);
    sendto_(us, "hi", 2, a, 16);
    for (int i = 0; i < 32; i++) from[i] = 0xee;
    flen = 32;
    long ua = wait_msg(ur, rep, sizeof rep, from, &flen);
    long ulen = flen;
    int zero = from[8] == 0 && from[15] == 0 && from[16] == 0xee;
    for (int i = 0; i < 32; i++) from[i] = 0xee;
    flen = 8;
    long ub = wait_msg(ur, rep, sizeof rep, from, &flen);
    snprintf(msg, sizeof msg, "U: UDP recvfrom %ld reports %ld, sin_zero cleared %d; with 8 bytes %ld reports %ld, byte 8 untouched %d (2 16 1 2 16 1)", ua, ulen, zero, ub, flen, from[8] == 0xee);
    check(ua == 2 && ulen == 16 && zero && ub == 2 && flen == 16 && from[8] == 0xee, msg);
    close_(ur); close_(us);

    restore_ping_range();
    if (range_rc != 3) { print("hello371:   FAIL could not open net.ipv4.ping_group_range\n"); failures++; }
    print(failures ? "hello371: FAIL\n" : "hello371: PASS\n");
    return failures ? 1 : 0;
}
