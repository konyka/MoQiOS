/* hello425: IPv4 ping socket sendmsg control messages (Linux ping_v4_sendmsg -> ip_cmsg_send, __sock_cmsg_send; no udp_cmsg_send).
 * The echo request carries the socket's IP_TTL / IP_TOS; IP_TTL (an int, 1..255) and IP_TOS (an int or one byte, 0..255) override
 * them for that one request; IP_PKTINFO (exactly a struct in_pktinfo) names the source address and the outgoing interface. A
 * malformed message or an unknown IP-level type is EINVAL; SOL_UDP (a UDP socket would reject UDP_SEGMENT of 4 bytes), SOL_TCP and
 * SCM_RIGHTS are skipped. Destination errors come first. A raw ICMP socket sees each request as it goes out over lo.
 * Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   O. a plain request carries ttl 33 / tos 0x28 (the socket's); IP_TTL 7 gives 7; IP_TOS 0x4b (int) and 0x51 (one byte) give that
 *      tos; IP_TTL 9 with IP_TOS 0x60 gives both; the next plain request is back to 33 / 0x28;
 *   E. EINVAL for: IP_TTL 0, 256, 1 byte; IP_TOS 256, -1, 2 bytes; IP level type 99; cmsg_len 12; cmsg_len past the end; SOL_SOCKET
 *      type 99; IP_PKTINFO of 16 bytes; no request goes out;
 *   S. skipped: SOL_UDP UDP_SEGMENT of 4 bytes, SOL_TCP type 1, SCM_RIGHTS, an 8-byte buffer (each request has 33 / 0x28);
 *   P. IP_PKTINFO spec_dst 127.0.0.5 sends from 127.0.0.5; ifindex 1 sends; ifindex 99 is ENODEV; spec_dst 192.0.2.1 is ENETUNREACH;
 *   D. an unconnected ping socket without a destination and with a bad IP_TTL is EDESTADDRREQ.
 * The test opens net.ipv4.ping_group_range to group 0 itself and puts the old range back. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
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
static long range_fd(int wr) { return rc(open("/proc/sys/net/ipv4/ping_group_range", wr ? O_WRONLY : O_RDONLY)); }
static long range_io(long fd, char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n)); }
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
static long range_fd(int wr) { return syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", wr ? 1 : 0, 0); }
static long range_io(long fd, char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
#endif
static char range_saved[48];
static long open_ping_range(void) {
    long fd = range_fd(0);
    if (fd < 0) return fd;
    long n = range_io(fd, range_saved, sizeof range_saved - 1, 0);
    close_(fd);
    if (n <= 0) return -1;
    range_saved[n] = 0;
    fd = range_fd(1);
    if (fd < 0) return fd;
    char zero[] = "0 0";
    long w = range_io(fd, zero, 3, 1);
    close_(fd);
    return w;
}
static void restore_ping_range(void) {
    long fd = range_fd(1);
    if (fd < 0) return;
    int n = 0;
    while (range_saved[n] && range_saved[n] != '\n') n++;
    range_io(fd, range_saved, n, 1);
    close_(fd);
}
static int failures;
static char msg[1600];
static void check(int ok, const char *w) {
    print(ok ? "hello425:   ok   " : "hello425:   FAIL ");
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
static unsigned char to[16];
static long tx, raw;
static int seq;
static long snd_to(long s, const unsigned char *dst, long clen) {
    static unsigned char echo[12];
    memset(echo, 0, sizeof echo);
    echo[0] = 8;
    seq++;
    echo[6] = (unsigned char)(seq >> 8);
    echo[7] = (unsigned char)seq;
    memcpy(echo + 8, "ping", 4);
    long iov[2] = { (long)echo, 12 };
    long m[7] = { (long)dst, dst ? 16 : 0, (long)iov, 1, clen ? (long)cbuf : 0, clen, 0 };
    return sendmsg_(s, m, 0);
}
static long snd(long clen) { return snd_to(tx, to, clen); }
static int r_ttl, r_tos, r_src;
/* The next echo request the raw socket saw, without waiting: its length (-11 when none came), TTL, TOS and the last byte of its
 * source in r_ttl, r_tos, r_src. The ping socket's replies are drained. */
