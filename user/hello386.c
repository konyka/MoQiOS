/* hello386: a socket bound to a 127/8 address cannot reach a destination that leaves through the NIC (net/ipv4/route.c
 * __mkroute_output: a loopback source on a non-loopback device is EINVAL). Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n`, with the veth setup of hello375; 10.0.2.15 is this host, 10.0.2.2 the gateway):
 *   U. a UDP socket bound to 127.0.0.1:40386 with SO_BROADCAST: sendto 10.0.2.2:9, 8.8.8.8:9 and the subnet broadcast 10.0.2.255:9
 *      are EINVAL; 127.9.9.9:9, this host's 10.0.2.15:9, 255.255.255.255:9 and 224.0.0.1:9 send (1); the socket keeps its name;
 *   M. sendmsg to 10.0.2.2:9 is EINVAL too;
 *   C. connect to 10.0.2.2:9 is EINVAL and leaves it unconnected: getpeername ENOTCONN, send EDESTADDRREQ;
 *   T. a TCP socket bound to 127.0.0.1: connect to 10.0.2.2:80 is EINVAL, blocking or not, with SO_ERROR 0; connecting it to a
 *      listener on 127.0.0.1 afterwards works;
 *   B. bound to this host's 10.0.2.15 instead, sendto 127.0.0.1:9 works (1): only a loopback source is refused;
 *   P. a ping socket bound to 127.0.0.1: sendto 10.0.2.2 and connect to it are EINVAL; sendto 10.0.2.15 sends (8).
 * IPv6 is not touched: Linux sends from ::1 to another host (hello358). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock_(int d, int t, int p) { return rc(socket(d, t, p)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 16)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long listen_(long s) { return rc(listen((int)s, 4)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 16)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, 0)); }
static long sendmsg_(long s, const void *b, int n, const unsigned char *to) {
    struct iovec io = { (void *)b, (size_t)n };
    struct msghdr m = { (void *)to, 16, &io, 1, 0, 0, 0 };
    return rc(sendmsg((int)s, &m, 0));
}
static long name_(long s, unsigned char *a) { socklen_t l = 16; return rc(getsockname((int)s, (void *)a, &l)); }
static long peer_(long s, unsigned char *a) { socklen_t l = 16; return rc(getpeername((int)s, (void *)a, &l)); }
static long setint(long s, int lvl, int opt, int v) { return rc(setsockopt((int)s, lvl, opt, &v, 4)); }
static long getint(long s, int opt) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, opt, &v, &l)); return r < 0 ? r : v; }
static long range_(const char *t) { long fd = rc(open("/proc/sys/net/ipv4/ping_group_range", O_WRONLY)); if (fd < 0) return fd; long r = rc(write((int)fd, t, strlen(t))); close((int)fd); return r; }
static long range_read(char *b, int n) { long fd = rc(open("/proc/sys/net/ipv4/ping_group_range", O_RDONLY)); if (fd < 0) return fd; long r = rc(read((int)fd, b, n)); close((int)fd); return r; }
static void close_(long s) { close((int)s); }
#define FAM(a, f) do { unsigned short fam_v_ = (f); memcpy(a, &fam_v_, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_NONBLOCK 0x800
#define SOL_SOCKET 1
#define SO_ERROR 4
#define SO_BROADCAST 6
static long sock_(int d, int t, int p) { return syscall3(117, d, t, p); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 16); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long listen_(long s) { return syscall2(119, s, 4); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long sendmsg_(long s, const void *b, int n, const unsigned char *to) {
    long io[2] = { (long)b, n };
    long m[7] = { (long)to, 16, (long)io, 1, 0, 0, 0 };
    return syscall3(129, s, (long)m, 0);
}
static long name_(long s, unsigned char *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long peer_(long s, unsigned char *a) { int l = 16; return syscall3(127, s, (long)a, (long)&l); }
static long setint(long s, int lvl, int opt, int v) { return syscall5(132, s, lvl, opt, (long)&v, 4); }
static long getint(long s, int opt) { int v = -1; int l = 4; long r = syscall5(133, s, 1, opt, (long)&v, (long)&l); return r < 0 ? r : v; }
static long range_(const char *t) { long fd = syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", 1, 0); if (fd < 0) return fd; long r = syscall3(1, fd, (long)t, strlen(t)); syscall1(11, fd); return r; }
static long range_read(char *b, int n) { long fd = syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", 0, 0); if (fd < 0) return fd; long r = syscall3(10, fd, (long)b, n); syscall1(11, fd); return r; }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[560];
static void check(int ok, const char *w) {
    print(ok ? "hello386:   ok   " : "hello386:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, int a, int b, int c, int d, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[4] = (unsigned char)a; s[5] = (unsigned char)b; s[6] = (unsigned char)c; s[7] = (unsigned char)d;
}
int main(void) {
    print("hello386: a socket bound to 127/8 cannot send out through the NIC\n");
    unsigned char lo[16], gw[16], far[16], sbc[16], lo9[16], own[16], bc[16], mc[16], nm[16], any[16];
    mk4(lo, 127, 0, 0, 1, 40386);
    mk4(gw, 10, 0, 2, 2, 9);
    mk4(far, 8, 8, 8, 8, 9);
    mk4(sbc, 10, 0, 2, 255, 9);
    mk4(lo9, 127, 9, 9, 9, 9);
    mk4(own, 10, 0, 2, 15, 9);
    mk4(bc, 255, 255, 255, 255, 9);
    mk4(mc, 224, 0, 0, 1, 9);

    long u = sock_(AF_INET, SOCK_DGRAM, 0);
    setint(u, SOL_SOCKET, SO_BROADCAST, 1);
    long u0 = bind_(u, lo);
    long u1 = sendto_(u, "x", 1, gw), u2 = sendto_(u, "x", 1, far), u3 = sendto_(u, "x", 1, sbc);
    long u4 = sendto_(u, "x", 1, lo9), u5 = sendto_(u, "x", 1, own), u6 = sendto_(u, "x", 1, bc), u7 = sendto_(u, "x", 1, mc);
    long u8 = name_(u, nm);
    int u9 = memcmp(nm + 2, lo + 2, 6) == 0;
    snprintf(msg, sizeof msg, "U: bind 127.0.0.1:40386 %ld; to the gateway %ld, 8.8.8.8 %ld, 10.0.2.255 %ld; to 127.9.9.9 %ld, 10.0.2.15 %ld, 255.255.255.255 %ld, 224.0.0.1 %ld; name %ld kept %d (0 -22 -22 -22 1 1 1 1 0 1)", u0, u1, u2, u3, u4, u5, u6, u7, u8, u9);
    check(u0 == 0 && u1 == -22 && u2 == -22 && u3 == -22 && u4 == 1 && u5 == 1 && u6 == 1 && u7 == 1 && u8 == 0 && u9, msg);

    long m1 = sendmsg_(u, "x", 1, gw), m2 = sendmsg_(u, "x", 1, lo9);
    snprintf(msg, sizeof msg, "M: sendmsg to the gateway %ld, to 127.9.9.9 %ld (-22 1)", m1, m2);
    check(m1 == -22 && m2 == 1, msg);

    long c1 = connect_(u, gw), c2 = peer_(u, nm), c3 = send_(u, "x", 1);
    snprintf(msg, sizeof msg, "C: connect to the gateway %ld; getpeername %ld; send %ld (-22 -107 -89)", c1, c2, c3);
    check(c1 == -22 && c2 == -107 && c3 == -89, msg);
    close_(u);

    unsigned char lo0[16], lis[16], gw80[16];
    mk4(lo0, 127, 0, 0, 1, 0);
    mk4(lis, 127, 0, 0, 1, 40387);
    mk4(gw80, 10, 0, 2, 2, 80);
    long l = sock_(AF_INET, SOCK_STREAM, 0);
    long l1 = bind_(l, lis), l2 = listen_(l);
    long t = sock_(AF_INET, SOCK_STREAM, 0);
    long t1 = bind_(t, lo0), t2 = connect_(t, gw80), t3 = getint(t, SO_ERROR), t4 = connect_(t, lis);
    long tn = sock_(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    bind_(tn, lo0);
    long t5 = connect_(tn, gw80);
    snprintf(msg, sizeof msg, "T: listener %ld %ld; TCP bound to 127.0.0.1 %ld: connect to the gateway %ld, SO_ERROR %ld, then to the listener %ld; non-blocking %ld (0 0 0 -22 0 0 -22)", l1, l2, t1, t2, t3, t4, t5);
    check(l1 == 0 && l2 == 0 && t1 == 0 && t2 == -22 && t3 == 0 && t4 == 0 && t5 == -22, msg);
    close_(t);
    close_(tn);
    close_(l);

    long w = sock_(AF_INET, SOCK_DGRAM, 0);
    mk4(any, 10, 0, 2, 15, 0);
    unsigned char to_lo[16];
    mk4(to_lo, 127, 0, 0, 1, 9);
    long b1 = bind_(w, any), b2 = sendto_(w, "x", 1, to_lo);
    snprintf(msg, sizeof msg, "B: bound to 10.0.2.15 %ld, sendto 127.0.0.1:9 %ld (0 1)", b1, b2);
    check(b1 == 0 && b2 == 1, msg);
    close_(w);

    char saved[48];
    long sn = range_read(saved, sizeof saved - 1);
    if (sn > 0) saved[sn] = 0; else saved[0] = 0;
    long r0 = range_("0 0");
    long p = sock_(AF_INET, SOCK_DGRAM, 1);
    unsigned char e[8] = { 8, 0, 0, 0, 0, 0, 0, 1 }, pgw[16], pown[16];
    mk4(pgw, 10, 0, 2, 2, 0);
    mk4(pown, 10, 0, 2, 15, 0);
    long p1 = bind_(p, lo0), p2 = sendto_(p, e, 8, pgw), p3 = connect_(p, pgw), p4 = sendto_(p, e, 8, pown);
    snprintf(msg, sizeof msg, "P: ping range %ld, socket %ld; bound to 127.0.0.1 %ld: sendto the gateway %ld, connect %ld; sendto 10.0.2.15 %ld (3 >=0 0 -22 -22 8)", r0, p, p1, p2, p3, p4);
    check(r0 == 3 && p >= 0 && p1 == 0 && p2 == -22 && p3 == -22 && p4 == 8, msg);
    close_(p);
    if (saved[0]) range_(saved);

    print(failures ? "hello386: FAIL\n" : "hello386: PASS\n");
    return failures ? 1 : 0;
}
