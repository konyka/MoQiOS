/* hello429: IPv6 ping socket sendmsg control messages (Linux ping_v6_sendmsg -> ip6_datagram_send_ctl, __sock_cmsg_send; no
 * udp_cmsg_send). The echo request carries the socket's IPV6_UNICAST_HOPS / IPV6_TCLASS; IPV6_HOPLIMIT (an int, -1..255; -1 keeps
 * the socket's value) and IPV6_TCLASS (an int, -1..255; -1 sends 0xff) override them for that one request. IPV6_PKTINFO is checked
 * (its interface must exist and be the one already chosen, its address must be ours) but ping_v6_sendmsg then takes the source from
 * the socket again. A malformed message or an unknown IPv6-level type is EINVAL; SOL_UDP, SOL_IP and SCM_RIGHTS are skipped.
 * A raw ICMPv6 socket with IPV6_RECVHOPLIMIT and IPV6_RECVTCLASS watches each request go out over lo.
 * Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   O. a plain request has hop limit 33 / tclass 0x28 (the socket's); IPV6_HOPLIMIT 7 gives 7, 0 gives 0, -1 keeps 33; IPV6_TCLASS
 *      0x4b gives 0x4b, -1 gives 0xff; both at once; the next plain one is back to 33 / 0x28;
 *   E. EINVAL for: hop limit 256, 1 byte; tclass 256; IPV6_DONTFRAG 2; IPv6 level type 99; cmsg_len 12; SOL_SOCKET type 99;
 *      IPV6_PKTINFO of 16 bytes; nothing goes out;
 *   S. skipped: SOL_UDP UDP_SEGMENT of 4 bytes, SOL_IP IP_TTL, SCM_RIGHTS, IPV6_DONTFRAG 1 (each has 33 / 0x28);
 *   P. IPV6_PKTINFO :: and ::1 send; interface 99 is ENODEV; 2001:db8::1 and ff02::1 are EINVAL;
 *   D. an unconnected ping socket without a destination and with a bad hop limit is EDESTADDRREQ.
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
static long recvmsg_(long s, long *m, int fl) { return rc(recvmsg((int)s, (struct msghdr *)m, fl)); }
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
static long recvmsg_(long s, long *m, int fl) { return syscall3(130, s, (long)m, fl); }
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
    print(ok ? "hello429:   ok   " : "hello429:   FAIL ");
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
static unsigned char to[28];
static long tx, raw;
static int seq;
static long snd_to(long s, const unsigned char *dst, long clen) {
    static unsigned char echo[12];
    memset(echo, 0, sizeof echo);
    echo[0] = 128;
    seq++;
    echo[6] = (unsigned char)(seq >> 8);
    echo[7] = (unsigned char)seq;
    memcpy(echo + 8, "ping", 4);
    long iov[2] = { (long)echo, 12 };
    long m[7] = { (long)dst, dst ? 28 : 0, (long)iov, 1, clen ? (long)cbuf : 0, clen, 0 };
    return sendmsg_(s, m, 0);
}
static long snd(long clen) { return snd_to(tx, to, clen); }
static int puti(int off, int ty, int v) { return put(off, 41, ty, &v, 4, 0); }
static int putpk(int off, const unsigned char *a, int ifx, int dl) {
    unsigned char p[24];
    memset(p, 0, sizeof p);
    memcpy(p, a, 16);
    memcpy(p + 16, &ifx, 4);
    return put(off, 41, 50, p, dl, 0);
}
static int r_hl, r_tc;
/* The next echo request the raw socket saw, without waiting: 1 when one came, its hop limit and traffic class in r_hl, r_tc. The
 * ping socket's replies are drained. */
