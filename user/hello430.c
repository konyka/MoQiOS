/* hello430: ping socket recvmsg control messages (Linux ping_recvmsg -> ip_cmsg_recv for IPv4, ip6_datagram_recv_common_ctl and
 * ip6_datagram_recv_specific_ctl for IPv6). An echo reply received on an IPv4 ping socket with IP_PKTINFO, IP_RECVTTL and
 * IP_RECVTOS carries struct in_pktinfo, the TTL as an int and the TOS as one byte; an IPv6 ping socket with IPV6_RECVPKTINFO,
 * IPV6_RECVHOPLIMIT and IPV6_RECVTCLASS gets struct in6_pktinfo, the hop limit and the traffic class as ints. The reply keeps
 * the request's TOS / traffic class (icmp_reply: ipc.tos = ip_hdr(skb)->tos; icmpv6_echo_reply: ipv6_get_dsfield). Without the
 * options msg_controllen is 0; a buffer too small for a message sets MSG_CTRUNC.
 * Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   A. a request with IP_TOS 0x28 to 127.0.0.1: the reply has pktinfo ifindex 1, spec_dst 0.0.0.0 (the ping path never runs
 *      ipv4_pktinfo_prepare), addr 127.0.0.1, ttl 64, tos 0x28 (controllen 80);
 *   B. without the options controllen is 0;
 *   C. with only IP_RECVTTL and a 16-byte control buffer: controllen 16, MSG_CTRUNC;
 *   D. an ICMPv6 request with IPV6_TCLASS 0x28 to ::1: pktinfo ::1 on interface 1, hop limit 64, tclass 0x28 (controllen 88);
 *      without the options controllen 0.
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
static long sendto_(long s, const void *b, int n, const void *to, int tl) { return rc(sendto((int)s, b, n, 0, to, (socklen_t)tl)); }
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
static long sendto_(long s, const void *b, int n, const void *to, int tl) { return syscall6(121, s, (long)b, n, 0, (long)to, tl); }
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
static char msg[800];
static void check(int ok, const char *w) {
    print(ok ? "hello430:   ok   " : "hello430:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static unsigned char ctl[256];
static long clen, mflags;
/* The next message on `s` whose ICMP(v6) type is `ty`, without waiting: its length, or -11. The control buffer gets `cap` bytes;
 * clen and mflags hold what came back. */
