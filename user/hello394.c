/* hello394: a raw ICMP socket keeps its SOL_SOCKET options, and a blocking receive gives up with EAGAIN once SO_RCVTIMEO runs out
 * (Linux raw_recvmsg / rawv6_recvmsg wait in skb_recv_datagram with sock_rcvtimeo). Measured on the host (build with -DHOST, run as
 * root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   T. SO_RCVTIMEO of 100 ms on an IPv4 raw socket: a blocking recv on an empty queue returns EAGAIN (-11) after about 100 ms;
 *   G. getsockopt reads the 100 ms back (0 s, 100000 us);
 *   S. SO_SNDTIMEO of 2.5 s reads back as 2 s, 500000 us;
 *   B. SO_RCVBUF of 4096 reads back doubled, 8192;
 *   D. a dup of the socket sees the same SO_RCVTIMEO, and its blocking recv times out too;
 *   R. with the timeout set, a datagram already queued (an echo request sent to 127.0.0.1) is delivered at once;
 *   6. the same timeout on an IPv6 raw ICMPv6 socket: EAGAIN after about 100 ms, and the value reads back. */
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
static long setopt(long s, int name, const void *v, int n) { return rc(setsockopt((int)s, SOL_SOCKET, name, v, (socklen_t)n)); }
static long getopt_(long s, int name, void *v, int *n) { socklen_t l = (socklen_t)*n; long r = rc(getsockopt((int)s, SOL_SOCKET, name, v, &l)); *n = (int)l; return r; }
static long recv_(long s, void *b, int n) { return rc(recv((int)s, b, n, 0)); }
static long sendto_(long s, const void *b, int n, const void *to, int tl) { return rc(sendto((int)s, b, n, 0, to, (socklen_t)tl)); }
static long dup_(long s) { return rc(dup((int)s)); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rsock4(void) { return syscall3(117, 2, 3, 1); }
static long rsock6(void) { return syscall3(117, 10, 3, 58); }
static long setopt(long s, int name, const void *v, int n) { return syscall5(132, s, 1, name, (long)v, n); }
static long getopt_(long s, int name, void *v, int *n) { return syscall5(133, s, 1, name, (long)v, (long)n); }
static long recv_(long s, void *b, int n) { return syscall6(122, s, (long)b, n, 0, 0, 0); }
static long sendto_(long s, const void *b, int n, const void *to, int tl) { return syscall6(121, s, (long)b, n, 0, (long)to, tl); }
static long dup_(long s) { return syscall1(160, s); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[700];
static unsigned char buf[2048];
static void check(int ok, const char *w) {
    print(ok ? "hello394:   ok   " : "hello394:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long set_tv(long s, int name, long sec, long usec) { long tv[2] = { sec, usec }; return setopt(s, name, tv, 16); }
static long get_tv(long s, int name, long *sec, long *usec) {
    long tv[2] = { -1, -1 };
    int n = 16;
    long r = getopt_(s, name, tv, &n);
    *sec = tv[0];
    *usec = tv[1];
    return r < 0 ? r : n;
}
/* How long a blocking recv on `s` took, in ms; its result goes to *r. */
static long timed_recv(long s, long *r) {
    long t0 = now_ms();
    *r = recv_(s, buf, sizeof buf);
    return now_ms() - t0;
}
static int near_100(long ms) { return ms >= 80 && ms < 1000; }
int main(void) {
    print("hello394: a raw ICMP socket keeps SO_RCVTIMEO and its blocking receive times out\n");
    long s = rsock4();
    long st = set_tv(s, 20, 0, 100000);
    long r;
    long ms = timed_recv(s, &r);
    snprintf(msg, sizeof msg, "T: socket %ld, setsockopt %ld; recv %ld (-11) after %ld ms (about 100)", s, st, r, ms);
    check(s >= 0 && st == 0 && r == -11 && near_100(ms), msg);

    long sec, usec;
    long g = get_tv(s, 20, &sec, &usec);
    snprintf(msg, sizeof msg, "G: getsockopt %ld (16): %ld s, %ld us (0, 100000)", g, sec, usec);
    check(g == 16 && sec == 0 && usec == 100000, msg);

    long ss = set_tv(s, 21, 2, 500000);
    long gs = get_tv(s, 21, &sec, &usec);
    snprintf(msg, sizeof msg, "S: SO_SNDTIMEO set %ld, get %ld: %ld s, %ld us (2, 500000)", ss, gs, sec, usec);
    check(ss == 0 && gs == 16 && sec == 2 && usec == 500000, msg);

    int v = 4096, got = -1, n = 4;
    long sb = setopt(s, 8, &v, 4);
    long gb = getopt_(s, 8, &got, &n);
    snprintf(msg, sizeof msg, "B: SO_RCVBUF 4096 set %ld, get %ld: %d (8192)", sb, gb, got);
    check(sb == 0 && gb == 0 && got == 8192, msg);

    long d = dup_(s);
    long gd = get_tv(d, 20, &sec, &usec);
    long rd;
    long msd = timed_recv(d, &rd);
    snprintf(msg, sizeof msg, "D: dup %ld reads %ld s, %ld us (0, 100000); its recv %ld (-11) after %ld ms", d, sec, usec, rd, msd);
    check(d >= 0 && gd == 16 && sec == 0 && usec == 100000 && rd == -11 && near_100(msd), msg);
    close_(d);

    unsigned char to[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
    unsigned char echo[8] = { 8, 0, 0, 0, 0x12, 0x34, 0, 1 };
    unsigned int sum = 0;
    for (int i = 0; i < 8; i += 2) sum += (unsigned int)(echo[i] << 8 | echo[i + 1]);
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    sum = ~sum & 0xffff;
    echo[2] = (unsigned char)(sum >> 8);
    echo[3] = (unsigned char)sum;
    long sent = sendto_(s, echo, 8, to, 16);
    long rr;
    long msr = timed_recv(s, &rr);
    snprintf(msg, sizeof msg, "R: sent %ld (8); queued datagram delivered: recv %ld (28 or more) after %ld ms (under 80)", sent, rr, msr);
    check(sent == 8 && rr >= 28 && msr < 80, msg);
    close_(s);

    long s6 = rsock6();
    long st6 = set_tv(s6, 20, 0, 100000);
    long r6;
    long ms6 = timed_recv(s6, &r6);
    long g6 = get_tv(s6, 20, &sec, &usec);
    snprintf(msg, sizeof msg, "6: socket %ld, setsockopt %ld; recv %ld (-11) after %ld ms; reads %ld s, %ld us", s6, st6, r6, ms6, sec, usec);
    check(s6 >= 0 && st6 == 0 && r6 == -11 && near_100(ms6) && g6 == 16 && sec == 0 && usec == 100000, msg);
    close_(s6);

    print(failures == 0 ? "hello394: PASS\n" : "hello394: FAIL\n");
    return failures == 0 ? 0 : 1;
}