static int rcv(void) {
    for (int i = 0; i < 3; i++) nap();
    static unsigned char d[128], c[128];
    while (recv_(tx, d, sizeof d) >= 0) {}
    r_hl = r_tc = -1;
    for (;;) {
        long iov[2] = { (long)d, sizeof d };
        long m[7] = { 0, 0, (long)iov, 1, (long)c, sizeof c, 0 };
        long r = recvmsg_(raw, m, 0x40);
        if (r < 0) return 0;
        if (r < 8 || d[0] != 128) continue;
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
        return 1;
    }
}
static long gs;
static int got(long clen, int hl, int tc) {
    gs = snd(clen);
    return gs == 12 && rcv() && r_hl == hl && r_tc == tc;
}
int main(void) {
    print("hello429: IPv6 ping socket sendmsg control messages\n");
    long opened = open_ping_range();
    memset(to, 0, sizeof to);
    to[0] = 10;
    to[23] = 1;
    raw = sock(10, 3, 58);
    long h1 = seti(raw, 41, 51, 1), h2 = seti(raw, 41, 66, 1);
    tx = sock(10, 2, 58);
    seti(tx, 41, 16, 33);
    seti(tx, 41, 67, 0x28);
    snprintf(msg, sizeof msg, "setup: range %ld, raw %ld, options %ld %ld, ping %ld (>0, >=0, 0 0, >=0)", opened, raw, h1, h2, tx);
    check(opened > 0 && raw >= 0 && h1 == 0 && h2 == 0 && tx >= 0, msg);

    int o0 = got(0, 33, 0x28), o1 = got(puti(0, 52, 7), 7, 0x28), o2 = got(puti(0, 52, 0), 0, 0x28), o3 = got(puti(0, 52, -1), 33, 0x28);
    int o4 = got(puti(0, 67, 0x4b), 33, 0x4b), o5 = got(puti(0, 67, -1), 33, 0xff), o6 = got(puti(puti(0, 52, 9), 67, 0x60), 9, 0x60);
    int o7 = got(0, 33, 0x28);
    snprintf(msg, sizeof msg, "O: plain %d, hl 7 %d, hl 0 %d, hl -1 %d, tc 0x4b %d, tc -1 %d, both %d, plain again %d (all 1)", o0, o1, o2, o3, o4, o5, o6, o7);
    check(o0 && o1 && o2 && o3 && o4 && o5 && o6 && o7, msg);

    long e[9];
    unsigned char one = 5, z[16];
    memset(z, 0, sizeof z);
    int v = 3;
    e[0] = snd(puti(0, 52, 256));
    e[1] = snd(put(0, 41, 52, &one, 1, 0));
    e[2] = snd(puti(0, 67, 256));
    e[3] = snd(puti(0, 62, 2));
    e[4] = snd(puti(0, 99, 3));
    e[5] = snd(put(0, 41, 52, &v, 4, 12));
    e[6] = snd(put(0, 1, 99, &v, 4, 0));
    e[7] = snd(put(0, 41, 50, z, 16, 0));
    e[8] = rcv();
    snprintf(msg, sizeof msg, "E: hl 256 %ld, 1 byte %ld; tc 256 %ld; dontfrag 2 %ld; type 99 %ld; cmsg_len 12 %ld; SOL_SOCKET 99 %ld; PKTINFO 16 bytes %ld; "
             "anything sent %ld (all -22; 0)", e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8]);
    int eok = e[8] == 0;
    for (int i = 0; i < 8; i++) eok = eok && e[i] == -22;
    check(eok, msg);

    int s0 = got(put(0, 17, 103, &v, 4, 0), 33, 0x28), s1 = got(put(0, 0, 2, &v, 4, 0), 33, 0x28), s2 = got(put(0, 1, 1, &v, 4, 0), 33, 0x28);
    int s3 = got(puti(0, 62, 1), 33, 0x28);
    snprintf(msg, sizeof msg, "S: SOL_UDP UDP_SEGMENT 4 bytes %d, SOL_IP IP_TTL %d, SCM_RIGHTS %d, dontfrag 1 %d (all 1)", s0, s1, s2, s3);
    check(s0 && s1 && s2 && s3, msg);

    unsigned char lo6[16], doc[16], grp[16];
    memset(lo6, 0, 16); lo6[15] = 1;
    memset(doc, 0, 16); doc[0] = 0x20; doc[1] = 0x01; doc[2] = 0x0d; doc[3] = 0xb8; doc[15] = 1;
    memset(grp, 0, 16); grp[0] = 0xff; grp[1] = 0x02; grp[15] = 1;
    int p0 = got(putpk(0, z, 0, 20), 33, 0x28), p1 = got(putpk(0, lo6, 0, 20), 33, 0x28);
    long q0 = snd(putpk(0, z, 99, 20)), q1 = snd(putpk(0, doc, 0, 20)), q2 = snd(putpk(0, grp, 0, 20));
    int q3 = rcv();
    snprintf(msg, sizeof msg, "P: :: %d, ::1 %d; if99 %ld, 2001:db8::1 %ld, ff02::1 %ld; anything sent %d (1 1; -19 -22 -22; 0)", p0, p1, q0, q1, q2, q3);
    check(p0 && p1 && q0 == -19 && q1 == -22 && q2 == -22 && q3 == 0, msg);

    long un = sock(10, 2, 58);
    long dn = snd_to(un, 0, puti(0, 52, 256));
    snprintf(msg, sizeof msg, "D: no destination and a bad hop limit: %ld (-89)", dn);
    check(dn == -89, msg);

    close_(un);
    close_(tx);
    close_(raw);
    restore_ping_range();
    print(failures == 0 ? "hello429: PASS\n" : "hello429: FAIL\n");
    return failures == 0 ? 0 : 1;
}
