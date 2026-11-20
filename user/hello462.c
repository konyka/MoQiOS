/* hello462: IPv6 flow labels on UDP (Linux ip6_datagram_send_ctl IPV6_FLOWINFO, udpv6_sendmsg with np->sndflow, ip6_make_flowlabel,
 * ip6_datagram_recv_specific_ctl rxflow). The receiver turns on IPV6_FLOWINFO (SOL_IPV6 11) and reads the label of each datagram
 * from its control message. Measured on the host (build with -DHOST, run in `unshare -n` with lo up and the default
 * net.ipv6.auto_flowlabels = 1):
 *   A. setsockopt(IPV6_FLOWINFO, 1) on the receiver: 0, getsockopt reads 1; a sender with IPV6_AUTOFLOWLABEL 0 sends a datagram with
 *      no label, which brings no IPV6_FLOWINFO message (its flowinfo is 0);
 *   B. sendmsg with an IPV6_FLOWINFO control message 0x000abcde: the receiver sees flowinfo 0x000abcde;
 *   C. sin6_flowinfo 0x54321 without IPV6_FLOWINFO_SEND: no label; with IPV6_FLOWINFO_SEND (33) set (getsockopt reads 1): label
 *      0x54321; a sin6_flowinfo with traffic-class bits (0x12354321) still gives label 0x54321;
 *   D. IPV6_FLOWINFO_SEND set and a control message: the control message's label wins;
 *   E. automatic labels: IPV6_AUTOFLOWLABEL reads 1 on a new socket; its plain datagrams carry a non-zero label, the same for two
 *      sends of one flow; another socket (another source port) gets another label; IPV6_AUTOFLOWLABEL 0 turns it off (label 0),
 *      1 back on (the same label as before);
 *   F. raw and ping ICMPv6 sockets: a raw ICMPV6 socket sees its own echo request (loopback) with a non-zero automatic label that
 *      repeats on the next request; an IPV6_FLOWINFO control message 0x12345 on a sendmsg gives that label; the IPv6 header is read
 *      back through a raw IPPROTO_ICMPV6 socket's IPV6_FLOWINFO control message on receive. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getint(long s, int lv, int o) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, lv, o, &v, &l)); return r < 0 ? r : v; }
static long sendmsg_(long s, void *m, int f) { return rc(sendmsg((int)s, m, f)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static void nap(void) { usleep(20000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getint(long s, int lv, int o) { int v = -1; int l = 4; long r = syscall5(133, s, lv, o, (long)&v, (long)&l); return r < 0 ? r : v; }
static long sendmsg_(long s, void *m, int f) { return syscall3(129, s, (long)m, f); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello462:   ok   " : "hello462:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rcv;
/* The flowinfo the receiver's next datagram carries in its IPV6_FLOWINFO message (host order), 0 without one, -1 with nothing. */
static long next_flow(void) {
    nap();
    static unsigned char ctl[128];
    char d[8];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    memset(ctl, 0, sizeof ctl);
    long iov[2] = { (long)d, 8 };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    long r = recvmsg_(rcv, mh, 0x40);
    if (r < 0) return -1;
    long used;
    memcpy(&used, mh + 40, 8);
    for (long off = 0; off + 16 <= used;) {
        long len;
        int lv, ty;
        memcpy(&len, ctl + off, 8); memcpy(&lv, ctl + off + 8, 4); memcpy(&ty, ctl + off + 12, 4);
        if (lv == 41 && ty == 11) return (long)ctl[off + 16] << 24 | ctl[off + 17] << 16 | ctl[off + 18] << 8 | ctl[off + 19];
        if (len < 16) break;
        off += (len + 7) & ~7L;
    }
    return 0;
}
/* sendmsg of "x" to `a` with an IPV6_FLOWINFO control message carrying `flow` (written big-endian). */
static long send_flow(long s, unsigned char *a, unsigned int flow) {
    unsigned char ctl[24];
    memset(ctl, 0, sizeof ctl);
    long len = 20;
    int lv = 41, ty = 11;
    memcpy(ctl, &len, 8); memcpy(ctl + 8, &lv, 4); memcpy(ctl + 12, &ty, 4);
    ctl[16] = (unsigned char)(flow >> 24); ctl[17] = (unsigned char)(flow >> 16); ctl[18] = (unsigned char)(flow >> 8); ctl[19] = (unsigned char)flow;
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    char d = 'x';
    long iov[2] = { (long)&d, 1 };
    long np = (long)a, nl = 28, ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh, &np, 8); memcpy(mh + 8, &nl, 4); memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    return sendmsg_(s, mh, 0);
}
static void set_flowinfo(unsigned char *a, unsigned int f) {
    a[4] = (unsigned char)(f >> 24); a[5] = (unsigned char)(f >> 16); a[6] = (unsigned char)(f >> 8); a[7] = (unsigned char)f;
}
int main(void) {
    print("hello462: IPv6 flow labels\n");
    unsigned char a[28];
    memset(a, 0, 28);
    a[0] = 10; a[2] = 4620 >> 8; a[3] = 4620 & 0xff; a[23] = 1;
    rcv = sock(10, 2, 0);
    bind_(rcv, a, 28);
    long u = sock(10, 2, 0);
    int one = 1;

    int zero = 0;
    setopt_(u, 41, 70, &zero, 4);
    long so = setopt_(rcv, 41, 11, &one, 4);
    long g = getint(rcv, 41, 11);
    sendto_(u, "x", 1, a, 28);
    long a1 = next_flow();
    snprintf(msg, sizeof msg, "A: IPV6_FLOWINFO set %ld get %ld; a plain datagram's flowinfo %lx (0 1 0)", so, g, a1);
    check(so == 0 && g == 1 && a1 == 0, msg);

    long b1 = send_flow(u, a, 0x000abcde);
    long b2 = next_flow();
    snprintf(msg, sizeof msg, "B: control message 0xabcde: send %ld, received flowinfo %lx (1 abcde)", b1, b2);
    check(b1 == 1 && b2 == 0xabcde, msg);

    set_flowinfo(a, 0x54321);
    sendto_(u, "x", 1, a, 28);
    long c1 = next_flow();
    long cs = setopt_(u, 41, 33, &one, 4);
    long cg = getint(u, 41, 33);
    sendto_(u, "x", 1, a, 28);
    long c2 = next_flow();
    set_flowinfo(a, 0x12354321);
    sendto_(u, "x", 1, a, 28);
    long c3 = next_flow();
    snprintf(msg, sizeof msg, "C: sin6_flowinfo without IPV6_FLOWINFO_SEND %lx; set %ld get %ld; with it %lx; with tclass bits %lx (0 0 1 54321 54321)", c1, cs, cg, c2, c3);
    check(c1 == 0 && cs == 0 && cg == 1 && c2 == 0x54321 && (c3 & 0xFFFFF) == 0x54321, msg);

    set_flowinfo(a, 0x54321);
    send_flow(u, a, 0x000fedcb);
    long d1 = next_flow();
    snprintf(msg, sizeof msg, "D: IPV6_FLOWINFO_SEND and a control message 0xfedcb: %lx (fedcb)", d1);
    check(d1 == 0xfedcb, msg);

    memset(a + 4, 0, 4);
    long e = sock(10, 2, 0), e2 = sock(10, 2, 0);
    long eg = getint(e, 41, 70);
    sendto_(e, "x", 1, a, 28);
    long e1 = next_flow();
    sendto_(e, "x", 1, a, 28);
    long e1b = next_flow();
    sendto_(e2, "x", 1, a, 28);
    long e3 = next_flow();
    setopt_(e, 41, 70, &zero, 4);
    long eoff = getint(e, 41, 70);
    sendto_(e, "x", 1, a, 28);
    long e4 = next_flow();
    setopt_(e, 41, 70, &one, 4);
    sendto_(e, "x", 1, a, 28);
    long e5 = next_flow();
    snprintf(msg, sizeof msg, "E: IPV6_AUTOFLOWLABEL %ld; label %lx then %lx; another socket %lx; off (%ld) %lx; on again %lx (1; x x; y; 0 0; x)", eg, e1, e1b, e3, eoff, e4, e5);
    check(eg == 1 && e1 > 0 && e1 <= 0xFFFFF && e1b == e1 && e3 > 0 && e3 != e1 && eoff == 0 && e4 == 0 && e5 == e1, msg);

    /* F: a raw ICMPv6 socket reads the flowinfo of the echo requests it sends to ::1 (each is looped back to it). */
    long rawf = sock(10, 3, 58);
    setopt_(rawf, 41, 11, &one, 4);
    unsigned char ra[28];
    memcpy(ra, a, 28);
    ra[2] = 0; ra[3] = 0;
    unsigned char echo[16] = { 128, 0 };
    long saved_rcv = rcv;
    rcv = rawf;
    sendto_(rawf, echo, 16, ra, 28);
    long f1 = next_flow();
    while (next_flow() >= 0) {}
    sendto_(rawf, echo, 16, ra, 28);
    long f2 = next_flow();
    while (next_flow() >= 0) {}
    unsigned char ctl[24];
    memset(ctl, 0, sizeof ctl);
    long clen = 20;
    int lv = 41, ty = 11;
    memcpy(ctl, &clen, 8); memcpy(ctl + 8, &lv, 4); memcpy(ctl + 12, &ty, 4);
    ctl[17] = 0x01; ctl[18] = 0x23; ctl[19] = 0x45;
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    long iov[2] = { (long)echo, 16 };
    long np = (long)ra, nl = 28, ip = (long)iov, onel = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh, &np, 8); memcpy(mh + 8, &nl, 4); memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &onel, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    long fs = sendmsg_(rawf, mh, 0);
    long f3 = next_flow();
    rcv = saved_rcv;
    snprintf(msg, sizeof msg, "F: raw ICMPv6 automatic label %lx then %lx; control message 0x12345: send %ld, label %lx (x x; 16 12345)", f1, f2, fs, f3);
    check(rawf >= 0 && f1 > 0 && f1 == f2 && fs == 16 && f3 == 0x12345, msg);

    print(failures ? "hello462: FAIL\n" : "hello462: PASS\n");
    return failures ? 1 : 0;
}
