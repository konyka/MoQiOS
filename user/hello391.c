/* hello391: an IPv6 raw ICMPv6 socket (socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6), Linux net/ipv6/raw.c), and shutdown on raw
 * sockets. A send gets its IPv6 header and its ICMPv6 checksum from the kernel; every ICMPv6 message this host receives is copied,
 * without the IPv6 header, to each raw ICMPv6 socket whose bound address, connected peer and ICMP6_FILTER let it through.
 * Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   A. protocol 0 is EPROTONOSUPPORT; SO_TYPE 3, SO_PROTOCOL 58, SO_DOMAIN 10; getsockname names AF_INET6, port 58, :: in 28
 *      bytes; getpeername is ENOTCONN;
 *   S. send without a destination is EDESTADDRREQ; a 16-byte address EINVAL, an AF_INET one of 28 bytes EAFNOSUPPORT, port 17
 *      EINVAL; 0 and 1 bytes are EFAULT, 2 and 3 EINVAL (the checksum does not fit), 4 bytes go out;
 *   E. an echo request with a wrong checksum sent to ::1 comes back twice, the request (checksum fixed by the kernel) and the
 *      kernel's reply, 16 bytes each; recvfrom names ::1 port 0 in 28 bytes; then EAGAIN;
 *   T. recv into 5 bytes with MSG_TRUNC returns 16, without it 5;
 *   P. poll: no POLLIN with nothing queued, POLLIN after a send;
 *   F. ICMP6_FILTER reads 32 zero bytes; blocking all but echo reply lets only the reply in and reads back word 4 0xfffffffd;
 *      8 bytes set only the first two words; 40 bytes are accepted; option 9 of that level and the level on an IPv4 raw socket
 *      are ENOPROTOOPT;
 *   K. IPV6_CHECKSUM reads 2 and cannot be set (EINVAL);
 *   C. connect to ::1: send and write reach it, both copies come back; a 16-byte address EINVAL, AF_INET EAFNOSUPPORT;
 *      getpeername ENOTCONN; connect(AF_UNSPEC), then send is EDESTADDRREQ;
 *   B. bind to ::1 names it with port 58; a 16-byte address and an AF_INET one are EINVAL, 2001:db8::9 EADDRNOTAVAIL;
 *   H. shutdown(SHUT_RD) of an unconnected socket is ENOTCONN but takes effect: poll shows POLLIN|POLLRDHUP, recv with
 *      MSG_DONTWAIT is EAGAIN, a blocking recv returns 0, a datagram that arrives later is still read; SHUT_WR leaves sends alone;
 *      a connected socket shuts down with 0 and SHUT_RDWR adds POLLHUP; an IPv4 raw socket behaves the same (ENOTCONN, then 0);
 *   U. a UDP datagram to [::1]:9 shows up as the ICMPv6 port unreachable it caused (type 1 code 4, quoting UDP);
 *   Z. an IPv4 raw socket: sends of 0 and 1 bytes are EFAULT, 2 bytes go out, and none of the IPv6 traffic reaches it;
 *   L. listen and accept are EOPNOTSUPP. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <netinet/icmp6.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock_(int dom, int type, int proto) { return rc(socket(dom, type, proto)); }
static long bind_(long s, const unsigned char *a, int l) { return rc(bind((int)s, (const void *)a, l)); }
static long connect_(long s, const unsigned char *a, int l) { return rc(connect((int)s, (const void *)a, l)); }
static long name_(long s, unsigned char *a, int peer) { socklen_t l = 28; long r = rc(peer ? getpeername((int)s, (void *)a, &l) : getsockname((int)s, (void *)a, &l)); return r < 0 ? r : (long)l; }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return rc(sendto((int)s, b, n, MSG_NOSIGNAL, (const void *)to, l)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, MSG_NOSIGNAL)); }
static long write_(long s, const void *b, int n) { return rc(write((int)s, b, n)); }
static long recvfrom_(long s, void *b, int n, int fl, unsigned char *from, long *flen) { socklen_t l = (socklen_t)*flen; long r = rc(recvfrom((int)s, b, n, fl, (void *)from, from ? &l : 0)); *flen = l; return r; }
static long getopt_(long s, int lvl, int opt, void *v, long *len) { socklen_t l = (socklen_t)*len; long r = rc(getsockopt((int)s, lvl, opt, v, &l)); *len = l; return r; }
static long setopt_(long s, int lvl, int opt, const void *v, int len) { return rc(setsockopt((int)s, lvl, opt, v, len)); }
static long poll_ev(long s) { struct pollfd p = { (int)s, POLLIN | POLLOUT | POLLRDHUP, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : p.revents; }
static long listen_(long s) { return rc(listen((int)s, 1)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long shutdown_(long s, int how) { return rc(shutdown((int)s, how)); }
static void nap(void) { struct timespec t = { 0, 50000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a, f) do { unsigned short fam = (f); memcpy(a, &fam, 2); } while (0)
#define MSG_DONTWAIT_ MSG_DONTWAIT
#define MSG_TRUNC_ MSG_TRUNC
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
#define AF_INET6 10
#define SOCK_DGRAM 2
#define SOCK_RAW 3
#define IPPROTO_ICMP 1
#define IPPROTO_ICMPV6 58
#define SOL_SOCKET 1
#define SO_TYPE 3
#define SO_DOMAIN 39
#define SO_PROTOCOL 38
#define IPPROTO_IPV6 41
#define IPV6_CHECKSUM 7
#define ICMP6_FILTER 1
#define POLLIN 1
#define POLLOUT 4
#define POLLHUP 0x10
#define POLLRDHUP 0x2000
#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2
static long sock_(int dom, int type, int proto) { return syscall3(117, dom, type, proto); }
static long bind_(long s, const unsigned char *a, int l) { return syscall3(118, s, (long)a, l); }
static long connect_(long s, const unsigned char *a, int l) { return syscall3(124, s, (long)a, l); }
static long name_(long s, unsigned char *a, int peer) { int l = 28; long r = syscall3(peer ? 127 : 126, s, (long)a, (long)&l); return r < 0 ? r : (long)l; }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return syscall6(121, s, (long)b, n, 0, (long)to, l); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long write_(long s, const void *b, int n) { return syscall3(1, s, (long)b, n); }
static long recvfrom_(long s, void *b, int n, int fl, unsigned char *from, long *flen) { int l = (int)*flen; long r = syscall6(122, s, (long)b, n, fl, (long)from, from ? (long)&l : 0); *flen = l; return r; }
static long getopt_(long s, int lvl, int opt, void *v, long *len) { int l = (int)*len; long r = syscall5(133, s, lvl, opt, (long)v, (long)&l); *len = l; return r; }
static long setopt_(long s, int lvl, int opt, const void *v, int len) { return syscall5(132, s, lvl, opt, (long)v, len); }
static long poll_ev(long s) { struct { int fd; short ev, rev; } p = { (int)s, POLLIN | POLLOUT | POLLRDHUP, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static long listen_(long s) { return syscall2(119, s, 1); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long shutdown_(long s, int how) { return syscall2(125, s, how); }
static void nap(void) { long t[2] = { 0, 50000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#define MSG_DONTWAIT_ 0x40
#define MSG_TRUNC_ 0x20
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello391:   ok   " : "hello391:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char buf[2048];
static int is_lo6(const unsigned char *a) {
    for (int i = 0; i < 15; i++) if (a[i]) return 0;
    return a[15] == 1;
}
/* The next datagram from ::1: ICMPv6 from the network (router advertisements, neighbour discovery) reaches every raw ICMPv6
   socket too, and is not what these checks are about. */
