/* hello390: an ICMP error reaches the socket whose datagram caused it (Linux icmp_unreach → udp_err / ping_err, icmp_err_convert):
 * a hard error on a connected UDP or ping socket becomes its SO_ERROR and fails the next send or receive once; soft errors and
 * unconnected sockets are left alone (only IP_RECVERR would report them). The errors are written through a raw ICMP socket to
 * 127.0.0.1, quoting a datagram the socket sent. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with only lo up):
 *   U. a UDP socket connected to 127.0.0.1:9 takes each error quoting its datagram as SO_ERROR: destination unreachable codes 2 3 4
 *      6 7 8 9 10 13 14 15 give 92 111 90 101 112 64 101 113 113 113 113, parameter problem EPROTO (71); codes 0 1 5 11 12, time
 *      exceeded, source quench and redirect give nothing;
 *   N. an unconnected UDP socket takes none of them;
 *   P. a ping socket connected to 127.0.0.1 takes the same errnos for errors quoting its echo requests;
 *   Q. an unconnected (bound) ping socket takes none;
 *   R. an error quoting an echo reply is for no ping socket;
 *   K. an error with a bad ICMP checksum is dropped;
 *   V. a pending error shows as POLLERR, fails the next ping recv once (ECONNREFUSED), then EAGAIN;
 *   S. it fails the next ping send once, and SO_ERROR reads 0 afterwards;
 *   E. on UDP too: recv is EHOSTUNREACH for code 13, then EAGAIN; send is ENOPROTOOPT for code 2;
 *   W. an unconnected ping socket with IP_RECVERR (ping_err → ip_icmp_error) queues even soft errors: host unreachable (3/1) gives
 *      SO_ERROR 113 and recvmsg(MSG_ERRQUEUE) returns the 8 quoted echo-request bytes, msg_name 127.0.0.1 port 0, IP_RECVERR with
 *      errno 113, origin 2, type 3, code 1; source quench (4/0), which a ping socket wants to see, is EREMOTEIO (121).
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
static long rsock(void) { return rc(socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)); }
static long usock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long psock(void) { return rc(socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 16)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long name_(long s, unsigned char *a) { socklen_t l = 16; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 16)); }
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
#define FAM(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#define O_WR O_WRONLY
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rsock(void) { return syscall3(117, 2, 3, 1); }
static long usock(void) { return syscall3(117, 2, 2, 0); }
static long psock(void) { return syscall3(117, 2, 2, 1); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 16); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long name_(long s, unsigned char *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
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
#define FAM(a) do { (a)[0] = 2; (a)[1] = 0; } while (0)
#define O_WR 1
#endif
static unsigned short csum(const unsigned char *p, int n) {
    unsigned long s = 0;
    for (int i = 0; i + 1 < n; i += 2) s += (unsigned long)((p[i] << 8) | p[i + 1]);
    if (n & 1) s += (unsigned long)(p[n - 1] << 8);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (unsigned short)~s;
}
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello390:   ok   " : "hello390:   FAIL ");
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
static unsigned char lo[16];
static unsigned char sink[2048];
/* An ICMP error of `type`/`code` sent to 127.0.0.1, quoting a datagram 127.0.0.1 -> 127.0.0.1 of protocol `proto` whose first 8
   payload bytes are `l4`; `bad` spoils the ICMP checksum. Frag needed carries MTU 65535 so no path MTU shrinks. */
