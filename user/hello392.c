/* hello392: an ICMPv6 error reaches the IPv6 socket whose datagram caused it (Linux icmpv6_rcv → icmpv6_notify → __udp6_lib_err /
 * icmpv6_err → ping_err, icmpv6_err_convert): a hard error on a connected IPv6 UDP or ping socket becomes its SO_ERROR and fails the
 * next send or receive once; soft errors and unconnected sockets are left alone (only IPV6_RECVERR would report them). The errors are
 * written through a raw ICMPv6 socket to ::1, quoting a datagram ::1 -> ::1 the socket sent. Measured on the host (build with -DHOST,
 * run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   U. a UDP socket connected to [::1]:9 takes, for destination unreachable codes 0..7, 0 13 0 0 111 13 13 71 (EACCES for codes 1, 5
 *      and 6, ECONNREFUSED for 4, EPROTO for an unknown code); packet too big EMSGSIZE (90); time exceeded nothing; parameter problem
 *      codes 0..2 EPROTO (71); an unknown error type (5, 100) nothing;
 *   N. an unconnected UDP socket takes none of them;
 *   A. an error quoting a datagram to [::2]:9 does not reach the socket connected to [::1]:9;
 *   P. an IPv6 ping socket connected to ::1 takes the same errnos for errors quoting its echo requests, except packet too big (soft
 *      for a ping socket);
 *   Q. an unconnected (bound) IPv6 ping socket takes none;
 *   R. an error quoting an echo reply, or an echo request with code 1, is for no ping socket;
 *   V. a pending error shows as POLLERR, fails the next ping recv once (ECONNREFUSED), then EAGAIN;
 *   S. it fails the next ping send once, and SO_ERROR reads 0 afterwards;
 *   E. on UDP too: recv is EACCES for code 1, then EAGAIN; send is EPROTO for a parameter problem;
 *   W. an unconnected IPv6 ping socket with IPV6_RECVERR (SOL_IPV6 25) queues even soft errors (ping_err → ipv6_icmp_error): address
 *      unreachable (1/3) gives SO_ERROR 113 and recvmsg(MSG_ERRQUEUE) returns the 8 quoted echo-request bytes, msg_name [::1] port 0
 *      (28 bytes), IPV6_RECVERR (SOL_IPV6/25) with errno 113, origin 3, type 1, code 3; packet too big (soft for ping) gives 90.
 *   X. a raw IPv6 socket of protocol 253 (raw6_icmp_error → rawv6_err): unconnected without IPV6_RECVERR it takes nothing; connected
 *      it takes only hard errors (the U list without packet too big, which is hard only under IPV6_PMTUDISC_DO), port unreachable
 *      fails the next recv once while send still works; with IPV6_RECVERR, unconnected, address unreachable is SO_ERROR 113 and
 *      POLLERR, MSG_ERRQUEUE returns the 8 bytes after the quoted IPv6 header, msg_name [::1] port 0, errno 113 origin 3 type 1
 *      code 3; packet too big is queued too (SO_ERROR 90).
 * The test sets net.ipv4.ping_group_range to "0 0" and puts the old value back at the end. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long rsock(void) { return rc(socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)); }
static long usock(void) { return rc(socket(AF_INET6, SOCK_DGRAM, 0)); }
static long psock(void) { return rc(socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)); }
static long rsockp(int p) { return rc(socket(AF_INET6, SOCK_RAW, p)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 28)); }
static long name_(long s, unsigned char *a) { socklen_t l = 28; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, 0)); }
static long recv_(long s, void *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long soerr(long s) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, SO_ERROR, &v, &l)); return r < 0 ? r : v; }
static long revents(long s) { struct pollfd p = { (int)s, POLLIN, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : p.revents; }
static long open_(const char *p, int fl) { return rc(open(p, fl)); }
static long read_(long fd, char *b, int n) { return rc(read((int)fd, b, n)); }
static long write_(long fd, const char *b, int n) { return rc(write((int)fd, b, n)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
static long setopt_(long s, int lv, int o, int v) { return rc(setsockopt((int)s, lv, o, &v, 4)); }
static long recvmsg_(long s, void *m, int fl) { return rc(recvmsg((int)s, m, fl)); }
#define FAM6(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#define O_WR O_WRONLY
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rsock(void) { return syscall3(117, 10, 3, 58); }
static long usock(void) { return syscall3(117, 10, 2, 0); }
static long psock(void) { return syscall3(117, 10, 2, 58); }
static long rsockp(int p) { return syscall3(117, 10, 3, p); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 28); }
static long name_(long s, unsigned char *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recv_(long s, void *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long soerr(long s) { int v = -1; int l = 4; long r = syscall5(133, s, 1, 4, (long)&v, (long)&l); return r < 0 ? r : v; }
static long revents(long s) { struct { int fd; short ev, rev; } p = { (int)s, 1, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : p.rev; }
static long open_(const char *p, int fl) { return syscall3(9, (long)p, fl, 0); }
static long read_(long fd, char *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const char *b, int n) { return syscall3(1, fd, (long)b, n); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
static long setopt_(long s, int lv, int o, int v) { return syscall5(132, s, lv, o, (long)&v, 4); }
static long recvmsg_(long s, void *m, int fl) { return syscall3(130, s, (long)m, fl); }
#define FAM6(a) do { (a)[0] = 10; (a)[1] = 0; } while (0)
#define O_WR 1
#endif
static int failures;
static char msg[700];
static void check(int ok, const char *w) {
    print(ok ? "hello392:   ok   " : "hello392:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
#define RANGE "/proc/sys/net/ipv4/ping_group_range"
static long set_range(const char *text) {
    long fd = open_(RANGE, O_WR);
    if (fd < 0) return fd;
    long n = write_(fd, text, (int)strlen(text));
    close_(fd);
    return n;
}
static long raw;
static unsigned char lo[28];
static unsigned char sink[2048];
/* An ICMPv6 error of `type`/`code` sent to ::1 through the raw socket (the kernel fills in its checksum), quoting a packet from ::1
   to ::`dst_last` of next header `proto` whose first 8 payload bytes are `l4`. Packet too big carries MTU 65535 so no path MTU
   shrinks. */
