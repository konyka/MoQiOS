/* hello426: IPv4 raw socket sendmsg control messages (Linux raw_sendmsg -> ip_cmsg_send, __sock_cmsg_send; no udp_cmsg_send).
 * IP_TTL (an int, 1..255) and IP_TOS (an int or one byte, 0..255) override the socket's values for that one datagram; IP_PKTINFO
 * (exactly a struct in_pktinfo) names the source address and the outgoing interface. A malformed message or an unknown IP-level type
 * is EINVAL; SOL_UDP, SOL_TCP and SCM_RIGHTS are skipped. The destination is checked first, the control messages before the ICMP
 * header is read. An IP_HDRINCL socket's header is not changed (IP_TTL / IP_TOS do nothing), IP_PKTINFO fills a zero source, and
 * any IP options, an empty IP_RETOPTS too, are EINVAL. Another raw ICMP socket (echo replies filtered out) watches what goes out.
 * Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   O. a plain datagram carries ttl 33 / tos 0x28 (the socket's); IP_TTL 7 gives 7; IP_TOS 0x4b (int) and 0x51 (one byte) give that
 *      tos; IP_TTL 9 with IP_TOS 0x60 gives both; the next plain one is back to 33 / 0x28; an empty IP_RETOPTS sends;
 *   E. EINVAL for: IP_TTL 0, 256, 1 byte; IP_TOS 256, -1, 2 bytes; IP level type 99; cmsg_len 12; cmsg_len past the end; SOL_SOCKET
 *      type 99; IP_PKTINFO of 16 bytes; nothing goes out;
 *   S. skipped: SOL_UDP UDP_SEGMENT of 4 bytes, SOL_TCP type 1, SCM_RIGHTS, an 8-byte buffer (each has 33 / 0x28);
 *   P. IP_PKTINFO spec_dst 127.0.0.5 sends from 127.0.0.5; ifindex 1 sends; ifindex 99 is ENODEV; spec_dst 192.0.2.1 is ENETUNREACH;
 *   H. IP_HDRINCL (IPPROTO_RAW) with a header of ttl 20, tos 0 and source 0: IP_TTL 7 / IP_TOS 0x4b leave 20 / 0; IP_PKTINFO spec_dst
 *      127.0.0.5 gives source 127.0.0.5; an empty IP_RETOPTS is EINVAL; a bad IP_TTL is EINVAL;
 *   D. no destination with a bad IP_TTL is EDESTADDRREQ; a 1-byte ICMP message with a bad IP_TTL is EINVAL, with a good one EFAULT. */
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
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void close_(long s) { close((int)s); }
static long sendmsg_(long s, long *m, int fl) { return rc(sendmsg((int)s, (struct msghdr *)m, fl)); }
static long recv_(long s, void *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void close_(long s) { syscall1(11, s); }
static long sendmsg_(long s, long *m, int fl) { return syscall3(46, s, (long)m, fl); }
static long recv_(long s, void *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[1600];
static void check(int ok, const char *w) {
    print(ok ? "hello426:   ok   " : "hello426:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
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
static unsigned short csum(const unsigned char *p, int n) {
    unsigned long s = 0;
    for (int i = 0; i + 1 < n; i += 2) s += (unsigned)(p[i] << 8 | p[i + 1]);
    if (n & 1) s += (unsigned)(p[n - 1] << 8);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (unsigned short)~s;
}
static unsigned char to[16];
static long tx, hdr, rx;
static int seq;
static unsigned char pkt[64];
/* An echo request at `p` (12 bytes) with a fresh sequence number. */
static void echo_at(unsigned char *p) {
    memset(p, 0, 12);
    p[0] = 8;
    seq++;
    p[6] = (unsigned char)(seq >> 8);
    p[7] = (unsigned char)seq;
    memcpy(p + 8, "ping", 4);
    unsigned short c = csum(p, 12);
    p[2] = (unsigned char)(c >> 8);
    p[3] = (unsigned char)c;
}
static long snd_raw(long s, const unsigned char *dst, long clen, const void *data, int n) {
    long iov[2] = { (long)data, n };
    long m[7] = { (long)dst, dst ? 16 : 0, (long)iov, 1, clen ? (long)cbuf : 0, clen, 0 };
    return sendmsg_(s, m, 0);
}
static long snd(long clen) {
    echo_at(pkt);
    return snd_raw(tx, to, clen, pkt, 12);
}
/* An IP_HDRINCL datagram: a 20-byte header (ttl 20, tos 0, source 0, destination 127.0.0.1) and an echo request. */
static long snd_hdr(long clen) {
    memset(pkt, 0, 20);
    pkt[0] = 0x45;
    pkt[3] = 32;
    pkt[8] = 20;
    pkt[9] = 1;
    pkt[16] = 127;
    pkt[19] = 1;
    echo_at(pkt + 20);
    return snd_raw(hdr, to, clen, pkt, 32);
}
static int r_ttl, r_tos, r_src;
/* The next echo request rx saw, without waiting: its ICMP length (-11 when none came), TTL, TOS and the last byte of its source in
 * r_ttl, r_tos, r_src. What tx itself received is drained. */
static long rcv(void) {
    for (int i = 0; i < 3; i++) nap();
    static unsigned char d[128];
    while (recv_(tx, d, sizeof d) >= 0) {}
    r_ttl = r_tos = r_src = -1;
    for (;;) {
        long r = recv_(rx, d, sizeof d);
        if (r < 0) return r;
        if (r < 28 || d[20] != 8) continue;
        r_ttl = d[8];
        r_tos = d[1];
        r_src = d[15];
        return r - 20;
    }
}
int main(void) {
    print("hello426: IPv4 raw socket sendmsg control messages\n");
    memset(to, 0, sizeof to);
    to[0] = 2;
    to[4] = 127;
    to[7] = 1;
    rx = sock(2, 3, 1);
    int mask = 1;
    long fm = setopt(rx, 255, 1, &mask, 4);
    tx = sock(2, 3, 1);
    hdr = sock(2, 3, 255);
    seti(tx, 0, 2, 33);
    seti(tx, 0, 1, 0x28);
    int v;
    unsigned char one;
    snprintf(msg, sizeof msg, "setup: rx %ld, ICMP_FILTER %ld, tx %ld, IPPROTO_RAW %ld (>=0, 0, >=0, >=0)", rx, fm, tx, hdr);
    check(rx >= 0 && fm == 0 && tx >= 0 && hdr >= 0, msg);

    long s0 = snd(0), g0 = rcv(); int t0 = r_ttl, q0 = r_tos;
    v = 7; long s1 = snd(put(0, 0, 2, &v, 4, 0)), g1 = rcv(); int t1 = r_ttl, q1 = r_tos;
    v = 0x4b; long s2 = snd(put(0, 0, 1, &v, 4, 0)), g2 = rcv(); int t2 = r_ttl, q2 = r_tos;
    one = 0x51; long s3 = snd(put(0, 0, 1, &one, 1, 0)), g3 = rcv(); int t3 = r_ttl, q3 = r_tos;
    v = 9; int o = put(0, 0, 2, &v, 4, 0); v = 0x60; o = put(o, 0, 1, &v, 4, 0);
    long s4 = snd(o), g4 = rcv(); int t4 = r_ttl, q4 = r_tos;
    long s5 = snd(0), g5 = rcv(); int t5 = r_ttl, q5 = r_tos;
    long s6 = snd(put(0, 0, 7, &v, 0, 0)), g6 = rcv(); int t6 = r_ttl;
    snprintf(msg, sizeof msg, "O: plain %ld/%ld %d 0x%x; ttl7 %ld/%ld %d 0x%x; tos 0x4b %ld/%ld %d 0x%x; 1-byte tos 0x51 %ld/%ld %d 0x%x; both %ld/%ld %d 0x%x; plain again %ld/%ld %d 0x%x; "
             "empty IP_RETOPTS %ld/%ld %d (12/12 33 0x28; 12/12 7 0x28; 12/12 33 0x4b; 12/12 33 0x51; 12/12 9 0x60; 12/12 33 0x28; 12/12 33)",
             s0, g0, t0, q0, s1, g1, t1, q1, s2, g2, t2, q2, s3, g3, t3, q3, s4, g4, t4, q4, s5, g5, t5, q5, s6, g6, t6);
    check(s0 == 12 && g0 == 12 && t0 == 33 && q0 == 0x28 && s1 == 12 && g1 == 12 && t1 == 7 && q1 == 0x28 && s2 == 12 && g2 == 12 && t2 == 33 &&
          q2 == 0x4b && s3 == 12 && g3 == 12 && t3 == 33 && q3 == 0x51 && s4 == 12 && g4 == 12 && t4 == 9 && q4 == 0x60 && s5 == 12 && g5 == 12 &&
          t5 == 33 && q5 == 0x28 && s6 == 12 && g6 == 12 && t6 == 33, msg);

    long e[11];
    unsigned char pi[12];
    v = 0; e[0] = snd(put(0, 0, 2, &v, 4, 0));
    v = 256; e[1] = snd(put(0, 0, 2, &v, 4, 0));
    one = 5; e[2] = snd(put(0, 0, 2, &one, 1, 0));
    v = 256; e[3] = snd(put(0, 0, 1, &v, 4, 0));
    v = -1; e[4] = snd(put(0, 0, 1, &v, 4, 0));
    v = 3; e[5] = snd(put(0, 0, 1, &v, 2, 0));
    v = 3; e[6] = snd(put(0, 0, 99, &v, 4, 0));
    v = 3; e[7] = snd(put(0, 0, 2, &v, 4, 12));
    v = 3; put(0, 0, 2, &v, 4, 64); e[8] = snd(24);
    v = 3; e[9] = snd(put(0, 1, 99, &v, 4, 0));
    memset(pi, 0, sizeof pi); e[10] = snd(put(0, 0, 8, pi, 12, 32));
    long ge = rcv();
    snprintf(msg, sizeof msg, "E: ttl 0 %ld, 256 %ld, 1 byte %ld; tos 256 %ld, -1 %ld, 2 bytes %ld; type 99 %ld; cmsg_len 12 %ld; past the end %ld; SOL_SOCKET 99 %ld; "
             "PKTINFO 16 bytes %ld; nothing sent %ld (all -22; -11)", e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9], e[10], ge);
    int eok = ge == -11;
    for (int i = 0; i < 11; i++) eok = eok && e[i] == -22;
    check(eok, msg);

    v = 3; long k0 = snd(put(0, 17, 103, &v, 4, 0)), h0 = rcv(); int kt0 = r_ttl, kq0 = r_tos;
    v = 3; long k1 = snd(put(0, 6, 1, &v, 4, 0)), h1 = rcv(); int kt1 = r_ttl, kq1 = r_tos;
    v = 3; long k2 = snd(put(0, 1, 1, &v, 4, 0)), h2 = rcv(); int kt2 = r_ttl, kq2 = r_tos;
    long k3 = snd(8), h3 = rcv(); int kt3 = r_ttl, kq3 = r_tos;
    snprintf(msg, sizeof msg, "S: SOL_UDP UDP_SEGMENT 4 bytes %ld/%ld %d 0x%x; SOL_TCP %ld/%ld %d 0x%x; SCM_RIGHTS %ld/%ld %d 0x%x; 8-byte buffer %ld/%ld %d 0x%x (12/12 33 0x28 each)",
             k0, h0, kt0, kq0, k1, h1, kt1, kq1, k2, h2, kt2, kq2, k3, h3, kt3, kq3);
    check(k0 == 12 && h0 == 12 && kt0 == 33 && kq0 == 0x28 && k1 == 12 && h1 == 12 && kt1 == 33 && kq1 == 0x28 && k2 == 12 && h2 == 12 && kt2 == 33 &&
          kq2 == 0x28 && k3 == 12 && h3 == 12 && kt3 == 33 && kq3 == 0x28, msg);

    memset(pi, 0, sizeof pi); pi[4] = 127; pi[7] = 5;
    long p0 = snd(put(0, 0, 8, pi, 12, 0)), j0 = rcv(); int f0 = r_src;
    memset(pi, 0, sizeof pi); pi[0] = 1;
    long p1 = snd(put(0, 0, 8, pi, 12, 0)), j1 = rcv(); int f1 = r_src;
    memset(pi, 0, sizeof pi); pi[0] = 99;
    long p2 = snd(put(0, 0, 8, pi, 12, 0));
    memset(pi, 0, sizeof pi); pi[4] = 192; pi[6] = 2; pi[7] = 1;
    long p3 = snd(put(0, 0, 8, pi, 12, 0));
    long j2 = rcv();
    snprintf(msg, sizeof msg, "P: spec_dst 127.0.0.5 %ld/%ld from .%d; ifindex 1 %ld/%ld from .%d; ifindex 99 %ld; spec_dst 192.0.2.1 %ld; then nothing %ld "
             "(12/12 .5; 12/12 .1; -19; -101; -11)", p0, j0, f0, p1, j1, f1, p2, p3, j2);
    check(p0 == 12 && j0 == 12 && f0 == 5 && p1 == 12 && j1 == 12 && f1 == 1 && p2 == -19 && p3 == -101 && j2 == -11, msg);

    v = 7; o = put(0, 0, 2, &v, 4, 0); v = 0x4b; o = put(o, 0, 1, &v, 4, 0);
    long x0 = snd_hdr(o), y0 = rcv(); int xt0 = r_ttl, xq0 = r_tos;
    memset(pi, 0, sizeof pi); pi[4] = 127; pi[7] = 5;
    long x1 = snd_hdr(put(0, 0, 8, pi, 12, 0)), y1 = rcv(); int xf1 = r_src;
    long x2 = snd_hdr(put(0, 0, 7, &v, 0, 0));
    v = 0; long x3 = snd_hdr(put(0, 0, 2, &v, 4, 0));
    long y2 = rcv();
    snprintf(msg, sizeof msg, "H: IP_HDRINCL with ttl 7 tos 0x4b %ld/%ld %d 0x%x; spec_dst 127.0.0.5 %ld/%ld from .%d; empty IP_RETOPTS %ld; bad ttl %ld; then nothing %ld "
             "(32/12 20 0x0; 32/12 .5; -22; -22; -11)", x0, y0, xt0, xq0, x1, y1, xf1, x2, x3, y2);
    check(x0 == 32 && y0 == 12 && xt0 == 20 && xq0 == 0 && x1 == 32 && y1 == 12 && xf1 == 5 && x2 == -22 && x3 == -22 && y2 == -11, msg);

    long un = sock(2, 3, 1);
    v = 0; echo_at(pkt); long dn = snd_raw(un, 0, put(0, 0, 2, &v, 4, 0), pkt, 12);
    v = 0; long sh0 = snd_raw(tx, to, put(0, 0, 2, &v, 4, 0), pkt, 1);
    v = 5; long sh1 = snd_raw(tx, to, put(0, 0, 2, &v, 4, 0), pkt, 1);
    snprintf(msg, sizeof msg, "D: no destination and a bad IP_TTL %ld; 1-byte message with a bad IP_TTL %ld, with a good one %ld (-89; -22; -14)", dn, sh0, sh1);
    check(dn == -89 && sh0 == -22 && sh1 == -14, msg);

    close_(un);
    close_(hdr);
    close_(tx);
    close_(rx);
    print(failures == 0 ? "hello426: PASS\n" : "hello426: FAIL\n");
    return failures == 0 ? 0 : 1;
}
