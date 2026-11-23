/* hello496: IP_MINTTL and IPV6_MINHOPCOUNT also gate ICMP errors for TCP (tcp_v4_err / tcp_v6_err).
 * A nonblocking connect stays in SYN_SENT behind a full accept queue. An ICMP host-unreachable quoting its SYN is ignored below
 * the socket threshold and ends the connect with EHOSTUNREACH at the threshold. IPv4 checks the quoted datagram's TTL (tcp_v4_err's
 * skb->data points there); the IPv6 raw injector sets the outer packet's hop limit. The host comparison distinguishes these paths.
 * Measured with -DHOST in a new network namespace with lo up. A: IPv4; B: IPv6. */
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
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, a, (socklen_t *)al)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static long setopt_(long s, int lv, int o, int v) { return rc(setsockopt((int)s, lv, o, &v, 4)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define NONBLOCK SOCK_NONBLOCK
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return syscall6(122, s, (long)b, n, 0x40, (long)a, (long)al); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long setopt_(long s, int lv, int o, int v) { return syscall5(132, s, lv, o, (long)&v, 4); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[600];
static unsigned char seg[1600];
static long rt4, rr4, rt6, ri6;
static void check(int ok, const char *w) {
    print(ok ? "hello496:   ok   " : "hello496:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port;
    a[4] = 127; a[7] = 1;
}
static void mk6(unsigned char *a, int port) {
    memset(a, 0, 28);
    a[0] = 10;
    a[2] = (unsigned char)(port >> 8); a[3] = (unsigned char)port;
    a[23] = 1;
}
static int soerr(long s) { int e = -7; int l = 4; long r = getopt_(s, 1, 4, &e, &l); return r < 0 ? (int)r : e; }
static long grab(long r, int v6, int dport) {
    unsigned char a[28];
    for (int k = 0; k < 150; k++) {
        int l = 28;
        long n = recvfrom_(r, seg, sizeof seg, a, &l);
        if (n < 0) { nap(); continue; }
        int off = v6 ? 0 : (seg[0] & 15) * 4;
        if ((seg[off + 2] << 8 | seg[off + 3]) != dport) continue;
        if (!(seg[off + 13] & 2)) continue;
        return n;
    }
    return -1;
}
static void drain(long r) { unsigned char a[28]; int l = 28; while (recvfrom_(r, seg, sizeof seg, a, &l) >= 0) l = 28; }
static void bump(unsigned char *p, int delta) {
    unsigned int q = ((unsigned int)p[0] << 24 | (unsigned int)p[1] << 16 | (unsigned int)p[2] << 8 | p[3]) + (unsigned int)delta;
    p[0] = (unsigned char)(q >> 24); p[1] = (unsigned char)(q >> 16); p[2] = (unsigned char)(q >> 8); p[3] = (unsigned char)q;
}
static long icmp4(int ttl) {
    int ihl = (seg[0] & 15) * 4, ql = ihl + 8, tot = 8 + ql;
    unsigned char p[120];
    memset(p, 0, sizeof p);
    p[0] = 3; p[1] = 1;
    seg[8] = (unsigned char)ttl;
    memcpy(p + 8, seg, (unsigned long)ql);
    bump(p + 8 + ihl + 4, 1);
    unsigned int s = 0;
    for (int i = 0; i < tot; i += 2) s += (unsigned int)(p[i] << 8 | (i + 1 < tot ? p[i + 1] : 0));
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    s = ~s & 0xffff;
    p[2] = (unsigned char)(s >> 8); p[3] = (unsigned char)s;
    unsigned char d[16];
    mk4(d, 0);
    return sendto_(rr4, p, tot, d, 16);
}
static long icmp6(int hops, long n) {
    unsigned char p[120];
    memset(p, 0, sizeof p);
    p[0] = 1; p[1] = 3;
    unsigned char *h = p + 8;
    h[0] = 0x60; h[5] = (unsigned char)n; h[6] = 6; h[7] = 64; h[23] = 1; h[39] = 1;
    int ql = n < 20 ? (int)n : 20;
    memcpy(h + 40, seg, (unsigned long)ql);
    bump(h + 44, 1);
    long so = setopt_(ri6, 41, 16, hops);
    if (so < 0) return so;
    unsigned char d[28];
    mk6(d, 0);
    return sendto_(ri6, p, 48 + ql, d, 28);
}
static long full_listener(int v6, int port, long *child) {
    long l = sock(v6 ? 10 : 2, 1, 0);
    unsigned char a[28];
    if (v6) mk6(a, port); else mk4(a, port);
    bind_(l, a, v6 ? 28 : 16);
    listen_(l, 1);
    for (int i = 0; i < 2; i++) {
        child[i] = sock(v6 ? 10 : 2, 1 | NONBLOCK, 0);
        connect_(child[i], a, v6 ? 28 : 16);
    }
    for (int i = 0; i < 10; i++) nap();
    return l;
}
static long start(int v6, int port, long *n, long *threshold, long *cr) {
    long s = sock(v6 ? 10 : 2, 1 | NONBLOCK, 0);
    *threshold = setopt_(s, v6 ? 41 : 0, v6 ? 73 : 21, 2);
    unsigned char a[28];
    if (v6) mk6(a, port); else mk4(a, port);
    drain(v6 ? rt6 : rt4);
    *cr = connect_(s, a, v6 ? 28 : 16);
    *n = grab(v6 ? rt6 : rt4, v6, port);
    return s;
}
static void settle(void) { for (int i = 0; i < 3; i++) nap(); }
static void run_family(int v6, int port) {
    long kids[2];
    long listener = full_listener(v6, port, kids);
    long n = -1, threshold = -1, cr = -1;
    long s = start(v6, port, &n, &threshold, &cr);
    int threshold_value = -1, threshold_len = 4;
    long threshold_read = getopt_(s, v6 ? 41 : 0, v6 ? 73 : 21, &threshold_value, &threshold_len);
    long low_send = v6 ? icmp6(1, n) : icmp4(1);
    settle();
    int low_error = soerr(s);
    long high_send = v6 ? icmp6(2, n) : icmp4(2);
    settle();
    int high_error = soerr(s), cleared = soerr(s);
    snprintf(msg, sizeof msg, "%c: threshold %ld read %ld/%d connect %ld SYN %ld; low send %ld SO_ERROR %d; threshold send %ld SO_ERROR %d then %d (0 0/2 -115 >0; >0 0; >0 113 0)",
             v6 ? 'B' : 'A', threshold, threshold_read, threshold_value, cr, n, low_send, low_error, high_send, high_error, cleared);
    check(threshold == 0 && threshold_read == 0 && threshold_value == 2 && cr == -115 && n > 0 && low_send > 0 && low_error == 0 && high_send > 0 && high_error == 113 && cleared == 0, msg);
    close_(s); close_(listener); close_(kids[0]); close_(kids[1]);
}
int main(void) {
    print("hello496: IP_MINTTL / IPV6_MINHOPCOUNT filter ICMP errors for TCP\n");
    rt4 = sock(2, 3, 6); rr4 = sock(2, 3, 1); rt6 = sock(10, 3, 6); ri6 = sock(10, 3, 58);
    check(rt4 >= 0 && rr4 >= 0 && rt6 >= 0 && ri6 >= 0, "raw TCP/ICMP sockets");
    run_family(0, 40496);
    run_family(1, 40497);
    close_(rt4); close_(rr4); close_(rt6); close_(ri6);
    print(failures ? "hello496: FAIL\n" : "hello496: PASS\n");
    return failures ? 1 : 0;
}