static void inject(int type, int code, int proto, const unsigned char *l4, int dst_last) {
    unsigned char m[56];
    for (int i = 0; i < 56; i++) m[i] = 0;
    m[0] = (unsigned char)type; m[1] = (unsigned char)code;
    if (type == 2) { m[6] = 0xff; m[7] = 0xff; }
    if (type == 4) m[7] = 6;
    unsigned char *ip = m + 8;
    ip[0] = 0x60; ip[5] = 8; ip[6] = (unsigned char)proto; ip[7] = 64;
    ip[23] = 1; ip[39] = (unsigned char)dst_last;
    for (int i = 0; i < 8; i++) m[48 + i] = l4[i];
    sendto_(raw, m, 56, lo);
    nap();
    while (recv_(raw, sink, sizeof sink) >= 0) {}
}
#define NK 15
static const int kinds[NK][2] = { {1,0},{1,1},{1,2},{1,3},{1,4},{1,5},{1,6},{1,7},{2,0},{3,0},{4,0},{4,1},{4,2},{5,0},{100,0} };
static const long want_udp[NK] = { 0, 13, 0, 0, 111, 13, 13, 71, 90, 0, 71, 71, 71, 0, 0 };
/* rawv6_err on a connected raw socket: only hard errors (icmpv6_err_convert), packet too big hard only under IPV6_PMTUDISC_DO. */
static const long want_raw[NK] = { 0, 13, 0, 0, 111, 13, 13, 71, 0, 0, 71, 71, 71, 0, 0 };
static const long want_ping[NK] = { 0, 13, 0, 0, 111, 13, 13, 71, 0, 0, 71, 71, 71, 0, 0 };
/* Every kind quoting `l4`; the SO_ERROR each leaves on `s` goes to `got`; returns how many matched `want` (or 0 when it is null). */
static int sweep(long s, int proto, const unsigned char *l4, const long *want, long *got) {
    int ok = 0;
    for (int k = 0; k < NK; k++) {
        inject(kinds[k][0], kinds[k][1], proto, l4, 1);
        got[k] = soerr(s);
        if (got[k] == (want ? want[k] : 0)) ok++;
    }
    return ok;
}
static void list(char *out, const long *v) {
    int o = 0;
    for (int k = 0; k < NK; k++) o += snprintf(out + o, 200 - o, "%s%ld", k ? " " : "", v[k]);
}
static void mk6(unsigned char *a, int port, int last) {
    for (int i = 0; i < 28; i++) a[i] = 0;
    FAM6(a);
    a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port;
    a[23] = (unsigned char)last;
}
int main(void) {
    print("hello392: an ICMPv6 error reaches the connected IPv6 UDP or ping socket whose datagram caused it\n");
    char saved[48];
    long sfd = open_(RANGE, 0);
    long sn = sfd >= 0 ? read_(sfd, saved, sizeof saved - 1) : -1;
    if (sfd >= 0) close_(sfd);
    if (sn < 0) sn = 0;
    saved[sn] = 0;
    long sr = set_range("0 0");
    mk6(lo, 0, 1);
    raw = rsock();
    unsigned char a[28], p9[28];
    mk6(p9, 9, 1);
    char l1[200];
    long got[NK];

    long u = usock();
    long uc = connect_(u, p9);
    name_(u, a);
    unsigned char uh[8] = { a[2], a[3], 0, 9, 0, 8, 0, 0 };
    int uok = sweep(u, 17, uh, want_udp, got);
    list(l1, got);
    snprintf(msg, sizeof msg, "U: raw %ld, range %ld, connect %ld port %d; SO_ERROR per error %s (%d of %d)", raw, sr, uc, (a[2] << 8) | a[3], l1, uok, NK);
    check(raw >= 0 && uc == 0 && uok == NK, msg);

    long n = usock();
    unsigned char any[28];
    mk6(any, 0, 0);
    long nb = bind_(n, any);
    name_(n, a);
    unsigned char nh[8] = { a[2], a[3], 0, 9, 0, 8, 0, 0 };
    int nok = sweep(n, 17, nh, 0, got);
    list(l1, got);
    snprintf(msg, sizeof msg, "N: unconnected UDP bind %ld: %s (%d of %d zero)", nb, l1, nok, NK);
    check(nb == 0 && nok == NK, msg);
    close_(n);

    inject(1, 4, 17, uh, 2);
    long ae = soerr(u);
    snprintf(msg, sizeof msg, "A: an error quoting a datagram to [::2]:9 leaves %ld (0)", ae);
    check(ae == 0, msg);

    long pc = psock();
    long pcc = connect_(pc, lo);
    unsigned char rq[8] = { 128, 0, 0, 0, 0, 0, 0, 1 };
    long ps = send_(pc, rq, 8);
    nap();
    while (recv_(pc, sink, sizeof sink) >= 0) {}
    name_(pc, a);
    unsigned char eq[8] = { 128, 0, 0, 0, a[2], a[3], 0, 1 };
    int pok = sweep(pc, 58, eq, want_ping, got);
    list(l1, got);
    snprintf(msg, sizeof msg, "P: ping socket %ld connect %ld send %ld ident %d: %s (%d of %d)", pc, pcc, ps, (a[2] << 8) | a[3], l1, pok, NK);
    check(pc >= 0 && pcc == 0 && ps == 8 && pok == NK, msg);

    long pu = psock();
    unsigned char b42[28];
    mk6(b42, 4392, 0);
    long pub = bind_(pu, b42);
    unsigned char eu[8] = { 128, 0, 0, 0, 4392 >> 8, 4392 & 0xff, 0, 1 };
    int qok = sweep(pu, 58, eu, 0, got);
    list(l1, got);
    snprintf(msg, sizeof msg, "Q: unconnected ping socket bind %ld: %s (%d of %d zero)", pub, l1, qok, NK);
    check(pub == 0 && qok == NK, msg);
    close_(pu);

    unsigned char er[8] = { 129, 0, 0, 0, eq[4], eq[5], 0, 1 };
    inject(1, 4, 58, er, 1);
    long re = soerr(pc);
    unsigned char ec[8] = { 128, 1, 0, 0, eq[4], eq[5], 0, 1 };
    inject(1, 4, 58, ec, 1);
    long ce = soerr(pc);
    snprintf(msg, sizeof msg, "R: quoting an echo reply %ld, an echo request with code 1 %ld (0 0)", re, ce);
    check(re == 0 && ce == 0, msg);

    inject(1, 4, 58, eq, 1);
    long pv = revents(pc);
    long v1 = recv_(pc, sink, 64), v2 = recv_(pc, sink, 64), ve = soerr(pc);
    snprintf(msg, sizeof msg, "V: POLLERR %d, recv %ld then %ld, SO_ERROR %ld (1 -111 -11 0)", (pv & 8) != 0, v1, v2, ve);
    check((pv & 8) != 0 && v1 == -111 && v2 == -11 && ve == 0, msg);

    inject(1, 4, 58, eq, 1);
    long s1 = send_(pc, rq, 8), se = soerr(pc);
    nap();
    while (recv_(pc, sink, sizeof sink) >= 0) {}
    snprintf(msg, sizeof msg, "S: send %ld, SO_ERROR after %ld (-111 0)", s1, se);
    check(s1 == -111 && se == 0, msg);
    close_(pc);

    inject(1, 1, 17, uh, 1);
    long e1 = recv_(u, sink, 64), e2 = recv_(u, sink, 64);
    inject(4, 0, 17, uh, 1);
    long e3 = send_(u, "x", 1), e4 = soerr(u);
    snprintf(msg, sizeof msg, "E: UDP recv %ld then %ld; send %ld, SO_ERROR %ld (-13 -11 -71 0)", e1, e2, e3, e4);
    check(e1 == -13 && e2 == -11 && e3 == -71 && e4 == 0, msg);
    close_(u);

    long pw = psock();
    unsigned char b43[28];
    mk6(b43, 4393, 0);
    long pwb = bind_(pw, b43);
    long pwo = setopt_(pw, 41, 25, 1);
    unsigned char ew[8] = { 128, 0, 0, 0, 4393 >> 8, 4393 & 0xff, 0, 1 };
    inject(1, 3, 58, ew, 1);
    long we = soerr(pw);
    struct { void *b; unsigned long n; } wio = { sink, sizeof sink };
    unsigned char wname[32], wctl[96];
    struct { void *name; unsigned int nl; int pad; void *iov; unsigned long iovlen; void *ctl; unsigned long ctllen; int flags; int pad2; } wm;
    memset(&wm, 0, sizeof wm);
    memset(wname, 0xee, sizeof wname);
    memset(wctl, 0, sizeof wctl);
    wm.name = wname;
    wm.nl = sizeof wname;
    wm.iov = &wio;
    wm.iovlen = 1;
    wm.ctl = wctl;
    wm.ctllen = sizeof wctl;
    long wr = recvmsg_(pw, &wm, 0x2000 | 0x40);
    int werr, wlv, wty;
    memcpy(&wlv, wctl + 8, 4);
    memcpy(&wty, wctl + 12, 4);
    memcpy(&werr, wctl + 16, 4);
    int wquote = wr == 8 && memcmp(sink, ew, 8) == 0;
    inject(2, 0, 58, ew, 1);
    long wq = soerr(pw);
    snprintf(msg, sizeof msg, "W: IPV6_RECVERR ping bind %ld set %ld; SO_ERROR %ld; errqueue %ld quote %d, namelen %u family %d last %d port %d, flags 0x%x, "
             "[%d/%d] errno %d origin %d type %d code %d; packet too big SO_ERROR %ld (0 0; 113; 8 1, 28 10 1 0, 0x2000, [41/25] 113 3 1 3; 90)", pwb, pwo, we, wr,
             wquote, wm.nl, wname[0], wname[23], (wname[2] << 8) | wname[3], wm.flags, wlv, wty, werr, wctl[20], wctl[21], wctl[22], wq);
    check(pwb == 0 && pwo == 0 && we == 113 && wquote && wm.nl == 28 && wname[0] == 10 && wname[23] == 1 && wname[2] == 0 && wname[3] == 0 &&
              wm.flags == 0x2000 && wlv == 41 && wty == 25 && werr == 113 && wctl[20] == 3 && wctl[21] == 1 && wctl[22] == 3 && wq == 90,
          msg);
    close_(pw);

    unsigned char xl4[8] = { 0x68, 0x69, 0x21, 0, 0, 0, 0, 0 };
    long xr = rsockp(253);
    long xn[NK], xc_[NK];
    int xnok = sweep(xr, 253, xl4, 0, xn);
    long xc = connect_(xr, lo);
    int xcok = sweep(xr, 253, xl4, want_raw, xc_);
    char l3[200], l4[200];
    list(l3, xn);
    list(l4, xc_);
    inject(1, 4, 253, xl4, 1);
    long xrv = recv_(xr, sink, sizeof sink);
    long xsd = send_(xr, xl4, 8);
    snprintf(msg, sizeof msg, "X1: raw IPv6 253 %ld unconnected %s (%d of %d zero); connect %ld: %s (%d of %d); port unreachable recv %ld, send %ld (-111 8)", xr, l3,
             xnok, NK, xc, l4, xcok, NK, xrv, xsd);
    check(xr >= 0 && xnok == NK && xc == 0 && xcok == NK && xrv == -111 && xsd == 8, msg);
    close_(xr);

    long xq = rsockp(253);
    long xo = setopt_(xq, 41, 25, 1);
    inject(1, 3, 253, xl4, 1);
    long xp = revents(xq);
    long xe = soerr(xq);
    memset(&wm, 0, sizeof wm);
    memset(wname, 0xee, sizeof wname);
    memset(wctl, 0, sizeof wctl);
    memset(sink, 0, 64);
    wm.name = wname;
    wm.nl = sizeof wname;
    wm.iov = &wio;
    wm.iovlen = 1;
    wm.ctl = wctl;
    wm.ctllen = sizeof wctl;
    long xm = recvmsg_(xq, &wm, 0x2000 | 0x40);
    memcpy(&wlv, wctl + 8, 4);
    memcpy(&wty, wctl + 12, 4);
    memcpy(&werr, wctl + 16, 4);
    int xquote = xm == 8 && memcmp(sink, xl4, 8) == 0;
    int xo0 = wctl[20], xo1 = wctl[21], xo2 = wctl[22];
    unsigned int xnl = wm.nl;
    int xfl = wm.flags;
    inject(2, 0, 253, xl4, 1);
    long xt = soerr(xq);
    long xtm = recvmsg_(xq, &wm, 0x2000 | 0x40);
    snprintf(msg, sizeof msg, "X2: IPV6_RECVERR raw set %ld; POLLERR %d SO_ERROR %ld; errqueue %ld quote %d, namelen %u family %d last %d port %d, flags 0x%x, "
             "[%d/%d] errno %d origin %d type %d code %d; packet too big SO_ERROR %ld, queued %ld (0; 1 113; 8 1, 28 10 1 0, 0x2000, [41/25] 113 3 1 3; 90 8)", xo,
             (xp & 8) != 0, xe, xm, xquote, xnl, wname[0], wname[23], (wname[2] << 8) | wname[3], xfl, wlv, wty, werr, xo0, xo1, xo2, xt, xtm);
    check(xo == 0 && (xp & 8) != 0 && xe == 113 && xquote && xnl == 28 && wname[0] == 10 && wname[23] == 1 && wname[2] == 0 && wname[3] == 0 &&
              xfl == 0x2000 && wlv == 41 && wty == 25 && werr == 113 && xo0 == 3 && xo1 == 1 && xo2 == 3 && xt == 90 && xtm == 8,
          msg);
    close_(xq);
    close_(raw);

    long back = set_range(saved);
    snprintf(msg, sizeof msg, "restored ping_group_range (%ld)", back);
    print("hello392:   info ");
    print(msg);
    print("\n");
    print(failures ? "hello392: FAIL\n" : "hello392: PASS\n");
    return failures ? 1 : 0;
}
