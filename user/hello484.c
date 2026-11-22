/* hello484: IPV6_FLOWLABEL_MGR (Linux net/ipv6/ip6_flowlabel.c). A socket leases flow labels from a system-wide table; GET creates
 * (IPV6_FL_F_CREATE) or joins one as its share mode allows, PUT gives it back, RENEW extends it. Once some label has a limiting share
 * mode, an IPv6 send or connect with IPV6_FLOWINFO_SEND may only use a label its socket holds. Measured on the host (build with
 * -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up; flowlabel_consistency 1, flowlabel_state_ranges 0):
 *   A. GET with CREATE and label 0 on a UDP socket returns 0 and writes a nonzero label (20 bits) back into flr_label;
 *   B. GET of 0x12345 without CREATE: ENOENT; with CREATE: 0; a second socket joins it (share ANY): 0; with F_EXCL: EEXIST;
 *   C. an EXCL label 0x22222 made by the second socket: the first may not join it (EPERM), nor 0x12345 with another share (EPERM);
 *   D. PUT or RENEW of a label the socket does not hold: ESRCH; RENEW of one it holds: 0;
 *   E. label 0x100000 (past 20 bits), action 7, an optlen of 31, the unspecified destination, share 9: all EINVAL;
 *   F. linger 151 s (past 150) without CAP_NET_ADMIN: EPERM (the test runs as uid 1000 here);
 *   G. with IPV6_FLOWINFO_SEND: a sendto whose sin6_flowinfo is a held label sends (1); an unheld label is EINVAL, the other
 *      socket's EXCL label too; after PUT the label is EINVAL as well;
 *   H. getsockopt(IPV6_FLOWLABEL_MGR) on a socket with no flow label: ENOENT; a socket connected with a label it holds and
 *      IPV6_FLOWINFO_SEND reads that label and share ANY back (optlen 32); a connect with an unheld label is EINVAL; getsockopt
 *      with action PUT is EINVAL;
 *   I. F_REFLECT on a UDP socket: EPERM (flowlabel_consistency); an IPv4 socket: ENOPROTOOPT;
 *   J. a child process may not join the parent's PROCESS label (EPERM); it may join its USER label (0);
 *   K. a label lingers (at least 6 s) after its last holder closes: creating the EXCL label 0x22222 again right away is EPERM;
 *   L. a raw ICMPv6 socket (rawv6_sendmsg) holding 0x11111: an IPV6_FLOWINFO control message with an unheld label is EINVAL, with
 *      the held one the echo request goes out (8); without IPV6_FLOWINFO_SEND sin6_flowinfo is ignored (8); with it an unheld label
 *      is EINVAL and the held one sends. (A ping socket does no such check: ping_v6_sendmsg has no fl6_sock_lookup.)
 *   M. TCP over IPv6 (tcp_v6_connect): with IPV6_FLOWINFO_SEND a connect whose sin6_flowinfo is an unheld label is EINVAL before
 *      the handshake starts; a socket holding the label connects to a listener on [::1] (0); without IPV6_FLOWINFO_SEND the
 *      label is not looked at (0);
 *   N. getsockopt with IPV6_FL_F_REMOTE reports the flow label last received (np->rcv_flowinfo): 0 on a UDP socket and on the
 *      connecting TCP socket; the accepted TCP socket reads the label of the SYN that made it (tcp_v6_syn_recv_sock); once the
 *      client sets IPV6_RECVFLOWINFO, data it receives in order updates its value to the label the server sends with.
 *   O. IPV6_2292PKTOPTIONS on that client reports the complete flowinfo: the server's non-ECN traffic-class bits and flow label,
 *      not only the low 20-bit label returned by IPV6_FL_F_REMOTE (TCP may mark the data ECT(1)).
 *   P. after every exclusive label is gone (six-second linger plus the deferred one-second static key), a send with an unheld
 *      label is allowed again. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long listen_(long s) { return rc(listen((int)s, 4)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long write_(long s, const void *b, long n) { return rc(write((int)s, b, (size_t)n)); }
static long read_(long s, void *b, long n) { return rc(read((int)s, b, (size_t)n)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long sendmsg_(long s, const void *m) { return rc(sendmsg((int)s, m, 0)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
static void close_(long s) { close((int)s); }
static long fork_(void) { return fork(); }
static int wait_(long c) { int st = 0; waitpid((pid_t)c, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 100; }
static long setuid_(long u) { return rc(setresuid((uid_t)u, (uid_t)u, (uid_t)u)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long listen_(long s) { return syscall2(119, s, 4); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long write_(long s, const void *b, long n) { return syscall3(1, s, (long)b, n); }
static long read_(long s, void *b, long n) { return syscall3(10, s, (long)b, n); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long sendmsg_(long s, const void *m) { return syscall3(129, s, (long)m, 0); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void close_(long s) { syscall1(11, s); }
static long fork_(void) { return syscall0(57); }
static int wait_(long c) { int st = 0; syscall3(6, c, (long)&st, 0); return (st & 0x7f) ? 100 : (st >> 8) & 0xff; }
static long setuid_(long u) { return syscall3(178, u, u, u); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello484:   ok   " : "hello484:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned int be32(unsigned int v) { return (v >> 24) | ((v >> 8) & 0xff00) | ((v << 8) & 0xff0000) | (v << 24); }
static unsigned short be16(unsigned short v) { return (unsigned short)((v >> 8) | (v << 8)); }
/* struct in6_flowlabel_req */
struct req { unsigned char dst[16]; unsigned int label; unsigned char action, share; unsigned short flags, expires, linger; unsigned int pad; };
static const unsigned char lo6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
static unsigned int got_label;
static long mgr_l(long s, int act, int share, int flags, unsigned int label, int linger, int optlen) {
    struct req q;
    memset(&q, 0, sizeof q);
    memcpy(q.dst, lo6, 16);
    q.label = be32(label);
    q.action = (unsigned char)act;
    q.share = (unsigned char)share;
    q.flags = (unsigned short)flags;
    q.linger = (unsigned short)linger;
    q.expires = (unsigned short)linger;
    long r = setopt_(s, 41, 32, &q, optlen);
    got_label = be32(q.label);
    return r;
}
static long mgr(long s, int act, int share, int flags, unsigned int label) { return mgr_l(s, act, share, flags, label, 6, 32); }
/* getsockopt(IPV6_FLOWLABEL_MGR) with action GET and IPV6_FL_F_REMOTE (8). */
static long remote_label(long s, unsigned int *label) {
    struct req q;
    memset(&q, 0, sizeof q);
    q.flags = 8;
    int l = sizeof q;
    long r = getopt_(s, 41, 32, &q, &l);
    *label = be32(q.label);
    return r;
}
struct sin6 { unsigned short fam, port; unsigned int flow; unsigned char addr[16]; unsigned int scope; };
static long send_flow(long s, unsigned int label) {
    struct sin6 a = { 10, be16(40484), be32(label), { 0 }, 0 };
    memcpy(a.addr, lo6, 16);
    return sendto_(s, "x", 1, &a, sizeof a);
}
int main(void) {
    print("hello484: IPV6_FLOWLABEL_MGR\n");
    int one = 1;
    long rs = sock(10, 2, 0);
    struct sin6 ra = { 10, be16(40484), 0, { 0 }, 0 };
    memcpy(ra.addr, lo6, 16);
    bind_(rs, &ra, sizeof ra);
    long s = sock(10, 2, 0), t = sock(10, 2, 0);
    long a = mgr(s, 0, 255, 1, 0);
    snprintf(msg, sizeof msg, "A: GET CREATE label 0: %ld, label 0x%x (0, nonzero, 20 bits)", a, got_label);
    check(a == 0 && got_label != 0 && (got_label & ~0xfffffu) == 0, msg);

    long b1 = mgr(s, 0, 255, 0, 0x12345), b2 = mgr(s, 0, 255, 1, 0x12345), b3 = mgr(t, 0, 255, 0, 0x12345), b4 = mgr(t, 0, 255, 2, 0x12345);
    snprintf(msg, sizeof msg, "B: no CREATE %ld, CREATE %ld, other joins %ld, with F_EXCL %ld (-2 0 0 -17)", b1, b2, b3, b4);
    check(b1 == -2 && b2 == 0 && b3 == 0 && b4 == -17, msg);

    long c1 = mgr(t, 0, 1, 1, 0x22222), c2 = mgr(s, 0, 1, 0, 0x22222), c3 = mgr(s, 0, 3, 0, 0x12345);
    snprintf(msg, sizeof msg, "C: EXCL create %ld, join it %ld, join ANY label as USER %ld (0 -1 -1)", c1, c2, c3);
    check(c1 == 0 && c2 == -1 && c3 == -1, msg);

    long d1 = mgr(s, 1, 0, 0, 0x99999), d2 = mgr(s, 2, 0, 0, 0x99999), d3 = mgr(s, 2, 0, 0, 0x12345);
    snprintf(msg, sizeof msg, "D: PUT unheld %ld, RENEW unheld %ld, RENEW held %ld (-3 -3 0)", d1, d2, d3);
    check(d1 == -3 && d2 == -3 && d3 == 0, msg);

    struct req z;
    memset(&z, 0, sizeof z);
    z.share = 255;
    z.flags = 1;
    z.linger = 6;
    z.expires = 6;
    long e1 = mgr(s, 0, 255, 1, 0x100000), e2 = mgr(s, 7, 0, 0, 0), e3 = mgr_l(s, 0, 255, 1, 0x33333, 6, 31), e4 = setopt_(s, 41, 32, &z, 32), e5 = mgr(s, 0, 9, 1, 0x33333);
    snprintf(msg, sizeof msg, "E: 21-bit label %ld, action 7 %ld, optlen 31 %ld, unspecified dst %ld, share 9 %ld (all -22)", e1, e2, e3, e4, e5);
    check(e1 == -22 && e2 == -22 && e3 == -22 && e4 == -22 && e5 == -22, msg);

    long cf = fork_();
    if (cf == 0) {
        if (setuid_(1000) != 0) _exit(9);
        long u = sock(10, 2, 0);
        _exit(mgr_l(u, 0, 255, 1, 0x45444, 151, 32) == -1 ? 0 : 1);
    }
    int fst = wait_(cf);
    snprintf(msg, sizeof msg, "F: linger 151 as uid 1000: child exit %d (0: EPERM)", fst);
    check(fst == 0, msg);

    setopt_(s, 41, 33, &one, 4);
    long g1 = send_flow(s, 0x12345), g2 = send_flow(s, 0x54321), g3 = send_flow(s, 0x22222);
    long g4 = mgr(s, 1, 0, 0, 0x12345), g5 = send_flow(s, 0x12345);
    snprintf(msg, sizeof msg, "G: send held %ld, unheld %ld, other's EXCL %ld, PUT %ld, send after PUT %ld (1 -22 -22 0 -22)", g1, g2, g3, g4, g5);
    check(g1 == 1 && g2 == -22 && g3 == -22 && g4 == 0 && g5 == -22, msg);

    struct req q;
    int ql = sizeof q;
    memset(&q, 0, sizeof q);
    long h1 = getopt_(s, 41, 32, &q, &ql);
    long u = sock(10, 2, 0);
    mgr(u, 0, 255, 1, 0);
    unsigned int ul = got_label;
    setopt_(u, 41, 33, &one, 4);
    struct sin6 ca = { 10, be16(40484), be32(ul), { 0 }, 0 };
    memcpy(ca.addr, lo6, 16);
    long h2 = connect_(u, &ca, sizeof ca);
    memset(&q, 0, sizeof q);
    ql = sizeof q;
    long h3 = getopt_(u, 41, 32, &q, &ql);
    long v = sock(10, 2, 0);
    setopt_(v, 41, 33, &one, 4);
    ca.flow = be32(0x66666);
    long h4 = connect_(v, &ca, sizeof ca);
    memset(&q, 0, sizeof q);
    q.action = 1;
    ql = sizeof q;
    long h5 = getopt_(u, 41, 32, &q, &ql);
    memset(&q, 0, sizeof q);
    ql = sizeof q;
    getopt_(u, 41, 32, &q, &ql);
    snprintf(msg, sizeof msg, "H: get unset %ld; connect %ld, get %ld label %d share %d optlen %d; connect unheld %ld; get with PUT %ld (-2 0 0 1 255 32 -22 -22)", h1, h2, h3,
             be32(q.label) == ul, q.share, ql, h4, h5);
    check(h1 == -2 && h2 == 0 && h3 == 0 && be32(q.label) == ul && q.share == 255 && ql == 32 && h4 == -22 && h5 == -22, msg);

    long i1 = mgr(s, 0, 0, 4, 0), v4 = sock(2, 2, 0), i2 = mgr(v4, 0, 255, 1, 0x77777);
    snprintf(msg, sizeof msg, "I: F_REFLECT on UDP %ld, IPv4 socket %ld (-1 -92)", i1, i2);
    check(i1 == -1 && i2 == -92, msg);

    long p = sock(10, 2, 0);
    long j1 = mgr(p, 0, 2, 1, 0x7a7a7), j2 = mgr(p, 0, 3, 1, 0x8a8a8);
    long cj = fork_();
    if (cj == 0) {
        long w = sock(10, 2, 0);
        long r1 = mgr(w, 0, 2, 0, 0x7a7a7), r2 = mgr(w, 0, 3, 0, 0x8a8a8);
        _exit((r1 == -1 ? 0 : 1) | (r2 == 0 ? 0 : 2));
    }
    int jst = wait_(cj);
    snprintf(msg, sizeof msg, "J: PROCESS %ld, USER %ld; child exit %d (0 0 0: PROCESS EPERM, USER joined)", j1, j2, jst);
    check(j1 == 0 && j2 == 0 && jst == 0, msg);

    close_(t);
    long k1 = mgr(s, 0, 1, 1, 0x22222);
    snprintf(msg, sizeof msg, "K: EXCL 0x22222 again while it lingers after its holder closed %ld (-1)", k1);
    check(k1 == -1, msg);
    /* L: raw ICMPv6. */
    long raw = sock(10, 3, 58);
    long l0 = mgr(raw, 0, 255, 1, 0x11111);
    struct sin6 da = { 10, 0, 0, { 0 }, 0 };
    memcpy(da.addr, lo6, 16);
    unsigned char echo[8] = { 128, 0, 0, 0, 0, 1, 0, 1 };
    long rl[6];
    for (int k = 0; k < 2; k++) {
        unsigned char mh[56], ctl[24];
        memset(mh, 0, sizeof mh);
        memset(ctl, 0, sizeof ctl);
        long clen = 20, lvl = 41;
        int ty = 11;
        unsigned int fl = be32(k ? 0x11111 : 0x54321);
        memcpy(ctl, &clen, 8); memcpy(ctl + 8, &lvl, 4); memcpy(ctl + 12, &ty, 4); memcpy(ctl + 16, &fl, 4);
        long iov[2] = { (long)echo, 8 };
        long np_ = (long)&da, nl = sizeof da, ip = (long)iov, one_ = 1, cp = (long)ctl, cl = 24;
        memcpy(mh, &np_, 8); memcpy(mh + 8, &nl, 4); memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one_, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
        rl[k] = sendmsg_(raw, mh);
    }
    da.flow = be32(0x54321);
    rl[2] = sendto_(raw, echo, 8, &da, sizeof da);
    setopt_(raw, 41, 33, &one, 4);
    rl[3] = sendto_(raw, echo, 8, &da, sizeof da);
    da.flow = be32(0x11111);
    rl[4] = sendto_(raw, echo, 8, &da, sizeof da);
    snprintf(msg, sizeof msg, "L: raw GET %ld; cmsg unheld %ld held %ld; addr label without SNDFLOW %ld; with SNDFLOW unheld %ld held %ld (0 -22 8 8 -22 8)", l0, rl[0], rl[1], rl[2], rl[3], rl[4]);
    check(l0 == 0 && rl[0] == -22 && rl[1] == 8 && rl[2] == 8 && rl[3] == -22 && rl[4] == 8, msg);
    close_(raw);
    /* M: TCP. */
    long ls = sock(10, 1, 0);
    setopt_(ls, 1, 2, &one, 4);
    struct sin6 la = { 10, be16(40487), 0, { 0 }, 0 };
    memcpy(la.addr, lo6, 16);
    long m0 = bind_(ls, &la, sizeof la);
    long m1 = listen_(ls);
    long ta = sock(10, 1, 0), tb = sock(10, 1, 0), tc = sock(10, 1, 0);
    setopt_(ta, 41, 33, &one, 4);
    setopt_(tb, 41, 33, &one, 4);
    long m2 = mgr(tb, 0, 255, 1, 0x13131);
    la.flow = be32(0x13131);
    long m3 = connect_(ta, &la, sizeof la), m4 = connect_(tb, &la, sizeof la), m5 = connect_(tc, &la, sizeof la);
    snprintf(msg, sizeof msg, "M: tcp bind %ld listen %ld GET %ld; connect unheld %ld, held %ld, without SNDFLOW %ld (0 0 0 -22 0 0)", m0, m1, m2, m3, m4, m5);
    check(m0 == 0 && m1 == 0 && m2 == 0 && m3 == -22 && m4 == 0 && m5 == 0, msg);
    long ac = accept_(ls);
    unsigned int n0 = 1, n1 = 1, n2 = 1, n3 = 1;
    long r0 = remote_label(u, &n0), r1 = remote_label(ac, &n1), r2 = remote_label(tb, &n2);
    int rfl = 1;
    setopt_(tb, 41, 11, &rfl, 4);
    setopt_(tb, 41, 66, &rfl, 4);
    int tc6 = 0xa8;
    setopt_(ac, 41, 67, &tc6, 4);
    long ws = write_(ac, "q", 1);
    char nb[4];
    long rd = read_(tb, nb, 4);
    long r3 = remote_label(tb, &n3);
    snprintf(msg, sizeof msg, "N: REMOTE udp %ld 0x%x, accepted %ld 0x%x, client %ld 0x%x; write %ld read %ld, client after RECVFLOWINFO %ld nonzero %d (0 0 0 0x13131 0 0 1 1 0 1)", r0, n0, r1, n1, r2, n2, ws, rd, r3, n3 != 0);
    check(r0 == 0 && n0 == 0 && r1 == 0 && n1 == 0x13131 && r2 == 0 && n2 == 0 && ws == 1 && rd == 1 && r3 == 0 && n3 != 0 && (n3 & ~0xfffffu) == 0, msg);
    unsigned char po[48];
    memset(po, 0xa5, sizeof po);
    int pol = sizeof po;
    long por = getopt_(tb, 41, 6, po, &pol);
    unsigned int oflow = 0x0a800000u | n3;
    unsigned int actual_flow = ((unsigned int)po[40] << 24) | ((unsigned int)po[41] << 16) | ((unsigned int)po[42] << 8) | po[43];
    // TCP may mark data ECT(1); compare the other six traffic-class bits and the label, not ECN.
    int flow_ok = (actual_flow & ~0x00300000u) == oflow;
    snprintf(msg, sizeof msg, "O: PKTOPTIONS r %ld len %d, TCLASS %d, FLOWINFO bytes %02x %02x %02x %02x (0 48 168 & 252, %02x %02x %02x %02x without ECN)",
             por, pol, po[16], po[40], po[41], po[42], po[43], oflow >> 24, (oflow >> 16) & 255, (oflow >> 8) & 255, oflow & 255);
    check(por == 0 && pol == 48 && po[12] == 67 && (po[16] & 0xfc) == 0xa8 && po[17] == 0 && po[36] == 11 && flow_ok, msg);
    close_(ac);
    close_(ta);
    close_(tb);
    close_(tc);
    close_(ls);
    close_(s);
    close_(u);
    close_(v);
    close_(p);
    close_(rs);
    long prs = sock(10, 2, 0);
    long prb = bind_(prs, &ra, sizeof ra);
    long ps = sock(10, 2, 0);
    setopt_(ps, 41, 33, &one, 4);
    sleep(8);
    long p1 = send_flow(ps, 0x5a5a5);
    snprintf(msg, sizeof msg, "P: after the last exclusive label expired and its deferred key turned off, unheld send: bind %ld send %ld (0 1)", prb, p1);
    check(prb == 0 && p1 == 1, msg);
    close_(ps);
    close_(prs);
    print(failures ? "hello484: FAIL\n" : "hello484: PASS\n");
    return failures ? 1 : 0;
}
