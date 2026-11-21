/* hello478: what a UDP socket's IP_RECVERR queue holds (Linux icmp_send quotes as much of the datagram as fits in 576 bytes,
 * icmp6_send in 1280; sock_queue_err_skb charges each error against SO_RCVBUF). Measured on the host (build with -DHOST, run as root
 * in `unshare --map-auto --map-root-user -n` with lo up), sending to an unbound port on the loopback address 30 ms apart:
 *   A. IPv4: a 100-byte datagram's error returns its 100 bytes; a 1000-byte one's returns 520 (576 less the ICMP, two IP and the
 *      UDP headers);
 *   B. IPv6: a 1000-byte datagram's error returns 1000; a 1300-byte one's 1184 (1280 less the ICMPv6, two IPv6 and UDP headers);
 *   D. SO_RCVBUF 4096 (8192): 8 of twenty 1-byte errors, 6 of twenty 1000-byte ones: more than the 4 this kernel used to keep,
 *      fewer than were sent (Linux's ICMP rate limit, icmp_ratelimit 1000 ms with a burst, lets about ten errors through per
 *      second, so the test pauses a second between the two runs and halfway through the second). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static void nap(void) { usleep(30000); }
static void pause_1s(void) { usleep(1000000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static void nap(void) { long t[2] = { 0, 30000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void pause_1s(void) { long t[2] = { 1, 0 }; syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello478:   ok   " : "hello478:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static char b[1500];
/* One recvmsg(MSG_ERRQUEUE | MSG_DONTWAIT): the payload length, or -errno. */
static long err1(long s) {
    static char d[2000];
    static unsigned char ctl[128];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    long iov[2] = { (long)d, sizeof d };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    return recvmsg_(s, mh, 0x2000 | 0x40);
}
static int drain(long s) {
    int n = 0;
    while (err1(s) >= 0) n++;
    return n;
}
static long one_err(long s, int size, const void *to, int tl) {
    sendto_(s, b, size, to, tl);
    nap();
    return err1(s);
}
int main(void) {
    print("hello478: the IP_RECVERR queue: quote length and SO_RCVBUF\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 0; a[3] = 9; a[4] = 127; a[7] = 1;
    int one = 1;
    long s = sock(2, 2, 0);
    setopt_(s, 0, 11, &one, 4);
    long a1 = one_err(s, 100, a, 16), a2 = one_err(s, 1000, a, 16);
    snprintf(msg, sizeof msg, "A: IPv4 100-byte error payload %ld, 1000-byte %ld (100 520)", a1, a2);
    check(a1 == 100 && a2 == 520, msg);

    unsigned char a6[28];
    memset(a6, 0, 28);
    a6[0] = 10; a6[3] = 9; a6[23] = 1;
    long s6 = sock(10, 2, 0);
    setopt_(s6, 41, 25, &one, 4);
    long b1 = one_err(s6, 1000, a6, 28), b2 = one_err(s6, 1300, a6, 28);
    snprintf(msg, sizeof msg, "B: IPv6 1000-byte error payload %ld, 1300-byte %ld (1000 1184)", b1, b2);
    check(b1 == 1000 && b2 == 1184, msg);

    pause_1s();
    long t = sock(2, 2, 0);
    setopt_(t, 0, 11, &one, 4);
    int v = 4096;
    setopt_(t, 1, 8, &v, 4);
    for (int i = 0; i < 20; i++) {
        sendto_(t, b, 1, a, 16);
        nap();
    }
    int d1 = drain(t);
    pause_1s();
    for (int i = 0; i < 20; i++) {
        sendto_(t, b, 1000, a, 16);
        nap();
        if (i == 9) pause_1s();
    }
    int d2 = drain(t);
    snprintf(msg, sizeof msg, "D: SO_RCVBUF 4096: 1-byte errors %d, 1000-byte %d (8 6)", d1, d2);
    check(d1 == 8 && d2 == 6, msg);

    print(failures ? "hello478: FAIL\n" : "hello478: PASS\n");
    return failures ? 1 : 0;
}
