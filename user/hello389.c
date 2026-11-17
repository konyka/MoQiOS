/* hello389: an IPv4 raw ICMP socket (socket(AF_INET, SOCK_RAW, IPPROTO_ICMP), Linux net/ipv4/raw.c). A send gets an IP header
 * from the kernel and leaves for the address given (or the connected one); every ICMP datagram this host receives is copied to
 * each raw ICMP socket whose bound address and connected peer match, IP header included. Measured on the host (build with -DHOST,
 * run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   A. SO_TYPE 3, SO_PROTOCOL 1; getsockname names AF_INET, port 1 (the protocol), 0.0.0.0; getpeername is ENOTCONN;
 *   S. send without a destination is EDESTADDRREQ, write too; a 8-byte address EINVAL, an AF_INET6 one EAFNOSUPPORT;
 *   E. an echo request sent to 127.0.0.1 comes back twice, first the request, then the kernel's reply: 36 bytes each (IP header
 *      0x45, total 36, protocol 1, both addresses 127.0.0.1), recvfrom names 127.0.0.1 port 0 in 16 bytes; then EAGAIN;
 *   P. poll shows no POLLIN with nothing queued, POLLIN after a send;
 *   T. recv into 10 bytes with MSG_TRUNC returns 36, without it 10;
 *   C. a socket connected to 127.0.0.2 sees nothing of 127.0.0.1's traffic; one connected to 127.0.0.1 sends with send() and
 *      write() and reads both datagrams, read() too;
 *   B. bind to 127.0.0.2 names it in getsockname and the socket then misses datagrams to 127.0.0.1; bind to 10.9.9.9 is
 *      EADDRNOTAVAIL, a 8-byte address EINVAL;
 *   U. connect(AF_UNSPEC) drops the peer: send is EDESTADDRREQ again;
 *   D. a dup keeps the socket after the original descriptor is closed;
 *   M. 8 raw sockets each get their own copy;
 *   X. a UDP datagram to 127.0.0.1:9 shows up as the ICMP port unreachable it caused (type 3 code 3, quoting port 9);
 *   I. a port unreachable written through the raw socket, quoting what a connected UDP socket sent, sets that socket's SO_ERROR
 *      to ECONNREFUSED;
 *   L. listen and accept are EOPNOTSUPP. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long rsock(void) { return rc(socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)); }
static long usock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long bind_(long s, const unsigned char *a, int l) { return rc(bind((int)s, (const void *)a, l)); }
static long connect_(long s, const unsigned char *a, int l) { return rc(connect((int)s, (const void *)a, l)); }
static long name_(long s, unsigned char *a, int peer) { socklen_t l = 16; long r = rc(peer ? getpeername((int)s, (void *)a, &l) : getsockname((int)s, (void *)a, &l)); return r < 0 ? r : (long)l; }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return rc(sendto((int)s, b, n, 0, (const void *)to, l)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, 0)); }
static long write_(long s, const void *b, int n) { return rc(write((int)s, b, n)); }
static long read_(long s, void *b, int n) { return rc(read((int)s, b, n)); }
static long recvfrom_(long s, void *b, int n, int fl, unsigned char *from, long *flen) { socklen_t l = (socklen_t)*flen; long r = rc(recvfrom((int)s, b, n, fl, (void *)from, from ? &l : 0)); *flen = l; return r; }
static long getint(long s, int opt) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, opt, &v, &l)); return r < 0 ? r : v; }
static long poll_in(long s) { struct pollfd p = { (int)s, POLLIN, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : (p.revents & POLLIN) != 0; }
static long dup_(long s) { return rc(dup((int)s)); }
static long listen_(long s) { return rc(listen((int)s, 1)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
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
#define SO_TYPE 3
#define SO_ERROR 4
#define SO_PROTOCOL 38
static long rsock(void) { return syscall3(117, AF_INET, 3, 1); }
static long usock(void) { return syscall3(117, AF_INET, 2, 0); }
static long bind_(long s, const unsigned char *a, int l) { return syscall3(118, s, (long)a, l); }
static long connect_(long s, const unsigned char *a, int l) { return syscall3(124, s, (long)a, l); }
static long name_(long s, unsigned char *a, int peer) { int l = 16; long r = syscall3(peer ? 127 : 126, s, (long)a, (long)&l); return r < 0 ? r : (long)l; }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return syscall6(121, s, (long)b, n, 0, (long)to, l); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long write_(long s, const void *b, int n) { return syscall3(1, s, (long)b, n); }
static long read_(long s, void *b, int n) { return syscall3(10, s, (long)b, n); }
static long recvfrom_(long s, void *b, int n, int fl, unsigned char *from, long *flen) { int l = (int)*flen; long r = syscall6(122, s, (long)b, n, fl, (long)from, from ? (long)&l : 0); *flen = l; return r; }
static long getint(long s, int opt) { int v = -1; int l = 4; long r = syscall5(133, s, 1, opt, (long)&v, (long)&l); return r < 0 ? r : v; }
static long poll_in(long s) { struct { int fd; short ev, rev; } p = { (int)s, 1, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (p.rev & 1) != 0; }
static long dup_(long s) { return syscall1(160, s); }
static long listen_(long s) { return syscall2(119, s, 1); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static void nap(void) { long t[2] = { 0, 50000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#define MSG_DONTWAIT_ 0x40
#define MSG_TRUNC_ 0x20
#endif
static unsigned short csum(const unsigned char *p, int n) {
    unsigned long s = 0;
    for (int i = 0; i + 1 < n; i += 2) s += (unsigned long)((p[i] << 8) | p[i + 1]);
    if (n & 1) s += (unsigned long)(p[n - 1] << 8);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (unsigned short)~s;
}
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello389:   ok   " : "hello389:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, int a, int b, int c, int d) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[4] = (unsigned char)a; s[5] = (unsigned char)b; s[6] = (unsigned char)c; s[7] = (unsigned char)d;
}
/* An echo request with ident 0x3809 and sequence `seq`, checksum set. */
static void echo(unsigned char *e, int seq) {
    e[0] = 8; e[1] = 0; e[2] = 0; e[3] = 0; e[4] = 0x38; e[5] = 0x09; e[6] = 0; e[7] = (unsigned char)seq;
    for (int i = 8; i < 16; i++) e[i] = (unsigned char)('a' + i);
    unsigned short c = csum(e, 16);
    e[2] = (unsigned char)(c >> 8); e[3] = (unsigned char)c;
}
static unsigned char buf[256];
static int is_lo(const unsigned char *p) { return p[0] == 127 && p[1] == 0 && p[2] == 0 && p[3] == 1; }
/* The next datagram 127.0.0.1 -> 127.0.0.1: ICMP that reaches the machine from outside (a late time exceeded or port unreachable
   the network sends back for an earlier program's traffic) goes to every raw socket too, and is not what these checks are about. */