static long rcv(long s, int ty, int cap) {
    for (int i = 0; i < 3; i++) nap();
    static unsigned char d[256];
    for (;;) {
        long iov[2] = { (long)d, sizeof d };
        long m[7] = { 0, 0, (long)iov, 1, cap ? (long)ctl : 0, cap, 0 };
        memset(ctl, 0xee, sizeof ctl);
        long r = recvmsg_(s, m, 0x40);
        if (r < 0) return r;
        clen = m[5];
        mflags = (long)(unsigned)(m[6] & 0xffffffff);
        if (r > 0 && d[0] == ty) return r;
    }
}
/* The data of the control message of `lv`/`ty` in ctl[0..clen], or 0. */
static unsigned char *find(int lv, int ty) {
    for (long off = 0; off + 16 <= clen;) {
        long l = 0;
        int a = 0, b = 0;
        memcpy(&l, ctl + off, 8);
        memcpy(&a, ctl + off + 8, 4);
        memcpy(&b, ctl + off + 12, 4);
        if (a == lv && b == ty) return ctl + off + 16;
        if (l < 16) break;
        off += (l + 7) & ~7L;
    }
    return 0;
}
static unsigned char echo[12] = { 8, 0, 0, 0, 0, 0, 0, 1, 'p', 'i', 'n', 'g' };
static unsigned char echo6[12] = { 128, 0, 0, 0, 0, 0, 0, 1, 'p', 'i', 'n', 'g' };
int main(void) {
    print("hello430: ping socket recvmsg control messages\n");
    long orc = open_ping_range();
    unsigned char to[16], to6[28];
    memset(to, 0, sizeof to);
    to[0] = 2;
    to[4] = 127;
    to[7] = 1;
    memset(to6, 0, sizeof to6);
    to6[0] = 10;
    to6[23] = 1;
    long rx = sock(2, 2, 1), plain = sock(2, 2, 1);
    snprintf(msg, sizeof msg, "setup: ping_group_range %ld, sockets %ld %ld (>=0)", orc, rx, plain);
    check(orc >= 0 && rx >= 0 && plain >= 0, msg);
    seti(rx, 0, 1, 0x28);
    long o1 = seti(rx, 0, 8, 1), o2 = seti(rx, 0, 12, 1), o3 = seti(rx, 0, 13, 1);
    long s = sendto_(rx, echo, 12, to, 16);
    long g = rcv(rx, 0, 256);
    long ga = clen;
    unsigned char *pi = find(0, 8), *tt = find(0, 2), *ts = find(0, 1);
    int ifx = -1, ttl = -1, tos = -1, sd = -1, ad = -1;
    if (pi) { memcpy(&ifx, pi, 4); sd = !pi[4] && !pi[5] && !pi[6] && !pi[7]; ad = pi[8] == 127 && pi[11] == 1; }
    if (tt) memcpy(&ttl, tt, 4);
    if (ts) tos = ts[0];
    snprintf(msg, sizeof msg, "A: options %ld %ld %ld; send %ld, got %ld, controllen %ld; pktinfo ifindex %d spec_dst 0.0.0.0 %d addr %d; ttl %d; tos 0x%x "
             "(0 0 0; 12, 12, 80; 1 1 1; 64; 0x28)", o1, o2, o3, s, g, ga, ifx, sd, ad, ttl, tos);
    check(o1 == 0 && o2 == 0 && o3 == 0 && s == 12 && g == 12 && ga == 80 && ifx == 1 && sd == 1 && ad == 1 && ttl == 64 && tos == 0x28, msg);

    long sb = sendto_(plain, echo, 12, to, 16);
    long gb = rcv(plain, 0, 256), cb = clen;
    snprintf(msg, sizeof msg, "B: without the options: send %ld, got %ld, controllen %ld (12, 12, 0)", sb, gb, cb);
    check(sb == 12 && gb == 12 && cb == 0, msg);

    seti(rx, 0, 8, 0);
    seti(rx, 0, 13, 0);
    sendto_(rx, echo, 12, to, 16);
    long gc = rcv(rx, 0, 16), cc = clen, fc = mflags;
    long cl = 0;
    memcpy(&cl, ctl, 8);
    snprintf(msg, sizeof msg, "C: IP_RECVTTL into 16 bytes: got %ld, controllen %ld, cmsg_len %ld, MSG_CTRUNC %d (12, 16, 16, 1)", gc, cc, cl, (fc & 8) != 0);
    check(gc == 12 && cc == 16 && cl == 16 && (fc & 8) != 0, msg);

    long rx6 = sock(10, 2, 58), plain6 = sock(10, 2, 58);
    seti(rx6, 41, 67, 0x28);
    long p1 = seti(rx6, 41, 49, 1), p2 = seti(rx6, 41, 51, 1), p3 = seti(rx6, 41, 66, 1);
    long s6 = sendto_(rx6, echo6, 12, to6, 28);
    long g6 = rcv(rx6, 129, 256), c6 = clen;
    unsigned char *pi6 = find(41, 50), *hl6 = find(41, 52), *tc6 = find(41, 67);
    int ifx6 = -1, hl = -1, tc = -1, lo = -1;
    if (pi6) {
        memcpy(&ifx6, pi6 + 16, 4);
        lo = pi6[15] == 1;
        for (int i = 0; i < 15; i++) if (pi6[i]) lo = 0;
    }
    if (hl6) memcpy(&hl, hl6, 4);
    if (tc6) memcpy(&tc, tc6, 4);
    long sp6 = sendto_(plain6, echo6, 12, to6, 28);
    long gp6 = rcv(plain6, 129, 256), cp6 = clen;
    snprintf(msg, sizeof msg, "D: sockets %ld %ld; options %ld %ld %ld; send %ld, got %ld, controllen %ld; pktinfo ::1 %d ifindex %d; hop limit %d; tclass 0x%x; "
             "without the options send %ld got %ld controllen %ld (0 0 0; 12, 12, 88; 1 1; 64; 0x28; 12 12 0)", rx6, plain6, p1, p2, p3, s6, g6, c6, lo, ifx6, hl, tc, sp6, gp6, cp6);
    check(rx6 >= 0 && plain6 >= 0 && p1 == 0 && p2 == 0 && p3 == 0 && s6 == 12 && g6 == 12 && c6 == 88 && lo == 1 && ifx6 == 1 && hl == 64 && tc == 0x28 &&
              sp6 == 12 && gp6 == 12 && cp6 == 0, msg);

    close_(rx);
    close_(plain);
    close_(rx6);
    close_(plain6);
    restore_ping_range();
    print(failures == 0 ? "hello430: PASS\n" : "hello430: FAIL\n");
    return failures == 0 ? 0 : 1;
}
