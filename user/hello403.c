/* hello403: IPv6 raw sockets of any protocol (Linux inet6_create / raw6_local_deliver / ip6_protocol_deliver_rcu):
 * socket(AF_INET6, SOCK_RAW, p) carries protocol p; every IPv6 packet of next header p this host receives goes, without its IPv6
 * header, to each raw socket of protocol p, before TCP or UDP see it; a next header nobody handles, with no raw socket taking it,
 * gets an ICMPv6 parameter problem (unrecognized next header). Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with only lo up):
 *   A. protocol 0 is EPROTONOSUPPORT, -1 and 263 EINVAL; protocol 253: SO_PROTOCOL 253, SO_DOMAIN 10, getsockname names port 253
 *      in 28 bytes; IPV6_CHECKSUM reads -1; ICMP6_FILTER is EOPNOTSUPP both ways;
 *   S. a protocol-253 socket sends "hello" to ::1 (5) and gets the 5 bytes back without a header, from ::1 port 0 in 28 bytes;
 *      a 0-byte send returns 0 and its copy is empty; sin6_port 253 is accepted, 17 is EINVAL;
 *   O. a second protocol-253 socket gets the same copies; a protocol-254 socket and an ICMPv6 one get none;
 *   U. a protocol-17 (UDP) raw socket sees a UDP datagram to a bound UDP socket (12 bytes, destination port as sent) and the UDP
 *      socket still gets it;
 *   T. a protocol-6 (TCP) raw socket sees both segments of a refused connect to [::1]: the SYN and the RST|ACK (low six flag bits
 *      0x02 and 0x14);
 *   K. IPV6_CHECKSUM on a protocol-253 socket: 4 sets it (reads 4), 3 is EINVAL, -1 clears it; with offset 4 a 5-byte send is
 *      EINVAL (the checksum must fit), an 8-byte one goes out with the checksum written at bytes 4-5 so the receiver's sum over the
 *      pseudo-header (next header 253) and the message is 0xffff; a datagram whose sum is wrong is dropped for that socket
 *      (rawv6_recvmsg); with it cleared the bytes arrive as sent. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, a, (socklen_t *)al)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static long getname(long s, void *a, int *l) { return rc(getsockname((int)s, a, (socklen_t *)l)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return syscall6(122, s, (long)b, n, 0x40, (long)a, (long)al); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long getname(long s, void *a, int *l) { return syscall3(126, s, (long)a, (long)l); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello403:   ok   " : "hello403:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char buf[1600];
static unsigned char from[28];
static int froml;
static const unsigned char lo6[28] = { 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
static long rd(long s) { froml = 28; return recvfrom_(s, buf, sizeof buf, from, &froml); }
static void drain(long s) { while (rd(s) >= 0) {} }
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static void with_port(unsigned char *a, int port) { memcpy(a, lo6, 28); a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port; }
int main(void) {
    print("hello403: IPv6 raw sockets of any protocol\n");
    long p0 = sock(10, 3, 0), pm = sock(10, 3, -1), p263 = sock(10, 3, 263);
    long a = sock(10, 3, 253);
    unsigned char nm[28];
    int nl = 28;
    long gn = getname(a, nm, &nl);
    int port = nm[2] << 8 | nm[3];
    unsigned char filt[32];
    memset(filt, 0, sizeof filt);
    int fl = 32;
    long fs = setopt(a, 58, 1, filt, 32), fg = getopt_(a, 58, 1, filt, &fl);
    snprintf(msg, sizeof msg, "A: protocol 0 %ld (-93), -1 %ld (-22), 263 %ld (-22); 253: socket %ld SO_PROTOCOL %d SO_DOMAIN %d getsockname %ld len %d port %d; IPV6_CHECKSUM %d (-1); ICMP6_FILTER set %ld get %ld (-95 -95)",
             p0, pm, p263, a, geti(a, 1, 38), geti(a, 1, 39), gn, nl, port, geti(a, 41, 7), fs, fg);
    check(p0 == -93 && pm == -22 && p263 == -22 && a >= 0 && geti(a, 1, 38) == 253 && geti(a, 1, 39) == 10 && gn == 0 && nl == 28 && port == 253 && geti(a, 41, 7) == -1 && fs == -95 && fg == -95, msg);

    long b = sock(10, 3, 253), c = sock(10, 3, 254), ic = sock(10, 3, 58);
    drain(a); drain(b); drain(c); drain(ic);
    long s5 = sendto_(a, "hello", 5, lo6, 28);
    nap();
    long n1 = rd(a);
    int pl = n1 == 5 && memcmp(buf, "hello", 5) == 0, ffam = from[0], fport = from[2] << 8 | from[3], flast = from[23], flen = froml;
    long s0 = sendto_(a, "", 0, lo6, 28);
    nap();
    long n0 = rd(a);
    unsigned char ap[28];
    with_port(ap, 253);
    long sp = sendto_(a, "p", 1, ap, 28);
    nap();
    long np = rd(a);
    with_port(ap, 17);
    long s17 = sendto_(a, "q", 1, ap, 28);
    snprintf(msg, sizeof msg, "S: send 5 %ld; copy %ld (5) payload %d from family %d port %d last byte %d len %d (10 0 1 28); send 0 %ld copy %ld (0 0); port 253 send %ld copy %ld (1 1); port 17 %ld (-22)",
             s5, n1, pl, ffam, fport, flast, flen, s0, n0, sp, np, s17);
    check(s5 == 5 && pl && ffam == 10 && fport == 0 && flast == 1 && flen == 28 && s0 == 0 && n0 == 0 && sp == 1 && np == 1 && s17 == -22, msg);

    long o1 = rd(b), o2 = rd(b), o3 = rd(b), o4 = rd(b), oc = rd(c), oi = rd(ic);
    snprintf(msg, sizeof msg, "O: second 253 socket got %ld %ld %ld then %ld (5 0 1 -11); 254 socket %ld, ICMPv6 socket %ld (-11 -11)", o1, o2, o3, o4, oc, oi);
    check(o1 == 5 && o2 == 0 && o3 == 1 && o4 == -11 && oc == -11 && oi == -11, msg);
    close_(b); close_(c); close_(ic);

    long u = sock(10, 2, 0), ru = sock(10, 3, 17);
    unsigned char ua[28];
    with_port(ua, 4011);
    long ub = bind_(u, ua, 28);
    drain(ru);
    long us = sendto_(u, "udp!", 4, ua, 28);
    nap();
    long rn = rd(ru);
    int rdp = buf[2] << 8 | buf[3];
    long un = rd(u);
    snprintf(msg, sizeof msg, "U: bind %ld, send %ld; raw UDP socket %ld (12) port %d (4011); UDP socket %ld (4)", ub, us, rn, rdp, un);
    check(ub == 0 && us == 4 && rn == 12 && rdp == 4011 && un == 4, msg);
    close_(u); close_(ru);

    long rt = sock(10, 3, 6), tc = sock(10, 1, 0);
    drain(rt);
    unsigned char ta[28];
    with_port(ta, 4012);
    long cr = connect_(tc, ta, 28);
    nap();
    int f1 = -1, f2 = -1;
    long t1 = rd(rt);
    if (t1 >= 20) f1 = buf[13] & 0x3f;
    long t2 = rd(rt);
    if (t2 >= 20) f2 = buf[13] & 0x3f;
    snprintf(msg, sizeof msg, "T: connect to a closed port %ld (-111); raw TCP socket %ld flags 0x%x (0x2), %ld flags 0x%x (0x14)", cr, t1, f1, t2, f2);
    check(cr == -111 && t1 >= 20 && f1 == 0x02 && t2 >= 20 && f2 == 0x14, msg);
    close_(tc); close_(rt);

    int four = 4, three = 3, neg = -1;
    long k4 = setopt(a, 41, 7, &four, 4);
    int r4 = geti(a, 41, 7);
    long k3 = setopt(a, 41, 7, &three, 4);
    drain(a);
    long k5 = sendto_(a, "abcde", 5, lo6, 28);
    unsigned char m8[8] = { 1, 2, 3, 4, 0, 0, 7, 8 };
    long k8 = sendto_(a, m8, 8, lo6, 28);
    long b2 = sock(10, 3, 253);
    long kb = sendto_(b2, m8, 8, lo6, 28);
    close_(b2);
    nap();
    long kn = rd(a);
    unsigned long sum = 0;
    for (int i = 0; i < 8; i += 2) sum += (unsigned long)(buf[i] << 8 | buf[i + 1]);
    sum += 1 + 1 + 8 + 253; /* ::1 + ::1, length 8, next header 253 */
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    long kx = rd(a);
    long kc = setopt(a, 41, 7, &neg, 4);
    int rc_ = geti(a, 41, 7);
    long kp = sendto_(a, m8, 8, lo6, 28);
    nap();
    long kq = rd(a);
    int plain = kq == 8 && buf[4] == 0 && buf[5] == 0;
    snprintf(msg, sizeof msg, "K: IPV6_CHECKSUM 4 %ld reads %d, 3 %ld (-22); send 5 %ld (-22), send 8 %ld copy %ld sum 0x%lx (0xffff); a bad sum from a socket without the option, sent %ld, is dropped %ld (-11); clear %ld reads %d, send %ld copy plain %d",
             k4, r4, k3, k5, k8, kn, sum, kb, kx, kc, rc_, kp, plain);
    check(k4 == 0 && r4 == 4 && k3 == -22 && k5 == -22 && k8 == 8 && kn == 8 && sum == 0xffff && kb == 8 && kx == -11 && kc == 0 && rc_ == -1 && kp == 8 && plain, msg);
    close_(a);

    print(failures == 0 ? "hello403: PASS\n" : "hello403: FAIL\n");
    return failures == 0 ? 0 : 1;
}