static long rcv(void) {
    for (int i = 0; i < 3; i++) nap();
    static unsigned char d[128];
    while (recv_(tx, d, sizeof d) >= 0) {}
    r_ttl = r_tos = r_src = -1;
    for (;;) {
        long r = recv_(raw, d, sizeof d);
        if (r < 0) return r;
        if (r < 28 || d[20] != 8) continue;
        r_ttl = d[8];
        r_tos = d[1];
        r_src = d[15];
        return r - 20;
    }
}
int main(void) {
    print("hello425: IPv4 ping socket sendmsg control messages\n");
    long opened = open_ping_range();
    memset(to, 0, sizeof to);
    to[0] = 2;
    to[4] = 127;
    to[7] = 1;
    raw = sock(2, 3, 1);
    int mask = 1;
    long fm = setopt(raw, 255, 1, &mask, 4);
    tx = sock(2, 2, 1);
    seti(tx, 0, 2, 33);
    seti(tx, 0, 1, 0x28);
    int v;
    unsigned char one;
    snprintf(msg, sizeof msg, "setup: range %ld, raw %ld, ICMP_FILTER %ld, ping %ld (>0, >=0, 0, >=0)", opened, raw, fm, tx);
    check(opened > 0 && raw >= 0 && fm == 0 && tx >= 0, msg);

    long s0 = snd(0), g0 = rcv(); int t0 = r_ttl, q0 = r_tos;
    v = 7; long s1 = snd(put(0, 0, 2, &v, 4, 0)), g1 = rcv(); int t1 = r_ttl, q1 = r_tos;
    v = 0x4b; long s2 = snd(put(0, 0, 1, &v, 4, 0)), g2 = rcv(); int t2 = r_ttl, q2 = r_tos;
    one = 0x51; long s3 = snd(put(0, 0, 1, &one, 1, 0)), g3 = rcv(); int t3 = r_ttl, q3 = r_tos;
    v = 9; int o = put(0, 0, 2, &v, 4, 0); v = 0x60; o = put(o, 0, 1, &v, 4, 0);
    long s4 = snd(o), g4 = rcv(); int t4 = r_ttl, q4 = r_tos;
    long s5 = snd(0), g5 = rcv(); int t5 = r_ttl, q5 = r_tos;
    snprintf(msg, sizeof msg, "O: plain %ld/%ld %d 0x%x; ttl7 %ld/%ld %d 0x%x; tos 0x4b %ld/%ld %d 0x%x; 1-byte tos 0x51 %ld/%ld %d 0x%x; both %ld/%ld %d 0x%x; plain again %ld/%ld %d 0x%x "
             "(12/12 33 0x28; 12/12 7 0x28; 12/12 33 0x4b; 12/12 33 0x51; 12/12 9 0x60; 12/12 33 0x28)",
             s0, g0, t0, q0, s1, g1, t1, q1, s2, g2, t2, q2, s3, g3, t3, q3, s4, g4, t4, q4, s5, g5, t5, q5);
    check(s0 == 12 && g0 == 12 && t0 == 33 && q0 == 0x28 && s1 == 12 && g1 == 12 && t1 == 7 && q1 == 0x28 && s2 == 12 && g2 == 12 && t2 == 33 &&
          q2 == 0x4b && s3 == 12 && g3 == 12 && t3 == 33 && q3 == 0x51 && s4 == 12 && g4 == 12 && t4 == 9 && q4 == 0x60 && s5 == 12 && g5 == 12 &&
          t5 == 33 && q5 == 0x28, msg);

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

    long un = sock(2, 2, 1);
    v = 0; long dn = snd_to(un, 0, put(0, 0, 2, &v, 4, 0));
    snprintf(msg, sizeof msg, "D: no destination and a bad IP_TTL: %ld (-89)", dn);
    check(dn == -89, msg);

    close_(un);
    close_(tx);
    close_(raw);
    restore_ping_range();
    print(failures == 0 ? "hello425: PASS\n" : "hello425: FAIL\n");
    return failures == 0 ? 0 : 1;
}