static void inject(int type, int code, int proto, const unsigned char *l4, int bad) {
    unsigned char m[36];
    for (int i = 0; i < 36; i++) m[i] = 0;
    m[0] = (unsigned char)type; m[1] = (unsigned char)code;
    if (type == 12) m[4] = 20;
    if (type == 3 && code == 4) { m[6] = 0xff; m[7] = 0xff; }
    unsigned char *ip = m + 8;
    ip[0] = 0x45; ip[3] = 28; ip[8] = 64; ip[9] = (unsigned char)proto;
    ip[12] = 127; ip[15] = 1; ip[16] = 127; ip[19] = 1;
    unsigned short ic = csum(ip, 20);
    ip[10] = (unsigned char)(ic >> 8); ip[11] = (unsigned char)ic;
    for (int i = 0; i < 8; i++) m[28 + i] = l4[i];
    unsigned short c = csum(m, 36);
    if (bad) c ^= 0x5a5a;
    m[2] = (unsigned char)(c >> 8); m[3] = (unsigned char)c;
    sendto_(raw, m, 36, lo);
    nap();
    while (recv_(raw, sink, sizeof sink) >= 0) {}
}
static const int kinds[20][2] = { {3,0},{3,1},{3,2},{3,3},{3,4},{3,5},{3,6},{3,7},{3,8},{3,9},{3,10},{3,11},{3,12},{3,13},{3,14},{3,15},{11,0},{12,0},{5,0},{4,0} };
static const long want[20] = { 0, 0, 92, 111, 90, 0, 101, 112, 64, 101, 113, 0, 0, 113, 113, 113, 0, 71, 0, 0 };
/* Every kind quoting `l4`; the SO_ERROR each leaves on `s` goes to `got`; returns how many matched `expect` (or 0 when `none`). */
static int sweep(long s, int proto, const unsigned char *l4, int none, long *got) {
    int ok = 0;
    for (int k = 0; k < 20; k++) {
        inject(kinds[k][0], kinds[k][1], proto, l4, 0);
        got[k] = soerr(s);
        if (got[k] == (none ? 0 : want[k])) ok++;
    }
    return ok;
}
static void list(char *out, const long *v) {
    int o = 0;
    for (int k = 0; k < 20; k++) o += snprintf(out + o, 200 - o, "%s%ld", k ? " " : "", v[k]);
}
int main(void) {
    print("hello390: an ICMP error reaches the connected UDP or ping socket whose datagram caused it\n");
    char saved[48];
    long sfd = open_(RANGE, 0);
    long sn = sfd >= 0 ? read_(sfd, saved, sizeof saved - 1) : -1;
    if (sfd >= 0) close_(sfd);
    if (sn < 0) sn = 0;
    saved[sn] = 0;
    long sr = set_range("0 0");
    for (int i = 0; i < 16; i++) lo[i] = 0;
    FAM(lo); lo[4] = 127; lo[7] = 1;
    raw = rsock();
    unsigned char a[16], p9[16];
    for (int i = 0; i < 16; i++) p9[i] = lo[i];
    p9[3] = 9;
    char l1[200], l2[200];
    long got[20], got2[20];

    long u = usock();
    long uc = connect_(u, p9);
    name_(u, a);
    unsigned char uh[8] = { a[2], a[3], 0, 9, 0, 9, 0, 0 };
    int uok = sweep(u, 17, uh, 0, got);
    list(l1, got);
    snprintf(msg, sizeof msg, "U: raw %ld, range %ld, connect %ld; SO_ERROR per error %s (20 of 20: %d)", raw, sr, uc, l1, uok);
    check(raw >= 0 && uc == 0 && uok == 20, msg);

    long n = usock();
    unsigned char any[16];
    for (int i = 0; i < 16; i++) any[i] = lo[i];
    long nb = bind_(n, any);
    name_(n, a);
    unsigned char nh[8] = { a[2], a[3], 0, 9, 0, 9, 0, 0 };
    int nok = sweep(n, 17, nh, 1, got);
    list(l1, got);
    snprintf(msg, sizeof msg, "N: unconnected UDP bind %ld: %s (20 of 20 zero: %d)", nb, l1, nok);
    check(nb == 0 && nok == 20, msg);
    close_(n);

    long pc = psock();
    long pcc = connect_(pc, lo);
    name_(pc, a);
    unsigned char eq[8] = { 8, 0, 0, 0, a[2], a[3], 0, 1 };
    int pok = sweep(pc, 1, eq, 0, got);
    list(l1, got);
    snprintf(msg, sizeof msg, "P: ping socket %ld connect %ld ident %d: %s (20 of 20: %d)", pc, pcc, (a[2] << 8) | a[3], l1, pok);
    check(pc >= 0 && pcc == 0 && pok == 20, msg);

    long pu = psock();
    unsigned char b42[16];
    for (int i = 0; i < 16; i++) b42[i] = lo[i];
    b42[2] = 4242 >> 8; b42[3] = 4242 & 0xff;
    long pub = bind_(pu, b42);
    unsigned char eu[8] = { 8, 0, 0, 0, 4242 >> 8, 4242 & 0xff, 0, 1 };
    int qok = sweep(pu, 1, eu, 1, got2);
    list(l2, got2);
    snprintf(msg, sizeof msg, "Q: unconnected ping socket bind %ld: %s (20 of 20 zero: %d)", pub, l2, qok);
    check(pub == 0 && qok == 20, msg);
    close_(pu);

    unsigned char er[8] = { 0, 0, 0, 0, eq[4], eq[5], 0, 1 };
    inject(3, 3, 1, er, 0);
    long re = soerr(pc);
    inject(3, 3, 1, eq, 1);
    long ke = soerr(pc);
    snprintf(msg, sizeof msg, "R/K: quoting an echo reply %ld, a bad checksum %ld (0 0)", re, ke);
    check(re == 0 && ke == 0, msg);

    inject(3, 3, 1, eq, 0);
    long pv = revents(pc);
    long v1 = recv_(pc, sink, 64), v2 = recv_(pc, sink, 64), ve = soerr(pc);
    snprintf(msg, sizeof msg, "V: POLLERR %d, recv %ld then %ld, SO_ERROR %ld (1 -111 -11 0)", (pv & 8) != 0, v1, v2, ve);
    check((pv & 8) != 0 && v1 == -111 && v2 == -11 && ve == 0, msg);

    inject(3, 3, 1, eq, 0);
    long s1 = send_(pc, eq, 8), se = soerr(pc);
    nap();
    while (recv_(pc, sink, sizeof sink) >= 0) {}
    snprintf(msg, sizeof msg, "S: send %ld, SO_ERROR after %ld (-111 0)", s1, se);
    check(s1 == -111 && se == 0, msg);
    close_(pc);

    inject(3, 13, 17, uh, 0);
    long e1 = recv_(u, sink, 64), e2 = recv_(u, sink, 64);
    inject(3, 2, 17, uh, 0);
    long e3 = send_(u, "x", 1), e4 = soerr(u);
    snprintf(msg, sizeof msg, "E: UDP recv %ld then %ld; send %ld, SO_ERROR %ld (-113 -11 -92 0)", e1, e2, e3, e4);
    check(e1 == -113 && e2 == -11 && e3 == -92 && e4 == 0, msg);
    close_(u);

    long pw = psock();
    unsigned char b43[16];
    for (int i = 0; i < 16; i++) b43[i] = lo[i];
    b43[2] = 4343 >> 8; b43[3] = 4343 & 0xff;
    long pwb = bind_(pw, b43);
    long pwo = setopt_(pw, 0, 11, 1);
    unsigned char ew[8] = { 8, 0, 0, 0, 4343 >> 8, 4343 & 0xff, 0, 1 };
    inject(3, 1, 1, ew, 0);
    long we = soerr(pw);
    struct { void *b; unsigned long n; } wio = { sink, sizeof sink };
    unsigned char wname[16], wctl[64];
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
    inject(4, 0, 1, ew, 0);
    long wq = soerr(pw);
    snprintf(msg, sizeof msg, "W: IP_RECVERR ping bind %ld set %ld; SO_ERROR %ld; errqueue %ld quote %d, name %d %d.%d.%d.%d port %d, flags 0x%x, [%d/%d] errno %d "
             "origin %d type %d code %d; source quench SO_ERROR %ld (0 0; 113; 8 1, 2 127.0.0.1 0, 0x2000, [0/11] 113 2 3 1; 121)", pwb, pwo, we, wr, wquote,
             wname[0], wname[4], wname[5], wname[6], wname[7], (wname[2] << 8) | wname[3], wm.flags, wlv, wty, werr, wctl[20], wctl[21], wctl[22], wq);
    check(pwb == 0 && pwo == 0 && we == 113 && wquote && wname[0] == 2 && wname[4] == 127 && wname[7] == 1 && wname[2] == 0 && wname[3] == 0 &&
              wm.flags == 0x2000 && wlv == 0 && wty == 11 && werr == 113 && wctl[20] == 2 && wctl[21] == 3 && wctl[22] == 1 && wq == 121,
          msg);
    close_(pw);
    close_(raw);

    long back = set_range(saved);
    snprintf(msg, sizeof msg, "restored ping_group_range (%ld)", back);
    print("hello390:   info ");
    print(msg);
    print("\n");
    print(failures ? "hello390: FAIL\n" : "hello390: PASS\n");
    return failures ? 1 : 0;
}
