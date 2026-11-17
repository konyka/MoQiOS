/* hello395: a raw ICMP socket takes the IP-level options and its sends carry them (Linux raw_setsockopt / rawv6_setsockopt hand
 * SOL_IP / SOL_IPV6 to ip_setsockopt / ipv6_setsockopt; raw_sendmsg builds the header with the socket's TTL and TOS). Measured on
 * the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   T. IP_TTL reads 64 by default, 7 once set; an echo request sent to 127.0.0.1 comes back to the socket with TTL 7 (byte 8);
 *   Q. IP_TOS 0x10 reads back, and the request's TOS byte is 0x10;
 *   E. IP_TTL 0 and 256 are EINVAL; -1 puts 64 back;
 *   L. SOL_IPV6 on the IPv4 raw socket: getsockopt is EOPNOTSUPP (ip_getsockopt), setsockopt ENOPROTOOPT (ip_setsockopt);
 *   D. a dup reads the TTL the original set;
 *   H. IPV6_UNICAST_HOPS on an IPv6 raw ICMPv6 socket reads 64 by default, 9 once set, and an echo request to ::1 still goes out;
 *   C. IPV6_TCLASS 0x20 reads back;
 *   S. SOL_IP on the IPv6 raw socket is ENOPROTOOPT. */
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
static long rsock4(void) { return rc(socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)); }
static long rsock6(void) { return rc(socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)); }
static long setopt(long s, int lvl, int name, const void *v, int n) { return rc(setsockopt((int)s, lvl, name, v, (socklen_t)n)); }
static long getopt_(long s, int lvl, int name, void *v, int *n) { socklen_t l = (socklen_t)*n; long r = rc(getsockopt((int)s, lvl, name, v, &l)); *n = (int)l; return r; }
static long recv_(long s, void *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long sendto_(long s, const void *b, int n, const void *to, int tl) { return rc(sendto((int)s, b, n, 0, to, (socklen_t)tl)); }
static long dup_(long s) { return rc(dup((int)s)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rsock4(void) { return syscall3(117, 2, 3, 1); }
static long rsock6(void) { return syscall3(117, 10, 3, 58); }
static long setopt(long s, int lvl, int name, const void *v, int n) { return syscall5(132, s, lvl, name, (long)v, n); }
static long getopt_(long s, int lvl, int name, void *v, int *n) { return syscall5(133, s, lvl, name, (long)v, (long)n); }
static long recv_(long s, void *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long sendto_(long s, const void *b, int n, const void *to, int tl) { return syscall6(121, s, (long)b, n, 0, (long)to, tl); }
static long dup_(long s) { return syscall1(160, s); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[700];
static unsigned char buf[2048];
static void check(int ok, const char *w) {
    print(ok ? "hello395:   ok   " : "hello395:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long seti(long s, int lvl, int name, int v) { return setopt(s, lvl, name, &v, 4); }
static long geti(long s, int lvl, int name) { int v = -1, n = 4; long r = getopt_(s, lvl, name, &v, &n); return r < 0 ? r : v; }
static void drain(long s) { while (recv_(s, buf, sizeof buf) >= 0) {} }
/* Send an echo request with id `id` to 127.0.0.1 and return the first queued datagram that is that request (type 8, IP header
   included), or -1: buf holds it. */
static long echo4(long s, int id) {
    unsigned char to[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
    unsigned char e[8] = { 8, 0, 0, 0, (unsigned char)(id >> 8), (unsigned char)id, 0, 1 };
    unsigned int sum = 0;
    for (int i = 0; i < 8; i += 2) sum += (unsigned int)(e[i] << 8 | e[i + 1]);
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    sum = ~sum & 0xffff;
    e[2] = (unsigned char)(sum >> 8);
    e[3] = (unsigned char)sum;
    if (sendto_(s, e, 8, to, 16) != 8) return -1;
    nap();
    for (int i = 0; i < 8; i++) {
        long n = recv_(s, buf, sizeof buf);
        if (n < 0) return -1;
        int ihl = (buf[0] & 15) * 4;
        if (n >= ihl + 8 && buf[ihl] == 8 && buf[ihl + 4] == (unsigned char)(id >> 8) && buf[ihl + 5] == (unsigned char)id) return n;
    }
    return -1;
}
int main(void) {
    print("hello395: a raw ICMP socket takes IP-level options and its sends carry them\n");
    long s = rsock4();
    long t0 = geti(s, 0, 2);
    long st = seti(s, 0, 2, 7);
    long t1 = geti(s, 0, 2);
    drain(s);
    long n = echo4(s, 0x3951);
    int ttl = n > 0 ? buf[8] : -1;
    snprintf(msg, sizeof msg, "T: socket %ld, IP_TTL %ld (64), set %ld, reads %ld (7); the request came back (%ld) with TTL %d (7)", s, t0, st, t1, n, ttl);
    check(s >= 0 && t0 == 64 && st == 0 && t1 == 7 && n >= 28 && ttl == 7, msg);

    long sq = seti(s, 0, 1, 0x10);
    long q = geti(s, 0, 1);
    drain(s);
    n = echo4(s, 0x3952);
    int tos = n > 0 ? buf[1] : -1;
    snprintf(msg, sizeof msg, "Q: IP_TOS set %ld, reads 0x%lx (0x10); the request's TOS 0x%x (0x10)", sq, q, tos);
    check(sq == 0 && q == 0x10 && tos == 0x10, msg);

    long e0 = seti(s, 0, 2, 0), e1 = seti(s, 0, 2, 256), e2 = seti(s, 0, 2, -1);
    long td = geti(s, 0, 2);
    snprintf(msg, sizeof msg, "E: IP_TTL 0 -> %ld, 256 -> %ld (-22 each); -1 -> %ld, reads %ld (64)", e0, e1, e2, td);
    check(e0 == -22 && e1 == -22 && e2 == 0 && td == 64, msg);

    long l6 = geti(s, 41, 16);
    long ls6 = seti(s, 41, 16, 5);
    snprintf(msg, sizeof msg, "L: SOL_IPV6 IPV6_UNICAST_HOPS on the IPv4 raw socket: get %ld (-95), set %ld (-92)", l6, ls6);
    check(l6 == -95 && ls6 == -92, msg);

    seti(s, 0, 2, 33);
    long d = dup_(s);
    long dt = geti(d, 0, 2);
    snprintf(msg, sizeof msg, "D: dup %ld reads IP_TTL %ld (33)", d, dt);
    check(d >= 0 && dt == 33, msg);
    close_(d);
    close_(s);

    long s6 = rsock6();
    long h0 = geti(s6, 41, 16);
    long sh = seti(s6, 41, 16, 9);
    long h1 = geti(s6, 41, 16);
    unsigned char lo6[28] = { 10, 0 };
    lo6[23] = 1;
    unsigned char e6[8] = { 128, 0, 0, 0, 0x39, 0x56, 0, 1 };
    drain(s6);
    long sent = sendto_(s6, e6, 8, lo6, 28);
    nap();
    int seen = 0;
    for (int i = 0; i < 16 && !seen; i++) {
        long m = recv_(s6, buf, sizeof buf);
        if (m < 0) break;
        if (m >= 8 && buf[0] == 128 && buf[4] == 0x39 && buf[5] == 0x56) seen = 1;
    }
    snprintf(msg, sizeof msg, "H: socket %ld, IPV6_UNICAST_HOPS %ld (64), set %ld, reads %ld (9); send %ld (8), request seen %d", s6, h0, sh, h1, sent, seen);
    check(s6 >= 0 && h0 == 64 && sh == 0 && h1 == 9 && sent == 8 && seen, msg);

    long sc = seti(s6, 41, 67, 0x20);
    long c = geti(s6, 41, 67);
    snprintf(msg, sizeof msg, "C: IPV6_TCLASS set %ld, reads 0x%lx (0x20)", sc, c);
    check(sc == 0 && c == 0x20, msg);

    long s4g = geti(s6, 0, 2);
    long s4s = seti(s6, 0, 2, 5);
    snprintf(msg, sizeof msg, "S: SOL_IP IP_TTL on the IPv6 raw socket: get %ld, set %ld (-92 each)", s4g, s4s);
    check(s4g == -92 && s4s == -92, msg);
    close_(s6);

    print(failures == 0 ? "hello395: PASS\n" : "hello395: FAIL\n");
    return failures == 0 ? 0 : 1;
}
