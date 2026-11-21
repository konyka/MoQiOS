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
 *   K. a label lingers (at least 6 s) after its last holder closes: creating the EXCL label 0x22222 again right away is EPERM. */
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
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
    close_(s);
    close_(u);
    close_(v);
    close_(p);
    close_(rs);
    print(failures ? "hello484: FAIL\n" : "hello484: PASS\n");
    return failures ? 1 : 0;
}
