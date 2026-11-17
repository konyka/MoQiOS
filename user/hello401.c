/* hello401: IPv4 raw sockets of any protocol (Linux inet_create / raw_v4_input / ip_protocol_deliver_rcu): socket(AF_INET,
 * SOCK_RAW, p) takes any p from 1 to 255 (0 is EPROTONOSUPPORT, out of range EINVAL); IPPROTO_RAW (255) starts with IP_HDRINCL
 * set; every datagram of protocol p this host receives goes to each raw socket of protocol p, before TCP or UDP see it; a protocol
 * nobody handles, with no raw socket taking it, gets an ICMP protocol unreachable. Measured on the host (build with -DHOST, run as
 * root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   A. protocol 0 is EPROTONOSUPPORT, -1 and 263 are EINVAL; protocol 253: SO_PROTOCOL 253, getsockname names port 253,
 *      IP_HDRINCL 0; IPPROTO_RAW: IP_HDRINCL 1; ICMP_FILTER on a protocol-253 socket is EOPNOTSUPP both ways;
 *   S. a protocol-253 socket sends "hello" to 127.0.0.1 (5), and gets a 25-byte copy back: protocol 253, TTL 64, the payload after
 *      a 20-byte header, sender port 0; a 0-byte send returns 0 and its copy is the 20-byte header alone; 1 byte is fine too;
 *   O. a second protocol-253 socket gets the same copies; a protocol-254 socket and the ICMP one get none;
 *   U. a protocol-17 (UDP) raw socket sees a UDP datagram to a bound UDP socket (32 bytes, protocol 17, destination port as sent)
 *      and the UDP socket still gets it;
 *   T. a protocol-6 (TCP) raw socket sees both segments of a refused connect to 127.0.0.1: the SYN and the RST|ACK (the low six
 *      flag bits 0x02 and 0x14; a SYN that asks for ECN also carries ECE|CWR, which Linux's default tcp_ecn=2 client leaves out);
 *   P. an IPPROTO_RAW socket sends a whole datagram of protocol 252, which nobody handles: an ICMP raw socket gets a protocol
 *      unreachable (type 3 code 2) quoting it; with a protocol-252 raw socket open, that socket gets it instead and no error comes;
 *   B. a protocol-248 socket bound to 127.0.0.1 does not get a datagram to 127.0.0.2 (and the sender then gets protocol unreachable:
 *      no raw socket took it). */
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
    print(ok ? "hello401:   ok   " : "hello401:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char buf[1600];
static const unsigned char lo[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
static long rd(long s) { unsigned char a[16]; int l = 16; return recvfrom_(s, buf, sizeof buf, a, &l); }
static void drain(long s) { while (rd(s) >= 0) {} }
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
/* Read `s` until an ICMP protocol unreachable (type 3 code 2) arrives whose quote names protocol `proto`: 1, or 0 when none did. */
static int got_unreach(long s, int proto) {
    for (int i = 0; i < 12; i++) {
        long n = rd(s);
        if (n < 0) return 0;
        if (n >= 48 && buf[20] == 3 && buf[21] == 2 && buf[28 + 9] == proto) return 1;
    }
    return 0;
}
/* A 24-byte datagram of protocol `proto` from 127.0.0.1 to `dst_last` (127.0.0.x), payload "abcd", for an IP_HDRINCL send. */
static unsigned char hdr[24];
static void mk_dgram(int proto, int dst_last) {
    static const unsigned char t[24] = { 0x45, 0, 0, 24, 0, 0, 0, 0, 64, 0, 0, 0, 127, 0, 0, 1, 127, 0, 0, 1, 'a', 'b', 'c', 'd' };
    memcpy(hdr, t, 24);
    hdr[9] = (unsigned char)proto;
    hdr[19] = (unsigned char)dst_last;
}
int main(void) {
    print("hello401: IPv4 raw sockets of any protocol\n");
    long p0 = sock(2, 3, 0), pm = sock(2, 3, -1), p263 = sock(2, 3, 263);
    long a = sock(2, 3, 253), r255 = sock(2, 3, 255);
    unsigned char nm[16];
    int nl = 16;
    long gn = getname(a, nm, &nl);
    int port = nm[2] << 8 | nm[3];
    unsigned int m = 0;
    int ml = 4;
    long fs = setopt(a, 255, 1, &m, 4), fg = getopt_(a, 255, 1, &m, &ml);
    snprintf(msg, sizeof msg, "A: protocol 0 %ld (-93), -1 %ld (-22), 263 %ld (-22); 253: socket %ld SO_PROTOCOL %d getsockname %ld port %d IP_HDRINCL %d; 255: IP_HDRINCL %d; ICMP_FILTER set %ld get %ld (-95 -95)",
             p0, pm, p263, a, geti(a, 1, 38), gn, port, geti(a, 0, 3), geti(r255, 0, 3), fs, fg);
    check(p0 == -93 && pm == -22 && p263 == -22 && a >= 0 && geti(a, 1, 38) == 253 && gn == 0 && port == 253 && geti(a, 0, 3) == 0 && geti(r255, 0, 3) == 1 && fs == -95 && fg == -95, msg);

    long b = sock(2, 3, 253), c = sock(2, 3, 254), ic = sock(2, 3, 1);
    drain(a); drain(b); drain(c); drain(ic);
    long s5 = sendto_(a, "hello", 5, lo, 16);
    nap();
    unsigned char from[16];
    int fl = 16;
    long n1 = recvfrom_(a, buf, sizeof buf, from, &fl);
    int pr = buf[9], ttl = buf[8], pl = memcmp(buf + 20, "hello", 5) == 0, fport = from[2] << 8 | from[3], fa = from[4];
    long s0 = sendto_(a, "", 0, lo, 16);
    nap();
    long n0 = rd(a);
    int tot = buf[2] << 8 | buf[3];
    long s1 = sendto_(a, "z", 1, lo, 16);
    nap();
    long n11 = rd(a);
    snprintf(msg, sizeof msg, "S: send 5 %ld; copy %ld (25) protocol %d (253) TTL %d (64) payload %d from %d port %d; send 0 %ld copy %ld total %d (20 20); send 1 %ld copy %ld (21)",
             s5, n1, pr, ttl, pl, fa, fport, s0, n0, tot, s1, n11);
    check(s5 == 5 && n1 == 25 && pr == 253 && ttl == 64 && pl && fa == 127 && fport == 0 && s0 == 0 && n0 == 20 && tot == 20 && s1 == 1 && n11 == 21, msg);

    long o1 = rd(b), o2 = rd(b), o3 = rd(b), o4 = rd(b), oc = rd(c), oi = rd(ic);
    snprintf(msg, sizeof msg, "O: second 253 socket got %ld %ld %ld then %ld (25 20 21 -11); 254 socket %ld, ICMP socket %ld (-11 -11)", o1, o2, o3, o4, oc, oi);
    check(o1 == 25 && o2 == 20 && o3 == 21 && o4 == -11 && oc == -11 && oi == -11, msg);
    close_(b); close_(c);

    long u = sock(2, 2, 0), ru = sock(2, 3, 17);
    unsigned char ua[16] = { 2, 0, 0x0f, 0xab, 127, 0, 0, 1 };
    long ub = bind_(u, ua, 16);
    drain(ru);
    long us = sendto_(u, "udp!", 4, ua, 16);
    nap();
    long rn = rd(ru);
    int rpr = buf[9], rdp = buf[22] << 8 | buf[23];
    long un = rd(u);
    snprintf(msg, sizeof msg, "U: bind %ld, send %ld; raw UDP socket %ld (32) protocol %d (17) port %d (4011); UDP socket %ld (4)", ub, us, rn, rpr, rdp, un);
    check(ub == 0 && us == 4 && rn == 32 && rpr == 17 && rdp == 4011 && un == 4, msg);
    close_(u); close_(ru);

    long rt = sock(2, 3, 6), tc = sock(2, 1, 0);
    drain(rt);
    unsigned char ta[16] = { 2, 0, 0x0f, 0xac, 127, 0, 0, 1 };
    long cr = connect_(tc, ta, 16);
    nap();
    int f1 = -1, f2 = -1;
    long t1 = rd(rt);
    if (t1 >= 40) f1 = buf[33] & 0x3f;
    long t2 = rd(rt);
    if (t2 >= 40) f2 = buf[33] & 0x3f;
    snprintf(msg, sizeof msg, "T: connect to a closed port %ld (-111); raw TCP socket %ld flags 0x%x (0x2), %ld flags 0x%x (0x14)", cr, t1, f1, t2, f2);
    check(cr == -111 && t1 >= 40 && f1 == 0x02 && t2 >= 40 && f2 == 0x14, msg);
    close_(tc); close_(rt);

    drain(ic);
    mk_dgram(252, 1);
    long ps = sendto_(r255, hdr, 24, lo, 16);
    nap();
    int pu = got_unreach(ic, 252);
    long d252 = sock(2, 3, 252);
    drain(ic);
    long ps2 = sendto_(r255, hdr, 24, lo, 16);
    nap();
    long pg = rd(d252);
    int ppr = buf[9];
    int pu2 = got_unreach(ic, 252);
    snprintf(msg, sizeof msg, "P: protocol 252 sent %ld (24), protocol unreachable %d (1); with a 252 socket: sent %ld, it got %ld (24) protocol %d, unreachable %d (0)", ps, pu, ps2, pg, ppr, pu2);
    check(ps == 24 && pu == 1 && ps2 == 24 && pg == 24 && ppr == 252 && pu2 == 0, msg);
    close_(d252);

    long d = sock(2, 3, 248);
    long db = bind_(d, lo, 16);
    drain(ic);
    mk_dgram(248, 2);
    unsigned char lo2[16] = { 2, 0, 0, 0, 127, 0, 0, 2 };
    long bs = sendto_(r255, hdr, 24, lo2, 16);
    nap();
    long bg = rd(d);
    int bu = got_unreach(ic, 248);
    snprintf(msg, sizeof msg, "B: bind 248 to 127.0.0.1 %ld; sent to 127.0.0.2 %ld; bound socket %ld (-11); protocol unreachable %d (1)", db, bs, bg, bu);
    check(db == 0 && bs == 24 && bg == -11 && bu == 1, msg);
    close_(d); close_(ic); close_(a); close_(r255);

    print(failures == 0 ? "hello401: PASS\n" : "hello401: FAIL\n");
    return failures == 0 ? 0 : 1;
}
