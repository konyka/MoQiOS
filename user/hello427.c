/* hello427: IPv6 raw socket sendmsg control messages (Linux rawv6_sendmsg -> ip6_datagram_send_ctl, __sock_cmsg_send; no
 * udp_cmsg_send). The test sends UDP datagrams through a raw socket of protocol 17 with IPV6_CHECKSUM 6 (the kernel fills in the UDP
 * checksum) to a UDP socket on ::1 that reports the hop limit, traffic class and source of each. IPV6_HOPLIMIT (an int, -1..255; -1
 * keeps the socket's value) and IPV6_TCLASS (an int, -1..255; -1 sends 0xff) override the socket's values for that one datagram;
 * IPV6_PKTINFO names the source address and the outgoing interface. A malformed message or an unknown IPv6-level type is EINVAL;
 * IPV6_DONTFRAG 0/1, IPV6_FLOWINFO, SOL_UDP, other levels and SCM_RIGHTS are skipped. Destination errors come first.
 * Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   O. a plain send carries the socket's IPV6_UNICAST_HOPS 33 / IPV6_TCLASS 0x28; IPV6_HOPLIMIT 7 gives 7, 0 gives 0, -1 keeps 33;
 *      RFC 2292's IPV6_HOPLIMIT (8) 8 gives 8; IPV6_TCLASS 0x4b gives 0x4b, -1 gives 0xff, 0 gives 0; both at once; plain again;
 *   E. EINVAL for: hop limit 256, -2, 1 byte; tclass 256, -2, 1 byte; IPV6_DONTFRAG 2; IPv6 level type 99; cmsg_len 12; SOL_SOCKET
 *      type 99; IPV6_PKTINFO of 16 bytes; nothing is sent;
 *   S. skipped: IPV6_DONTFRAG 1, SOL_IP IP_TTL, IPV6_FLOWINFO, SCM_RIGHTS, SOL_UDP UDP_SEGMENT of 4 bytes;
 *   P. IPV6_PKTINFO :: and ::1 send (from ::1); interface 99 is ENODEV; 2001:db8::1, fe80::1 without an interface and ff02::1 are
 *      EINVAL; none of these sends;
 *   D. an unconnected raw socket without a destination and with a bad hop limit is EDESTADDRREQ. */
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
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void close_(long s) { close((int)s); }
static long sendmsg_(long s, long *m, int fl) { return rc(sendmsg((int)s, (struct msghdr *)m, fl)); }
static long recvmsg_(long s, long *m, int fl) { return rc(recvmsg((int)s, (struct msghdr *)m, fl)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void close_(long s) { syscall1(11, s); }
static long sendmsg_(long s, long *m, int fl) { return syscall3(46, s, (long)m, fl); }
static long recvmsg_(long s, long *m, int fl) { return syscall3(130, s, (long)m, fl); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[1600];
static void check(int ok, const char *w) {
    print(ok ? "hello427:   ok   " : "hello427:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
/* A sockaddr_in6 for [::1]:port (or [::]:port when !lo). */
static void mk6(unsigned char *a, int port, int lo) {
    memset(a, 0, 28);
    a[0] = 10;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    if (lo) a[23] = 1;
}
static unsigned char cbuf[256];
/* Append a control message at `off` (cmsg_len `len`, or the exact length when 0); returns the next offset. */
static int put(int off, int lv, int ty, const void *d, int dl, long len) {
    memset(cbuf + off, 0, 16 + ((dl + 7) & ~7));
    long l = len ? len : 16 + dl;
    memcpy(cbuf + off, &l, 8);
    memcpy(cbuf + off + 8, &lv, 4);
    memcpy(cbuf + off + 12, &ty, 4);
    memcpy(cbuf + off + 16, d, (size_t)dl);
    return off + 16 + ((dl + 7) & ~7);
}
static int puti(int off, int ty, int v) { return put(off, 41, ty, &v, 4, 0); }
/* An IPV6_PKTINFO (type `ty`) for address `a` on interface `ifx`, `dl` bytes long (20 is the struct). */
static int putpk(int off, int ty, const unsigned char *a, int ifx, int dl) {
    unsigned char p[24];
    memset(p, 0, sizeof p);
    memcpy(p, a, 16);
    memcpy(p + 16, &ifx, 4);
    return put(off, 41, ty, p, dl, 0);
}
static unsigned char to[28];
static long tx;
static long snd_to(long s, const unsigned char *dst, long clen) {
    static unsigned char data[12] = { 0x13, 0x88, 0x9d, 0xeb, 0, 12, 0, 0, 'p', 'i', 'n', 'g' };
    long iov[2] = { (long)data, 12 };
    long m[7] = { (long)dst, dst ? 28 : 0, (long)iov, 1, clen ? (long)cbuf : 0, clen, 0 };
    return sendmsg_(s, m, 0);
}
static long snd(long clen) { return snd_to(tx, to, clen); }
static long rx;
static int r_hl, r_tc, r_src;
/* Receive one datagram on rx without waiting: its length (-11 when none came), hop limit, traffic class and the last byte of its
 * source in r_hl, r_tc, r_src. */
static long rcv(void) {
    for (int i = 0; i < 3; i++) nap();
    static char d[16];
    static unsigned char c[128];
    unsigned char from[28];
    long iov[2] = { (long)d, 16 };
    long m[7] = { (long)from, 28, (long)iov, 1, (long)c, 128, 0 };
    r_hl = r_tc = r_src = -1;
    long r = recvmsg_(rx, m, 0x40);
    if (r < 0) return r;
    long cl = m[5];
    for (long off = 0; off + 16 <= cl;) {
        long l = 0;
        int ty = 0;
        memcpy(&l, c + off, 8);
        memcpy(&ty, c + off + 12, 4);
        if (ty == 52) memcpy(&r_hl, c + off + 16, 4);
        if (ty == 67) memcpy(&r_tc, c + off + 16, 4);
        if (l < 16) break;
        off += (l + 7) & ~7L;
    }
    r_src = from[23];
    return r;
}
/* Send with `clen` bytes of control and receive: 1 when it went out with hop limit `hl` and traffic class `tc`. */
static long gs, gr;
static int got(long clen, int hl, int tc) {
    gs = snd(clen);
    gr = rcv();
    return gs == 12 && gr == 4 && r_hl == hl && r_tc == tc && r_src == 1;
}
int main(void) {
    print("hello427: IPv6 raw socket sendmsg control messages\n");
    unsigned char ra[28];
    mk6(ra, 40427, 0);
    mk6(to, 0, 1);
    rx = sock(10, 2, 0);
    long b = bind_(rx, ra, 28);
    seti(rx, 41, 51, 1);
    seti(rx, 41, 66, 1);
    tx = sock(10, 3, 17);
    long ck = seti(tx, 41, 7, 6);
    seti(tx, 41, 16, 33);
    seti(tx, 41, 67, 0x28);
    snprintf(msg, sizeof msg, "setup: bind %ld, raw %ld, IPV6_CHECKSUM %ld (0, >=0, 0)", b, tx, ck);
    check(b == 0 && tx >= 0 && ck == 0, msg);

    int o0 = got(0, 33, 0x28), o1 = got(puti(0, 52, 7), 7, 0x28), o2 = got(puti(0, 52, 0), 0, 0x28), o3 = got(puti(0, 52, -1), 33, 0x28);
    int o4 = got(puti(0, 8, 8), 8, 0x28), o5 = got(puti(0, 67, 0x4b), 33, 0x4b), o6 = got(puti(0, 67, -1), 33, 0xff), o7 = got(puti(0, 67, 0), 33, 0);
    int o8 = got(puti(puti(0, 52, 9), 67, 0x60), 9, 0x60), o9 = got(0, 33, 0x28);
    snprintf(msg, sizeof msg, "O: plain %d, hl 7 %d, hl 0 %d, hl -1 %d, 2292 hl 8 %d, tc 0x4b %d, tc -1 %d, tc 0 %d, both %d, plain again %d (all 1)",
             o0, o1, o2, o3, o4, o5, o6, o7, o8, o9);
    check(o0 && o1 && o2 && o3 && o4 && o5 && o6 && o7 && o8 && o9, msg);

    long e[12];
    unsigned char one = 5, z[16];
    memset(z, 0, sizeof z);
    e[0] = snd(puti(0, 52, 256));
    e[1] = snd(puti(0, 52, -2));
    e[2] = snd(put(0, 41, 52, &one, 1, 0));
    e[3] = snd(puti(0, 67, 256));
    e[4] = snd(puti(0, 67, -2));
    e[5] = snd(put(0, 41, 67, &one, 1, 0));
    e[6] = snd(puti(0, 62, 2));
    e[7] = snd(puti(0, 99, 3));
    int v = 3;
    e[8] = snd(put(0, 41, 52, &v, 4, 12));
    e[9] = snd(put(0, 1, 99, &v, 4, 0));
    e[10] = snd(put(0, 41, 50, z, 16, 0));
    e[11] = rcv();
    snprintf(msg, sizeof msg, "E: hl 256 %ld, -2 %ld, 1 byte %ld; tc 256 %ld, -2 %ld, 1 byte %ld; dontfrag 2 %ld; type 99 %ld; cmsg_len 12 %ld; SOL_SOCKET 99 %ld; "
             "PKTINFO 16 bytes %ld; nothing sent %ld (all -22; -11)", e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9], e[10], e[11]);
    int eok = e[11] == -11;
    for (int i = 0; i < 11; i++) eok = eok && e[i] == -22;
    check(eok, msg);

    int s0 = got(puti(0, 62, 1), 33, 0x28);
    v = 3;
    int s1 = got(put(0, 0, 2, &v, 4, 0), 33, 0x28);
    int s2 = got(puti(0, 11, 0), 33, 0x28);
    int s3 = got(put(0, 1, 1, &v, 4, 0), 33, 0x28);
    int s4 = got(put(0, 17, 103, &v, 4, 0), 33, 0x28);
    snprintf(msg, sizeof msg, "S: dontfrag 1 %d, SOL_IP IP_TTL %d, flowinfo %d, SCM_RIGHTS %d, SOL_UDP UDP_SEGMENT 4 bytes %d (all 1)", s0, s1, s2, s3, s4);
    check(s0 && s1 && s2 && s3 && s4, msg);

    unsigned char lo6[16], doc[16], ll[16], grp[16];
    memset(lo6, 0, 16); lo6[15] = 1;
    memset(doc, 0, 16); doc[0] = 0x20; doc[1] = 0x01; doc[2] = 0x0d; doc[3] = 0xb8; doc[15] = 1;
    memset(ll, 0, 16); ll[0] = 0xfe; ll[1] = 0x80; ll[15] = 1;
    memset(grp, 0, 16); grp[0] = 0xff; grp[1] = 0x02; grp[15] = 1;
    int p0 = got(putpk(0, 50, z, 0, 20), 33, 0x28), p1 = got(putpk(0, 50, lo6, 0, 20), 33, 0x28), p2 = got(putpk(0, 50, lo6, 1, 20), 33, 0x28);
    long q0 = snd(putpk(0, 50, z, 99, 20)), q1 = snd(putpk(0, 50, doc, 0, 20)), q2 = snd(putpk(0, 50, ll, 0, 20)), q3 = snd(putpk(0, 50, grp, 0, 20));
    long q4 = rcv();
    snprintf(msg, sizeof msg, "P: :: %d, ::1 %d, ::1 if1 %d; if99 %ld, 2001:db8::1 %ld, fe80::1 %ld, ff02::1 %ld; nothing sent %ld (1 1 1; -19 -22 -22 -22; -11)",
             p0, p1, p2, q0, q1, q2, q3, q4);
    check(p0 && p1 && p2 && q0 == -19 && q1 == -22 && q2 == -22 && q3 == -22 && q4 == -11, msg);

    long un = sock(10, 3, 17);
    long dn = snd_to(un, 0, puti(0, 52, 256));
    snprintf(msg, sizeof msg, "D: no destination and a bad hop limit: %ld (-89)", dn);
    check(dn == -89, msg);

    close_(un);
    close_(tx);
    close_(rx);
    print(failures == 0 ? "hello427: PASS\n" : "hello427: FAIL\n");
    return failures == 0 ? 0 : 1;
}