static long rxf(long s, int n, int fl, unsigned char *from, long *flen) {
    for (;;) {
        unsigned char f[16];
        long l = 16;
        for (int i = 0; i < 16; i++) f[i] = 0xee;
        long r = recvfrom_(s, buf, n, fl, f, &l);
        /* Ours: from 127.0.0.1 and to 127.0.0.1 (a short read cannot see the destination, but every datagram here is 36 bytes). */
        long got = r < n ? r : n;
        int ours = is_lo(f + 4) && (got >= 20 ? is_lo(buf + 16) : got < 4 || (buf[2] == 0 && buf[3] == 36));
        if (r < 0 || ours) {
            if (from) { for (int i = 0; i < 16; i++) from[i] = f[i]; *flen = l; }
            return r;
        }
    }
}
static long rx(long s) { return rxf(s, sizeof buf, MSG_DONTWAIT_, 0, 0); }
static void drain(long s) { while (rx(s) >= 0) {} }
/* A 36-byte datagram 127.0.0.1 -> 127.0.0.1 carrying ICMP of `type`. */
static int is36(long n, int type) {
    return n == 36 && buf[0] == 0x45 && buf[2] == 0 && buf[3] == 36 && buf[9] == 1 && is_lo(buf + 12) && is_lo(buf + 16) && buf[20] == type;
}
int main(void) {
    print("hello389: an IPv4 raw ICMP socket sends with a kernel IP header and gets a copy of every ICMP datagram\n");
    unsigned char lo[16], lo2[16], far[16], a[28], from[16], e[16];
    mk4(lo, 127, 0, 0, 1); mk4(lo2, 127, 0, 0, 2); mk4(far, 10, 9, 9, 9);

    long r = rsock();
    long ty = getint(r, SO_TYPE), pr = getint(r, SO_PROTOCOL);
    long nl = name_(r, a, 0);
    int nm = a[0] == AF_INET && a[1] == 0 && a[2] == 0 && a[3] == 1 && a[4] == 0 && a[5] == 0 && a[6] == 0 && a[7] == 0;
    long pn = name_(r, a, 1);
    snprintf(msg, sizeof msg, "A: socket %ld, SO_TYPE %ld SO_PROTOCOL %ld, getsockname %ld names port 1 of 0.0.0.0 %d, getpeername %ld (>=0 3 1 16 1 -107)", r, ty, pr, nl, nm, pn);
    check(r >= 0 && ty == 3 && pr == 1 && nl == 16 && nm && pn == -107, msg);

    echo(e, 1);
    unsigned char a6[28];
    for (int i = 0; i < 28; i++) a6[i] = 0;
    FAM(a6, AF_INET6);
    long s1 = send_(r, e, 16), s2 = write_(r, e, 16), s3 = sendto_(r, e, 16, lo, 8), s4 = sendto_(r, e, 16, a6, 28);
    snprintf(msg, sizeof msg, "S: send %ld, write %ld, 8-byte address %ld, AF_INET6 address %ld (-89 -89 -22 -97)", s1, s2, s3, s4);
    check(s1 == -89 && s2 == -89 && s3 == -22 && s4 == -97, msg);

    long p0 = poll_in(r);
    long se = sendto_(r, e, 16, lo, 16);
    nap();
    long p1 = poll_in(r);
    long fl = 16;
    for (int i = 0; i < 16; i++) from[i] = 0xee;
    long n1 = rxf(r, sizeof buf, MSG_DONTWAIT_, from, &fl);
    int ok1 = is36(n1, 8) && buf[24] == 0x38 && buf[25] == 0x09 && buf[27] == 1;
    int name1 = fl == 16 && from[0] == AF_INET && from[2] == 0 && from[3] == 0 && is_lo(from + 4);
    long n2 = rx(r);
    int ok2 = is36(n2, 0) && buf[24] == 0x38 && buf[25] == 0x09;
    long n3 = rx(r);
    snprintf(msg, sizeof msg, "E: sendto 127.0.0.1 %ld; the request %ld (%d) from 127.0.0.1 port 0 in %ld bytes (%d), the reply %ld (%d), then %ld (16 36 1 16 1 36 1 -11)", se, n1, ok1, fl, name1, n2, ok2, n3);
    check(se == 16 && ok1 && name1 && ok2 && n3 == -11, msg);
    snprintf(msg, sizeof msg, "P: poll POLLIN with nothing queued %ld, after a send %ld (0 1)", p0, p1);
    check(p0 == 0 && p1 == 1, msg);

    echo(e, 2);
    sendto_(r, e, 16, lo, 16);
    nap();
    long t1 = rxf(r, 10, MSG_DONTWAIT_ | MSG_TRUNC_, 0, 0);
    long t2 = rxf(r, 10, MSG_DONTWAIT_, 0, 0);
    drain(r);
    snprintf(msg, sizeof msg, "T: recv into 10 bytes with MSG_TRUNC %ld, without %ld (36 10)", t1, t2);
    check(t1 == 36 && t2 == 10, msg);

    long c2 = rsock(), c1 = rsock();
    long cc2 = connect_(c2, lo2, 16), cc1 = connect_(c1, lo, 16);
    echo(e, 3);
    long cs = send_(c1, e, 16);
    nap();
    long ca = rx(c1);
    int oka = is36(ca, 8);
    long cb = rx(c1);
    int okb = is36(cb, 0);
    long cn = rx(c1), cx = rx(c2);
    echo(e, 4);
    long cw = write_(c1, e, 16);
    nap();
    long rd = read_(c1, buf, sizeof buf);
    int okr = is36(rd, 8);
    drain(c1); drain(c2); drain(r);
    snprintf(msg, sizeof msg, "C: connect to .2 %ld, to .1 %ld; send %ld, request %ld (%d), reply %ld (%d), then %ld; the .2 socket %ld; write %ld, read %ld (%d) (0 0 16 36 1 36 1 -11 -11 16 36 1)", cc2, cc1, cs, ca, oka, cb, okb, cn, cx, cw, rd, okr);
    check(cc2 == 0 && cc1 == 0 && cs == 16 && oka && okb && cn == -11 && cx == -11 && cw == 16 && okr, msg);

    long rb = rsock();
    long b1 = bind_(rb, lo2, 16);
    long bn = name_(rb, a, 0);
    int bnm = a[3] == 1 && a[4] == 127 && a[5] == 0 && a[6] == 0 && a[7] == 2;
    echo(e, 5);
    sendto_(r, e, 16, lo, 16);
    nap();
    long bm = rx(rb);
    drain(r); drain(c1); drain(c2);
    long rx2 = rsock();
    long bf = bind_(rx2, far, 16), bs = bind_(rx2, lo, 8);
    close_(rx2);
    snprintf(msg, sizeof msg, "B: bind 127.0.0.2 %ld, getsockname %ld names it %d, then traffic to 127.0.0.1 %ld; bind 10.9.9.9 %ld, 8-byte address %ld (0 16 1 -11 -99 -22)", b1, bn, bnm, bm, bf, bs);
    check(b1 == 0 && bn == 16 && bnm && bm == -11 && bf == -99 && bs == -22, msg);

    unsigned char un[16];
    for (int i = 0; i < 16; i++) un[i] = 0;
    long u1 = connect_(c1, un, 16), u2 = send_(c1, e, 16);
    snprintf(msg, sizeof msg, "U: connect(AF_UNSPEC) %ld, then send %ld (0 -89)", u1, u2);
    check(u1 == 0 && u2 == -89, msg);
    close_(c1); close_(c2); close_(rb);

    long d = dup_(r);
    close_(r);
    echo(e, 7);
    long ds = sendto_(d, e, 16, lo, 16);
    nap();
    long dn = rx(d);
    int okd = is36(dn, 8);
    drain(d);
    snprintf(msg, sizeof msg, "D: after closing the original, the dup %ld sends %ld and receives %ld (%d) (>=0 16 36 1)", d, ds, dn, okd);
    check(d >= 0 && ds == 16 && okd, msg);

    long m[8];
    int opened = 0, got = 0;
    for (int k = 0; k < 8; k++) { m[k] = rsock(); if (m[k] >= 0) opened++; }
    echo(e, 8);
    sendto_(d, e, 16, lo, 16);
    nap();
    for (int k = 0; k < 8; k++) { if (is36(rx(m[k]), 8)) got++; drain(m[k]); close_(m[k]); }
    drain(d);
    snprintf(msg, sizeof msg, "M: 8 more raw sockets opened %d, each got its own copy %d (8 8)", opened, got);
    check(opened == 8 && got == 8, msg);

    long u = usock();
    unsigned char p9[16];
    mk4(p9, 127, 0, 0, 1);
    p9[3] = 9;
    long ux = sendto_(u, "abc", 3, p9, 16);
    nap();
    long xn = rx(d);
    int xok = xn >= 56 && buf[9] == 1 && buf[20] == 3 && buf[21] == 3 && buf[28 + 9] == 17 && buf[50] == 0 && buf[51] == 9;
    drain(d);
    close_(u);
    snprintf(msg, sizeof msg, "X: a UDP datagram to 127.0.0.1:9 %ld shows up as port unreachable %ld quoting port 9 (%d) (3 >=56 1)", ux, xn, xok);
    check(ux == 3 && xok, msg);

    long cu = usock();
    long cuc = connect_(cu, p9, 16);
    long cun = name_(cu, a, 0);
    unsigned char im[36];
    for (int i = 0; i < 36; i++) im[i] = 0;
    im[0] = 3; im[1] = 3;
    unsigned char *ip = im + 8;
    ip[0] = 0x45; ip[3] = 28; ip[8] = 64; ip[9] = 17;
    ip[12] = 127; ip[15] = 1; ip[16] = 127; ip[19] = 1;
    unsigned short ic = csum(ip, 20);
    ip[10] = (unsigned char)(ic >> 8); ip[11] = (unsigned char)ic;
    im[28] = a[2]; im[29] = a[3]; im[31] = 9; im[33] = 8;
    unsigned short mc = csum(im, 36);
    im[2] = (unsigned char)(mc >> 8); im[3] = (unsigned char)mc;
    long iw = sendto_(d, im, 36, lo, 16);
    nap();
    long ie = getint(cu, SO_ERROR);
    drain(d);
    close_(cu);
    snprintf(msg, sizeof msg, "I: UDP connect %ld, name %ld; a port unreachable written by the raw socket %ld sets SO_ERROR %ld (0 16 36 111)", cuc, cun, iw, ie);
    check(cuc == 0 && cun == 16 && iw == 36 && ie == 111, msg);

    long l1 = listen_(d), l2 = accept_(d);
    snprintf(msg, sizeof msg, "L: listen %ld, accept %ld (-95 -95)", l1, l2);
    check(l1 == -95 && l2 == -95, msg);
    close_(d);

    print(failures ? "hello389: FAIL\n" : "hello389: PASS\n");
    return failures ? 1 : 0;
}
