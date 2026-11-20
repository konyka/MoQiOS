/* hello461: IPV6_DONTFRAG (Linux do_ipv6_setsockopt, ip6_datagram_send_ctl, __ip6_append_data: with dontfrag set a datagram over
 * the path MTU is EMSGSIZE instead of being fragmented). Measured on the host (build with -DHOST, run in `unshare -n` with lo up and
 * its MTU set to 1500):
 *   A. setsockopt(SOL_IPV6, IPV6_DONTFRAG, 1) on a UDP socket: 0, getsockopt reads 1; then a 3000-byte send to [::1] is EMSGSIZE;
 *      with IPV6_RECVERR on as well the refusal is queued: MSG_ERRQUEUE returns 0 with ee_errno 90, ee_origin 1 (local) and ee_info
 *      the path MTU (1500 here; an earlier test in the boot run may have lowered the path MTU to ::1, so only "at most 1500" is
 *      checked); a 1232-byte datagram (it fits the IPv6 minimum MTU of 1280) is sent;
 *   B. back to 0: 3000 bytes are sent (fragmented); a value of 2 reads back 1; a 2-byte optval sets 0;
 *   C. sendmsg with an IPV6_DONTFRAG 1 control message on a socket without the option: 3000 bytes EMSGSIZE; with 0: sent;
 *   D. a raw ICMPv6 socket with IPV6_DONTFRAG: a 3000-byte echo request is EMSGSIZE; with IPV6_RECVERR the refusal is queued too
 *      (ee_errno 90, ee_info the path MTU, at most 1500);
 *   E. an IPv4 UDP socket: SOL_IPV6 IPV6_DONTFRAG is ENOPROTOOPT; a TCP IPv6 socket takes it (0);
 *   F. an IPv6 ping socket (net.ipv4.ping_group_range opened to group 0 for the test) with IPV6_DONTFRAG and IPV6_RECVERR: a 3000-byte
 *      echo request is EMSGSIZE and the error queue holds ee_errno 90, ee_origin 1;
 *   G. IPV6_RECVPATHMTU on a UDP socket with IPV6_DONTFRAG: set 0, getsockopt reads 1; after a refused 3000-byte send, recvmsg
 *      returns 0 bytes with msg_name [::1] port 0 and one 48-byte control message, SOL_IPV6 / IPV6_PATHMTU, holding a sockaddr_in6
 *      of ::1 and the MTU (at most 1500); the next recvmsg is EAGAIN; two refused sends leave only one notice;
 *   H. getsockopt(IPV6_PATHMTU): unconnected ENOTCONN; connected to [::1] it gives 32 bytes, the address left zero and the MTU (at
 *      most 1500); an optlen of 8 is EINVAL; an unconnected TCP socket ENOTCONN;
 *   I. IPV6_PATHMTU on TCP: a connected client and the accepted socket give the MTU, the listener ENOTCONN; a raw ICMPv6 socket is
 *      ENOTCONN until it connects to [::1], then gives the MTU;
 *   J. a raw ICMPv6 socket with IPV6_DONTFRAG and IPV6_RECVPATHMTU: after a refused 3000-byte send, recvmsg returns 0 with one
 *      48-byte IPV6_PATHMTU control message. */
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
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getint(long s, int lv, int o) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, lv, o, &v, &l)); return r < 0 ? r : v; }
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long listen_(long s) { return rc(listen((int)s, 4)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long sendmsg_(long s, void *m, int f) { return rc(sendmsg((int)s, m, f)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long io_(long fd, char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getint(long s, int lv, int o) { int v = -1; int l = 4; long r = syscall5(133, s, lv, o, (long)&v, (long)&l); return r < 0 ? r : v; }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long listen_(long s) { return syscall2(119, s, 4); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long sendmsg_(long s, void *m, int f) { return syscall3(129, s, (long)m, f); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr ? 1 : 0, 0); }
static long io_(long fd, char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello461:   ok   " : "hello461:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char out[3000];
static unsigned char in[3100];
/* struct msghdr (56 bytes) with one iovec of `n` bytes from `out`, the name `a` (28 bytes) and `ctl` as control. */
static unsigned char mh[56];
static long iov[2];
static void msghdr_(unsigned char *a, unsigned char *ctl, long ctl_len, long n) {
    memset(mh, 0, sizeof mh);
    iov[0] = (long)out; iov[1] = n;
    long p = (long)a, nl = 28, ip = (long)iov, one = 1, cp = (long)ctl;
    memcpy(mh, &p, 8); memcpy(mh + 8, &nl, 4); memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &ctl_len, 8);
}
/* One cmsghdr: len 20 (16 + an int), SOL_IPV6, IPV6_DONTFRAG, value `v`; padded to 24. */
static unsigned char ctl[24];
static void dontfrag_cmsg(int v) {
    memset(ctl, 0, sizeof ctl);
    long len = 20;
    int lv = 41, ty = 62;
    memcpy(ctl, &len, 8); memcpy(ctl + 8, &lv, 4); memcpy(ctl + 12, &ty, 4); memcpy(ctl + 16, &v, 4);
}
int main(void) {
    print("hello461: IPV6_DONTFRAG\n");
    unsigned char a[28];
    memset(a, 0, 28);
    a[0] = 10; a[2] = 4610 >> 8; a[3] = 4610 & 0xff; a[23] = 1;
    long r = sock(10, 2, 0);
    bind_(r, a, 28);
    long u = sock(10, 2, 0);
    int one = 1, zero = 0, two = 2;

    long so = setopt_(u, 41, 62, &one, 4);
    long g = getint(u, 41, 62);
    long a1 = sendto_(u, out, 3000, a, 28);
    setopt_(u, 41, 25, &one, 4);
    long a3 = sendto_(u, out, 3000, a, 28);
    unsigned char eh[56];
    memset(eh, 0, sizeof eh);
    long eiov[2] = { (long)in, 16 };
    long eip = (long)eiov, eone = 1;
    memcpy(eh + 16, &eip, 8); memcpy(eh + 24, &eone, 8);
    static unsigned char ec[128];
    long ecp = (long)ec, ecl = sizeof ec;
    memcpy(eh + 32, &ecp, 8); memcpy(eh + 40, &ecl, 8);
    long aq = recvmsg_(u, eh, 0x2000 | 0x40);
    unsigned int ee_errno, ee_info;
    memcpy(&ee_errno, ec + 16, 4);
    memcpy(&ee_info, ec + 16 + 8, 4);
    unsigned char ee_origin = ec[16 + 4];
    setopt_(u, 41, 25, &zero, 4);
    long a2 = sendto_(u, out, 1232, a, 28);
    while (recv_(r, in, sizeof in) >= 0) {}
    snprintf(msg, sizeof msg, "A: set %ld get %ld; 3000 %ld; with IPV6_RECVERR 3000 %ld, error queue %ld errno %u origin %u info %u; 1232 %ld (0 1; -90; -90 0 90 1 <=1500; 1232)", so, g,
             a1, a3, aq, ee_errno, ee_origin, ee_info, a2);
    check(so == 0 && g == 1 && a1 == -90 && a3 == -90 && aq == 0 && ee_errno == 90 && ee_origin == 1 && ee_info >= 1280 && ee_info <= 1500 && a2 == 1232, msg);

    setopt_(u, 41, 62, &zero, 4);
    long b1 = sendto_(u, out, 3000, a, 28);
    long b2 = recv_(r, in, sizeof in);
    setopt_(u, 41, 62, &two, 4);
    long b3 = getint(u, 41, 62);
    long b4 = setopt_(u, 41, 62, &one, 2);
    long b5 = getint(u, 41, 62);
    snprintf(msg, sizeof msg, "B: off: 3000 %ld, received %ld; set 2 reads %ld; a 2-byte value %ld reads %ld (3000 3000 1 0 0)", b1, b2, b3, b4, b5);
    check(b1 == 3000 && b2 == 3000 && b3 == 1 && b4 == 0 && b5 == 0, msg);

    long u2 = sock(10, 2, 0);
    dontfrag_cmsg(1);
    msghdr_(a, ctl, 24, 3000);
    long c1 = sendmsg_(u2, mh, 0);
    dontfrag_cmsg(0);
    msghdr_(a, ctl, 24, 3000);
    long c2 = sendmsg_(u2, mh, 0);
    long c3 = recv_(r, in, sizeof in);
    snprintf(msg, sizeof msg, "C: control message 1: %ld; 0: %ld, received %ld (-90 3000 3000)", c1, c2, c3);
    check(c1 == -90 && c2 == 3000 && c3 == 3000, msg);

    long raw = sock(10, 3, 58);
    setopt_(raw, 41, 62, &one, 4);
    memset(out, 0, 8);
    out[0] = 128;
    unsigned char b[28];
    memcpy(b, a, 28);
    b[2] = 0; b[3] = 0;
    long d1 = sendto_(raw, out, 3000, b, 28);
    setopt_(raw, 41, 25, &one, 4);
    long d2 = sendto_(raw, out, 3000, b, 28);
    memset(ec, 0, sizeof ec);
    memcpy(eh + 32, &ecp, 8); memcpy(eh + 40, &ecl, 8);
    long dq = recvmsg_(raw, eh, 0x2000 | 0x40);
    unsigned int de, di;
    memcpy(&de, ec + 16, 4);
    memcpy(&di, ec + 16 + 8, 4);
    snprintf(msg, sizeof msg, "D: raw ICMPv6 with IPV6_DONTFRAG, 3000 bytes: %ld; with IPV6_RECVERR %ld, error queue %ld errno %u info %u (-90 -90 0 90 <=1500)", d1, d2, dq, de, di);
    check(raw >= 0 && d1 == -90 && d2 == -90 && dq == 0 && de == 90 && di >= 1280 && di <= 1500, msg);

    long v4 = sock(2, 2, 0), t6 = sock(10, 1, 0);
    long e1 = setopt_(v4, 41, 62, &one, 4), e2 = setopt_(t6, 41, 62, &one, 4);
    snprintf(msg, sizeof msg, "E: IPv4 UDP %ld; IPv6 TCP %ld (-92 0)", e1, e2);
    check(e1 == -92 && e2 == 0, msg);

    char saved[48];
    long rf = open_("/proc/sys/net/ipv4/ping_group_range", 0);
    long rn = rf >= 0 ? io_(rf, saved, sizeof saved - 1, 0) : -1;
    if (rf >= 0) close_(rf);
    long wf = open_("/proc/sys/net/ipv4/ping_group_range", 1);
    char zz[] = "0 0";
    if (wf >= 0) { io_(wf, zz, 3, 1); close_(wf); }
    long p = sock(10, 2, 58);
    setopt_(p, 41, 62, &one, 4);
    setopt_(p, 41, 25, &one, 4);
    long f1 = sendto_(p, out, 3000, b, 28);
    memset(ec, 0, sizeof ec);
    memcpy(eh + 32, &ecp, 8); memcpy(eh + 40, &ecl, 8);
    long fq = recvmsg_(p, eh, 0x2000 | 0x40);
    unsigned int fe;
    memcpy(&fe, ec + 16, 4);
    unsigned char fo = ec[16 + 4];
    if (rn > 0) {
        int k = 0;
        while (k < rn && saved[k] != '\n') k++;
        wf = open_("/proc/sys/net/ipv4/ping_group_range", 1);
        if (wf >= 0) { io_(wf, saved, k, 1); close_(wf); }
    }
    snprintf(msg, sizeof msg, "F: ping socket %d; 3000 bytes %ld; error queue %ld errno %u origin %u (1 -90 0 90 1)", p >= 0, f1, fq, fe, fo);
    check(p >= 0 && f1 == -90 && fq == 0 && fe == 90 && fo == 1, msg);

    long gs = sock(10, 2, 0);
    setopt_(gs, 41, 62, &one, 4);
    long g1 = setopt_(gs, 41, 60, &one, 4);
    long g2 = getint(gs, 41, 60);
    sendto_(gs, out, 3000, a, 28);
    static unsigned char gname[28], gctl[128];
    memset(gname, 0x55, sizeof gname);
    memset(gctl, 0, sizeof gctl);
    unsigned char gh[56];
    memset(gh, 0, sizeof gh);
    long gnp = (long)gname, gnl = 28, gcp = (long)gctl, gcl = sizeof gctl;
    long giov[2] = { (long)in, 16 };
    long gip = (long)giov, gone = 1;
    memcpy(gh, &gnp, 8); memcpy(gh + 8, &gnl, 4); memcpy(gh + 16, &gip, 8); memcpy(gh + 24, &gone, 8); memcpy(gh + 32, &gcp, 8); memcpy(gh + 40, &gcl, 8);
    long gr = recvmsg_(gs, gh, 0x40);
    long gclen; memcpy(&gclen, gh + 40, 8);
    long cml; memcpy(&cml, gctl, 8);
    int cmlv, cmty; memcpy(&cmlv, gctl + 8, 4); memcpy(&cmty, gctl + 12, 4);
    unsigned int gmtu; memcpy(&gmtu, gctl + 16 + 28, 4);
    int addr_ok = gctl[16] == 10 && gctl[16 + 23] == 1 && gname[0] == 10 && gname[2] == 0 && gname[3] == 0 && gname[23] == 1;
    memcpy(gh + 40, &gcl, 8);
    long gr2 = recvmsg_(gs, gh, 0x40);
    sendto_(gs, out, 3000, a, 28);
    sendto_(gs, out, 3000, a, 28);
    memcpy(gh + 40, &gcl, 8);
    long gr3 = recvmsg_(gs, gh, 0x40);
    memcpy(gh + 40, &gcl, 8);
    long gr4 = recvmsg_(gs, gh, 0x40);
    snprintf(msg, sizeof msg, "G: set %ld get %ld; recvmsg %ld controllen %ld cmsg len %ld %d/%d mtu %u addr %d; again %ld; after two refusals %ld then %ld (0 1; 0 48 48 41/61 <=1500 1; -11; 0 -11)",
             g1, g2, gr, gclen, cml, cmlv, cmty, gmtu, addr_ok, gr2, gr3, gr4);
    check(g1 == 0 && g2 == 1 && gr == 0 && gclen == 48 && cml == 48 && cmlv == 41 && cmty == 61 && gmtu >= 1280 && gmtu <= 1500 && addr_ok && gr2 == -11 && gr3 == 0 && gr4 == -11, msg);

    long hs = sock(10, 2, 0);
    unsigned char pm[40];
    int pl = 40;
    long h1 = getopt_(hs, 41, 61, pm, &pl);
    connect_(hs, a, 28);
    memset(pm, 0x55, sizeof pm);
    pl = 40;
    long h2 = getopt_(hs, 41, 61, pm, &pl);
    int h2len = pl;
    unsigned int hm; memcpy(&hm, pm + 28, 4);
    int zero_addr = 1;
    for (int k = 0; k < 28; k++) if (pm[k] != 0) zero_addr = 0;
    pl = 8;
    long h3 = getopt_(hs, 41, 61, pm, &pl);
    long ht = sock(10, 1, 0);
    pl = 40;
    long h4 = getopt_(ht, 41, 61, pm, &pl);
    snprintf(msg, sizeof msg, "H: IPV6_PATHMTU unconnected %ld; connected %ld len %d address zero %d mtu %u; optlen 8 %ld; TCP %ld (-107; 0 32 1 <=1500; -22; -107)", h1, h2, h2len, zero_addr, hm, h3,
             h4);
    check(h1 == -107 && h2 == 0 && h2len == 32 && zero_addr && hm >= 1280 && hm <= 1500 && h3 == -22 && h4 == -107, msg);

    unsigned char ta[28];
    memcpy(ta, a, 28);
    ta[2] = 4612 >> 8; ta[3] = 4612 & 0xff;
    long tl = sock(10, 1, 0);
    setopt_(tl, 1, 2, &one, 4);
    bind_(tl, ta, 28);
    listen_(tl);
    long tc = sock(10, 1, 0);
    long tcn = connect_(tc, ta, 28);
    long tsv = accept_(tl);
    unsigned int m1 = 0, m2 = 0, m3 = 0;
    pl = 32; long i1 = getopt_(tc, 41, 61, pm, &pl); memcpy(&m1, pm + 28, 4);
    pl = 32; long i2 = getopt_(tsv, 41, 61, pm, &pl); memcpy(&m2, pm + 28, 4);
    pl = 32; long i3 = getopt_(tl, 41, 61, pm, &pl);
    long rr = sock(10, 3, 58);
    pl = 32; long i4 = getopt_(rr, 41, 61, pm, &pl);
    connect_(rr, b, 28);
    pl = 32; long i5 = getopt_(rr, 41, 61, pm, &pl); memcpy(&m3, pm + 28, 4);
    snprintf(msg, sizeof msg, "I: TCP connect %ld accept %d; client %ld mtu %u, accepted %ld mtu %u, listener %ld; raw %ld, connected %ld mtu %u (0 1; 0 <=1500 0 <=1500 -107; -107 0 <=1500)",
             tcn, tsv >= 0, i1, m1, i2, m2, i3, i4, i5, m3);
    check(tcn == 0 && tsv >= 0 && i1 == 0 && m1 >= 1280 && m1 <= 1500 && i2 == 0 && m2 >= 1280 && m2 <= 1500 && i3 == -107 && i4 == -107 && i5 == 0 && m3 >= 1280 && m3 <= 1500, msg);

    long jr = sock(10, 3, 58);
    setopt_(jr, 41, 62, &one, 4);
    setopt_(jr, 41, 60, &one, 4);
    sendto_(jr, out, 3000, b, 28);
    memset(gctl, 0, sizeof gctl);
    memcpy(gh + 40, &gcl, 8);
    long j1 = recvmsg_(jr, gh, 0x40);
    long jcl; memcpy(&jcl, gh + 40, 8);
    int jty; memcpy(&jty, gctl + 12, 4);
    snprintf(msg, sizeof msg, "J: raw IPV6_RECVPATHMTU: recvmsg %ld controllen %ld type %d (0 48 61)", j1, jcl, jty);
    check(j1 == 0 && jcl == 48 && jty == 61, msg);

    print(failures ? "hello461: FAIL\n" : "hello461: PASS\n");
    return failures ? 1 : 0;
}
