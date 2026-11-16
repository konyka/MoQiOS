/* hello387: net.ipv4.conf.<dev>.route_localnet (/proc/sys/net/ipv4/conf/{all,default,lo,<nic>}/route_localnet, net/ipv4/route.c
 * __mkroute_output: IN_DEV_ROUTE_LOCALNET of the output device, which is set when that device's or all's value is nonzero). Measured
 * on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n`, with the veth setup of hello375; the NIC is
 * v0 there, eth0 on MoQiOS):
 *   L. a device's conf directory lists route_localnet next to proxy_arp; all four read "0\n";
 *   N. with all of them 0 a UDP socket bound to 127.0.0.1 gets EINVAL sending to the gateway 10.0.2.2:9 (hello386);
 *   E. the NIC's route_localnet 1 lets it send (1); all 1 too; lo 1 or default 1 do not (EINVAL): the output device is the NIC;
 *   V. it is an int like proxy_arp: 7 and -1 read back and both count as on;
 *   T. with the NIC's value 1 a non-blocking TCP connect from 127.0.0.1 to the gateway is EINPROGRESS instead of EINVAL;
 *   R. writing it needs root or CAP_NET_ADMIN like the other sysctls (hello383); the test leaves every value 0. */
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
#include <sys/syscall.h>
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
static long put_(const char *p, const char *t) { long fd = rc(open(p, O_WRONLY)); if (fd < 0) return fd; long r = rc(write((int)fd, t, strlen(t))); close((int)fd); return r; }
static long get_(const char *p, char *b, int n) { long fd = rc(open(p, O_RDONLY)); if (fd < 0) return fd; long r = rc(read((int)fd, b, n)); close((int)fd); return r; }
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
static long setint(long s, int lvl, int opt, int v) { return syscall5(134, s, lvl, opt, (long)&v, 4); }
static long getint(long s, int opt) { int v = -1; int l = 4; long r = syscall5(133, s, 1, opt, (long)&v, (long)&l); return r < 0 ? r : v; }
static long put_(const char *p, const char *t) { long fd = syscall3(9, (long)p, 1, 0); if (fd < 0) return fd; long r = syscall3(1, fd, (long)t, strlen(t)); syscall1(11, fd); return r; }
static long get_(const char *p, char *b, int n) { long fd = syscall3(9, (long)p, 0, 0); if (fd < 0) return fd; long r = syscall3(10, fd, (long)b, n); syscall1(11, fd); return r; }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[480];
static void check(int ok, const char *w) {
    print(ok ? "hello387:   ok   " : "hello387:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
#ifdef HOST
#define NIC "v0"
#else
#define NIC "eth0"
#endif
#define CONF "/proc/sys/net/ipv4/conf/"
#define RL "/route_localnet"
static void mk4(unsigned char *s, int a, int b, int c, int d, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    s[4] = (unsigned char)a; s[5] = (unsigned char)b; s[6] = (unsigned char)c; s[7] = (unsigned char)d;
}
static long value(const char *p) {
    char b[24];
    long n = get_(p, b, sizeof b - 1);
    if (n < 2 || b[n - 1] != '\n') return -9999;
    long v = 0, i = 0, neg = 0;
    if (b[0] == '-') { neg = 1; i = 1; }
    for (; i < n - 1; i++) { if (b[i] < '0' || b[i] > '9') return -9999; v = v * 10 + (b[i] - '0'); }
    return neg ? -v : v;
}
/* sendto 10.0.2.2:9 from a fresh UDP socket bound to 127.0.0.1. */
static long out1(void) {
    unsigned char b[16], g[16];
    mk4(b, 127, 0, 0, 1, 0);
    mk4(g, 10, 0, 2, 2, 9);
    long u = sock_(AF_INET, SOCK_DGRAM, 0);
    bind_(u, b);
    long r = sendto_(u, "x", 1, g);
    close_(u);
    return r;
}
static long dir_has(const char *dir, const char *name) {
#ifdef HOST
    long fd = rc(open(dir, O_RDONLY));
#else
    long fd = syscall3(9, (long)dir, 0, 0);
#endif
    if (fd < 0) return fd;
    char b[1024];
    long t = 0, n;
    for (;;) {
#ifdef HOST
        n = rc(syscall(SYS_getdents64, (int)fd, b, sizeof b));
#else
        n = syscall3(173, fd, (long)b, sizeof b);
#endif
        if (n <= 0) break;
        for (long off = 0; off < n;) {
            unsigned short reclen = (unsigned short)((b[off + 16] & 0xff) | ((b[off + 17] & 0xff) << 8));
            if (strcmp(b + off + 19, name) == 0) t = b[off + 18];
            off += reclen;
        }
    }
    close_(fd);
    if (n < 0) return n;
    return t;
}
int main(void) {
    print("hello387: net.ipv4.conf.<dev>.route_localnet\n");
    long l1 = dir_has(CONF NIC, "route_localnet"), l2 = dir_has(CONF NIC, "proxy_arp");
    long l3 = value(CONF "all" RL), l4 = value(CONF "default" RL), l5 = value(CONF "lo" RL), l6 = value(CONF NIC RL);
    snprintf(msg, sizeof msg, "L: " NIC "/ lists route_localnet %ld proxy_arp %ld; all %ld default %ld lo %ld " NIC " %ld (8 8 0 0 0 0)", l1, l2, l3, l4, l5, l6);
    check(l1 == 8 && l2 == 8 && l3 == 0 && l4 == 0 && l5 == 0 && l6 == 0, msg);

    long n1 = out1();
    snprintf(msg, sizeof msg, "N: all 0: 127.0.0.1 -> 10.0.2.2 %ld (-22)", n1);
    check(n1 == -22, msg);

    long e1 = put_(CONF NIC RL, "1"), e2 = out1();
    put_(CONF NIC RL, "0");
    long e3 = put_(CONF "all" RL, "1"), e4 = out1();
    put_(CONF "all" RL, "0");
    long e5 = put_(CONF "lo" RL, "1"), e6 = out1();
    put_(CONF "lo" RL, "0");
    long e7 = put_(CONF "default" RL, "1"), e8 = out1();
    put_(CONF "default" RL, "0");
    snprintf(msg, sizeof msg, "E: " NIC "=1 %ld send %ld; all=1 %ld send %ld; lo=1 %ld send %ld; default=1 %ld send %ld (1 1 1 1 1 -22 1 -22)", e1, e2, e3, e4, e5, e6, e7, e8);
    check(e1 == 1 && e2 == 1 && e3 == 1 && e4 == 1 && e5 == 1 && e6 == -22 && e7 == 1 && e8 == -22, msg);

    long v1 = put_(CONF NIC RL, "7"), v2 = value(CONF NIC RL), v3 = out1();
    long v4 = put_(CONF NIC RL, "-1"), v5 = value(CONF NIC RL), v6 = out1();
    put_(CONF NIC RL, "0");
    snprintf(msg, sizeof msg, "V: 7 %ld reads %ld send %ld; -1 %ld reads %ld send %ld (1 7 1 2 -1 1)", v1, v2, v3, v4, v5, v6);
    check(v1 == 1 && v2 == 7 && v3 == 1 && v4 == 2 && v5 == -1 && v6 == 1, msg);

    unsigned char lo0[16], gw80[16];
    mk4(lo0, 127, 0, 0, 1, 0);
    mk4(gw80, 10, 0, 2, 2, 80);
    put_(CONF NIC RL, "1");
    long t = sock_(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    bind_(t, lo0);
    long t1 = connect_(t, gw80);
    close_(t);
    put_(CONF NIC RL, "0");
    snprintf(msg, sizeof msg, "T: " NIC "=1: non-blocking TCP connect from 127.0.0.1 to the gateway %ld (-115)", t1);
    check(t1 == -115, msg);

    long r1 = value(CONF "all" RL), r2 = value(CONF "default" RL), r3 = value(CONF "lo" RL), r4 = value(CONF NIC RL), r5 = out1();
    snprintf(msg, sizeof msg, "R: left at all %ld default %ld lo %ld " NIC " %ld, send %ld (0 0 0 0 -22)", r1, r2, r3, r4, r5);
    check(r1 == 0 && r2 == 0 && r3 == 0 && r4 == 0 && r5 == -22, msg);

    print(failures ? "hello387: FAIL\n" : "hello387: PASS\n");
    return failures ? 1 : 0;
}