static long rxf(long s, int n, int fl, unsigned char *from, long *flen) {
    for (;;) {
        unsigned char f[28];
        long l = 28;
        for (int i = 0; i < 28; i++) f[i] = 0xee;
        long r = recvfrom_(s, buf, n, fl, f, &l);
        if (r <= 0 || is_lo6(f + 8)) {
            if (from) { for (int i = 0; i < 28; i++) from[i] = f[i]; *flen = l; }
            return r;
        }
    }
}
static long rx(long s) { return rxf(s, sizeof buf, MSG_DONTWAIT_, 0, 0); }
static void drain(long s) { long fl = 0; while (recvfrom_(s, buf, sizeof buf, MSG_DONTWAIT_, 0, &fl) >= 0) {} }
static void mk6(unsigned char *s, int last) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s, AF_INET6);
    s[23] = (unsigned char)last;
}
int main(void) {
    print("hello391: an IPv6 raw ICMPv6 socket gets its checksum from the kernel and a copy of every ICMPv6 message\n");
    unsigned char lo[28], a[28], from[28], e[16];
    mk6(lo, 1);
    for (int i = 0; i < 16; i++) e[i] = 0;
    e[0] = 128; e[2] = 0x12; e[3] = 0x34; e[4] = 0x39; e[5] = 0x10; e[7] = 1;
    for (int i = 8; i < 16; i++) e[i] = (unsigned char)('a' + i);

    long p0 = sock_(AF_INET6, SOCK_RAW, 0);
    long r = sock_(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6);
    int v = -1;
    long vl = 4;
    getopt_(r, SOL_SOCKET, SO_TYPE, &v, &vl);
    long ty = v;
    vl = 4; getopt_(r, SOL_SOCKET, SO_PROTOCOL, &v, &vl);
    long pr = v;
    vl = 4; getopt_(r, SOL_SOCKET, SO_DOMAIN, &v, &vl);
    long dm = v;
    for (int i = 0; i < 28; i++) a[i] = 0xee;
    long nl = name_(r, a, 0);
    int nm = a[0] == AF_INET6 && a[1] == 0 && a[2] == 0 && a[3] == 58;
    for (int i = 4; i < 28; i++) if (a[i]) nm = 0;
    long pn = name_(r, a, 1);
    snprintf(msg, sizeof msg, "A: protocol 0 %ld; socket %ld, SO_TYPE %ld SO_PROTOCOL %ld SO_DOMAIN %ld, getsockname %ld names port 58 of :: %d, getpeername %ld (-93 >=0 3 58 10 28 1 -107)", p0, r, ty, pr, dm, nl, nm, pn);
    check(p0 == -93 && r >= 0 && ty == 3 && pr == 58 && dm == 10 && nl == 28 && nm && pn == -107, msg);

    unsigned char a4[28], p17[28];
    mk6(a4, 1); FAM(a4, AF_INET);
    mk6(p17, 1); p17[3] = 17;
    long s1 = send_(r, e, 16), s2 = sendto_(r, e, 16, lo, 16), s3 = sendto_(r, e, 16, a4, 28), s4 = sendto_(r, e, 16, p17, 28);
    long z0 = sendto_(r, e, 0, lo, 28), z1 = sendto_(r, e, 1, lo, 28), z2 = sendto_(r, e, 2, lo, 28), z3 = sendto_(r, e, 3, lo, 28), z4 = sendto_(r, e, 4, lo, 28);
    nap();
    drain(r);
    snprintf(msg, sizeof msg, "S: send %ld, 16-byte address %ld, AF_INET %ld, port 17 %ld; 0 to 4 bytes %ld %ld %ld %ld %ld (-89 -22 -97 -22; -14 -14 -22 -22 4)", s1, s2, s3, s4, z0, z1, z2, z3, z4);
    check(s1 == -89 && s2 == -22 && s3 == -97 && s4 == -22 && z0 == -14 && z1 == -14 && z2 == -22 && z3 == -22 && z4 == 4, msg);

    long q0 = poll_ev(r);
    long se = sendto_(r, e, 16, lo, 28);
    nap();
    long q1 = poll_ev(r);
    long fl = 28;
    long n1 = rxf(r, sizeof buf, MSG_DONTWAIT_, from, &fl);
    int ok1 = n1 == 16 && buf[0] == 128 && buf[4] == 0x39 && buf[5] == 0x10 && !(buf[2] == 0x12 && buf[3] == 0x34);
    int name1 = fl == 28 && from[0] == AF_INET6 && from[2] == 0 && from[3] == 0 && from[4] == 0 && from[24] == 0;
    long n2 = rx(r);
    int ok2 = n2 == 16 && buf[0] == 129 && buf[4] == 0x39 && buf[5] == 0x10;
    long n3 = rx(r);
    snprintf(msg, sizeof msg, "E: sendto ::1 %ld; the request %ld (checksum fixed %d) from ::1 port 0 in %ld bytes (%d), the reply %ld (%d), then %ld (16 16 1 28 1 16 1 -11)", se, n1, ok1, fl, name1, n2, ok2, n3);
    check(se == 16 && ok1 && fl == 28 && name1 && ok2 && n3 == -11, msg);
    snprintf(msg, sizeof msg, "P: poll POLLIN with nothing queued %d, after a send %d (0 1)", (int)(q0 & POLLIN), (int)(q1 & POLLIN));
    check(q0 >= 0 && (q0 & POLLIN) == 0 && (q1 & POLLIN) != 0, msg);

    sendto_(r, e, 16, lo, 28);
    nap();
    long t1 = rxf(r, 5, MSG_DONTWAIT_ | MSG_TRUNC_, 0, 0);
    long t2 = rxf(r, 5, MSG_DONTWAIT_, 0, 0);
    drain(r);
    snprintf(msg, sizeof msg, "T: recv into 5 bytes with MSG_TRUNC %ld, without %ld (16 5)", t1, t2);
    check(t1 == 16 && t2 == 5, msg);

    unsigned int flt[10];
    for (int i = 0; i < 10; i++) flt[i] = 0x77777777;
    long fln = 64;
    long g1 = getopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, flt, &fln);
    int zero = 1;
    for (int i = 0; i < 8; i++) if (flt[i]) zero = 0;
    for (int i = 0; i < 8; i++) flt[i] = 0xffffffff;
    flt[4] &= ~(1u << (129 & 31));
    long f1 = setopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, flt, 32);
    sendto_(r, e, 16, lo, 28);
    nap();
    long fa = rx(r);
    int fty = buf[0];
    long fb = rx(r);
    for (int i = 0; i < 8; i++) flt[i] = 0;
    fln = 32;
    getopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, flt, &fln);
    unsigned int w4 = flt[4], w0 = flt[0];
    unsigned int ones[10];
    for (int i = 0; i < 10; i++) ones[i] = 0xffffffff;
    unsigned int zeros[8];
    for (int i = 0; i < 8; i++) zeros[i] = 0;
    setopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, zeros, 32);
    long f8 = setopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, ones, 8);
    fln = 32;
    getopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, flt, &fln);
    int part = flt[0] == 0xffffffff && flt[1] == 0xffffffff && flt[2] == 0;
    long f40 = setopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, zeros, 8);
    f40 = setopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, ones, 40);
    setopt_(r, IPPROTO_ICMPV6, ICMP6_FILTER, zeros, 32);
    long f9 = setopt_(r, IPPROTO_ICMPV6, 9, zeros, 4);
    long r4 = sock_(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    long f4 = setopt_(r4, IPPROTO_ICMPV6, ICMP6_FILTER, zeros, 32);
    drain(r);
    snprintf(msg, sizeof msg, "F: get %ld len %ld zero %d; pass only the reply %ld: %ld type %d then %ld, word4 0x%x word0 0x%x; 8 bytes %ld first two words %d; 40 bytes %ld; option 9 %ld; on IPv4 %ld (0 32 1 0 16 129 -11 0xfffffffd 0xffffffff 0 1 0 -92 -92)", g1, fln, zero, f1, fa, fty, fb, w4, w0, f8, part, f40, f9, f4);
    check(g1 == 0 && fln == 32 && zero && f1 == 0 && fa == 16 && fty == 129 && fb == -11 && w4 == 0xfffffffd && w0 == 0xffffffff && f8 == 0 && part && f40 == 0 && f9 == -92 && f4 == -92, msg);

    int cs = -5;
    long csl = 4;
    long k1 = getopt_(r, IPPROTO_IPV6, IPV6_CHECKSUM, &cs, &csl);
    int two = 2;
    long k2 = setopt_(r, IPPROTO_IPV6, IPV6_CHECKSUM, &two, 4);
    snprintf(msg, sizeof msg, "K: IPV6_CHECKSUM get %ld reads %d, set %ld (0 2 -22)", k1, cs, k2);
    check(k1 == 0 && cs == 2 && k2 == -22, msg);

    long c = sock_(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6);
    long cc = connect_(c, lo, 28);
    long w1 = send_(c, e, 16);
    nap();
    long ca = rx(c);
    int cta = buf[0];
    long cb = rx(c);
    int ctb = buf[0];
    long w2 = write_(c, e, 16);
    nap();
    long cd = rx(c), ce = rx(c), cn = rx(c);
    long c16 = connect_(c, lo, 16), c4 = connect_(c, a4, 28);
    long cp = name_(c, a, 1);
    unsigned char un[28];
    for (int i = 0; i < 28; i++) un[i] = 0;
    long cu = connect_(c, un, 28), cs2 = send_(c, e, 16);
    drain(r);
    drain(c);
    snprintf(msg, sizeof msg, "C: connect %ld; send %ld, back %ld/%d %ld/%d; write %ld, back %ld %ld then %ld; 16 bytes %ld, AF_INET %ld; getpeername %ld; AF_UNSPEC %ld then send %ld (0 16 16/128 16/129 16 16 16 -11 -22 -97 -107 0 -89)", cc, w1, ca, cta, cb, ctb, w2, cd, ce, cn, c16, c4, cp, cu, cs2);
    check(cc == 0 && w1 == 16 && ca == 16 && cta == 128 && cb == 16 && ctb == 129 && w2 == 16 && cd == 16 && ce == 16 && cn == -11 && c16 == -22 && c4 == -97 && cp == -107 && cu == 0 && cs2 == -89, msg);

    long b = sock_(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6);
    long b1 = bind_(b, lo, 28);
    for (int i = 0; i < 28; i++) a[i] = 0;
    long bn = name_(b, a, 0);
    int bnm = a[3] == 58 && is_lo6(a + 8);
    unsigned char far[28];
    mk6(far, 9); far[8] = 0x20; far[9] = 0x01; far[10] = 0x0d; far[11] = 0xb8;
    long b2 = bind_(b, lo, 16), b3 = bind_(b, a4, 28), b4 = bind_(b, far, 28);
    close_(b);
    snprintf(msg, sizeof msg, "B: bind ::1 %ld, getsockname %ld names it with port 58 %d; 16 bytes %ld, AF_INET %ld, 2001:db8::9 %ld (0 28 1 -22 -22 -99)", b1, bn, bnm, b2, b3, b4);
    check(b1 == 0 && bn == 28 && bnm && b2 == -22 && b3 == -22 && b4 == -99, msg);

    long h = sock_(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6);
    long h1 = shutdown_(h, SHUT_RD);
    long hp = poll_ev(h);
    long hn = rxf(h, sizeof buf, MSG_DONTWAIT_, 0, 0);
    long hb = rxf(h, sizeof buf, 0, 0, 0);
    sendto_(r, e, 16, lo, 28);
    nap();
    long hl = rx(h);
    long hw = sock_(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6);
    long h2 = shutdown_(hw, SHUT_WR), hwp = poll_ev(hw), hws = sendto_(hw, e, 16, lo, 28);
    long hc = sock_(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6);
    connect_(hc, lo, 28);
    long h3 = shutdown_(hc, SHUT_RDWR), hcp = poll_ev(hc), h7 = shutdown_(hc, 7);
    unsigned char l4[16];
    for (int i = 0; i < 16; i++) l4[i] = 0;
    l4[0] = AF_INET; l4[4] = 127; l4[7] = 1;
    long v41 = shutdown_(r4, SHUT_RD);
    connect_(r4, l4, 16);
    long v42 = shutdown_(r4, SHUT_RD);
    close_(r4);
    close_(h); close_(hw); close_(hc);
    drain(r);
    snprintf(msg, sizeof msg, "H: SHUT_RD unconnected %ld, poll 0x%lx, recv %ld, blocking %ld, later %ld; SHUT_WR %ld poll 0x%lx sendto %ld; connected SHUT_RDWR %ld poll 0x%lx, how 7 %ld; IPv4 %ld then %ld (-107 0x2005 -11 0 16 -107 0x4(+1) 16 0 0x2015 -22 -107 0)", h1, hp, hn, hb, hl, h2, hwp, hws, h3, hcp, h7, v41, v42);
    check(h1 == -107 && hp == 0x2005 && hn == -11 && hb == 0 && hl == 16 && h2 == -107 && (hwp & ~1) == 0x4 && hws == 16 && h3 == 0 && hcp == 0x2015 && h7 == -22 && v41 == -107 && v42 == 0, msg);

    long u = sock_(AF_INET6, SOCK_DGRAM, 0);
    unsigned char p9[28];
    mk6(p9, 1); p9[3] = 9;
    long us = sendto_(u, "x", 1, p9, 28);
    nap();
    long un1 = rx(r);
    int uok = un1 >= 48 && buf[0] == 1 && buf[1] == 4 && buf[8 + 6] == 17 && buf[48 + 2] == 0 && buf[48 + 3] == 9;
    close_(u);
    drain(r);
    snprintf(msg, sizeof msg, "U: a UDP datagram to [::1]:9 %ld shows up as port unreachable %ld quoting UDP port 9 (%d) (1 >=48 1)", us, un1, uok);
    check(us == 1 && uok, msg);

    long z = sock_(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    unsigned char e4[8] = { 8, 0, 0xf7, 0xfe, 0, 1, 0, 0 };
    long y0 = sendto_(z, e4, 0, l4, 16), y1 = sendto_(z, e4, 1, l4, 16), y2 = sendto_(z, e4, 2, l4, 16), yu = send_(z, e4, 0);
    nap();
    drain(z);
    sendto_(r, e, 16, lo, 28);
    nap();
    int leaked = 0;
    for (int i = 0; i < 16; i++) {
        long fz = 0;
        long n = recvfrom_(z, buf, sizeof buf, MSG_DONTWAIT_, 0, &fz);
        if (n < 0) break;
        if (n < 20 || (buf[0] >> 4) != 4) leaked++;
    }
    close_(z);
    drain(r);
    snprintf(msg, sizeof msg, "Z: IPv4 raw sendto 0 1 2 bytes %ld %ld %ld, unconnected send of 0 %ld; IPv6 datagrams it saw %d (-14 -14 2 -89 0)", y0, y1, y2, yu, leaked);
    check(y0 == -14 && y1 == -14 && y2 == 2 && yu == -89 && leaked == 0, msg);

    long l1 = listen_(r), l2 = accept_(r);
    close_(r);
    close_(c);
    snprintf(msg, sizeof msg, "L: listen %ld, accept %ld (-95 -95)", l1, l2);
    check(l1 == -95 && l2 == -95, msg);

    print(failures ? "hello391: FAIL\n" : "hello391: PASS\n");
    return failures ? 1 : 0;
}
