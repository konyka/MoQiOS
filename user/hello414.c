/* hello414: the RTO a connection starts its data with when the peer sends no timestamps (Linux tcp_ack_update_rtt with the
 * segment's own send time, tcp_synack_rtt_meas, tcp_init_metrics, RFC 6298 2.1 and 5.7). The handshake gives the first RTT sample
 * when the SYN (or SYN-ACK) was not retransmitted, so on loopback the first data retransmission comes after about TCP_RTO_MIN
 * (200 ms); when the handshake needed a retransmission there is no sample and the RTO falls back to 3 s. The peers are forged with
 * an IPPROTO_RAW socket from the port of a listener whose accept queue is full (see hello407). Measured on the host (build with
 * -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up and RSTs dropped with nft):
 *   F. a client whose first SYN is answered at once: the first data retransmission 150 to 800 ms after the data;
 *   B. a client whose first SYN is ignored and the second answered: the first data retransmission 2.5 to 3.8 s after the data;
 *   S. a server whose SYN-ACK is acknowledged at once: its data is first retransmitted 150 to 800 ms after it went out;
 *   T. a server whose first SYN-ACK is ignored and the retransmitted one acknowledged: 2.5 to 3.8 s. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, MSG_NOSIGNAL, a, (socklen_t)al)); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, a, (socklen_t *)al)); }
static long poll_ev(long s) { struct pollfd p = { (int)s, POLLIN | POLLOUT, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : p.revents; }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void close_(long s) { close((int)s); }
static long rc_name(long s, void *a, int *l) { return rc(getsockname((int)s, a, (socklen_t *)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0x4000, (long)a, al); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return syscall6(122, s, (long)b, n, 0x40, (long)a, (long)al); }
static long poll_ev(long s) { struct { int fd; short ev, rev; } p = { (int)s, 1 | 4, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void close_(long s) { syscall1(11, s); }
static long rc_name(long s, void *a, int *l) { return syscall3(51, s, (long)a, (long)l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello414:   ok   " : "hello414:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char seg[1600];
static long rt, rr;
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static void drain(void) { unsigned char a[16]; int l = 16; while (recvfrom_(rt, seg, sizeof seg, a, &l) >= 0) l = 16; }
/* A full listener on `port` (backlog 1 with two connections queued): new SYNs to it are dropped. */
static long full_listener(int port, long *kid) {
    long l = sock(2, 1, 0);
    unsigned char a[16];
    mk4(a, port);
    bind_(l, a, 16);
    listen_(l, 1);
    for (int i = 0; i < 2; i++) {
        kid[i] = sock(2, 1 | NONBLOCK, 0);
        connect_(kid[i], a, 16);
    }
    for (int i = 0; i < 10; i++) nap();
    return l;
}
/* The client's SYN to `dport`, seen by the raw TCP socket: its length or -1. */
static long grab_syn(int dport) {
    unsigned char a[16];
    for (int k = 0; k < 250; k++) {
        int l = 16;
        long n = recvfrom_(rt, seg, sizeof seg, a, &l);
        if (n < 0) { nap(); continue; }
        int off = (seg[0] & 15) * 4;
        if ((seg[off + 2] << 8 | seg[off + 3]) == dport && (seg[off + 13] & 0x12) == 0x02) return n;
    }
    return -1;
}
static unsigned int rd32(const unsigned char *p) { return (unsigned int)(p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]); }
static void wr32(unsigned char *p, unsigned int v) { p[0] = (unsigned char)(v >> 24); p[1] = (unsigned char)(v >> 16); p[2] = (unsigned char)(v >> 8); p[3] = (unsigned char)v; }
/* Send a 20-byte TCP header 127.0.0.1:sport -> 127.0.0.1:dport, no options, window 65535. */
static void forge(int sport, int dport, int flags, unsigned int sq, unsigned int ak) {
    unsigned char p[40];
    memset(p, 0, sizeof p);
    p[0] = 0x45; p[3] = 40; p[8] = 64; p[9] = 6; p[12] = 127; p[15] = 1; p[16] = 127; p[19] = 1;
    unsigned char *t = p + 20;
    t[0] = (unsigned char)(sport >> 8); t[1] = (unsigned char)sport; t[2] = (unsigned char)(dport >> 8); t[3] = (unsigned char)dport;
    wr32(t + 4, sq);
    wr32(t + 8, ak);
    t[12] = 0x50; t[13] = (unsigned char)flags; t[14] = 0xff; t[15] = 0xff;
    unsigned int s = 0x7f00 + 0x0001 + 0x7f00 + 0x0001 + 6 + 20;
    for (int i = 0; i < 20; i += 2) s += (unsigned int)(t[i] << 8 | t[i + 1]);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    s = ~s & 0xffff;
    t[16] = (unsigned char)(s >> 8); t[17] = (unsigned char)s;
    unsigned char d[16];
    mk4(d, 0);
    sendto_(rr, p, 40, d, 16);
}
static int lport(long s) { unsigned char a[16]; int l = 16; memset(a, 0, 16); if (rc_name(s, a, &l) < 0) return -1; return a[2] << 8 | a[3]; }
/* The times (ms from the call) of the first two data segments from `sport` to `dport` within `limit` ms: how many were seen. */
static int data_times(int sport, int dport, long limit, long *at) {
    long t0 = now_ms();
    int n = 0;
    unsigned char a[16];
    while (now_ms() - t0 < limit && n < 2) {
        int l = 16;
        long r = recvfrom_(rt, seg, sizeof seg, a, &l);
        if (r <= 0) { nap(); continue; }
        int off = (seg[0] & 15) * 4;
        int doff = (seg[off + 12] >> 4) * 4;
        if ((seg[off] << 8 | seg[off + 1]) != sport || (seg[off + 2] << 8 | seg[off + 3]) != dport) continue;
        if (r - off - doff <= 0) continue;
        at[n++] = now_ms() - t0;
    }
    return n;
}
/* A client connected through the forged peer on `port`; `skip` SYNs are ignored before one is answered. The first data
 * retransmission's delay in ms, or a negative code. */
static long client_case(int port, int skip) {
    long s = sock(2, 1 | NONBLOCK, 0);
    unsigned char a[16];
    mk4(a, port);
    drain();
    connect_(s, a, 16);
    int sp = lport(s);
    for (int k = 0; k <= skip; k++) if (grab_syn(port) < 0) { close_(s); return -1000 - k; }
    int off = (seg[0] & 15) * 4;
    forge(port, sp, 0x12, 0x40700000u, rd32(seg + off + 4) + 1);
    int up = 0;
    for (int i = 0; i < 50 && !up; i++) { if (poll_ev(s) & 4) up = 1; else nap(); }
    if (!up) { close_(s); return -1100; }
    drain();
    sendto_(s, "data", 4, 0, 0);
    long at[2];
    int n = data_times(sp, port, 6000, at);
    close_(s);
    return n == 2 ? at[1] - at[0] : -1200 - n;
}
/* A server on `lp` accepting a forged client from `cp`; `skip` SYN-ACKs are ignored before one is acknowledged. The delay of the
 * first retransmission of the data it sends, or a negative code. */
static long server_case(int lp, int cp, unsigned int isn) {
    long l = sock(2, 1 | NONBLOCK, 0);
    unsigned char a[16];
    mk4(a, lp);
    bind_(l, a, 16);
    listen_(l, 4);
    drain();
    forge(cp, lp, 0x02, isn, 0);
    return l;
}
static long server_finish(long l, int lp, int cp, unsigned int isn, int skip) {
    unsigned int siss = 0;
    int seen = 0;
    long t0 = now_ms();
    unsigned char a[16];
    while (seen <= skip && now_ms() - t0 < 6000) {
        int ll = 16;
        long r = recvfrom_(rt, seg, sizeof seg, a, &ll);
        if (r <= 0) { nap(); continue; }
        int off = (seg[0] & 15) * 4;
        if ((seg[off] << 8 | seg[off + 1]) == lp && (seg[off + 2] << 8 | seg[off + 3]) == cp && (seg[off + 13] & 0x12) == 0x12) {
            siss = rd32(seg + off + 4);
            seen++;
        }
    }
    if (seen <= skip) { close_(l); return -1000 - seen; }
    forge(cp, lp, 0x10, isn + 1, siss + 1);
    long c = -1;
    for (int i = 0; i < 50 && c < 0; i++) { c = accept_(l); if (c < 0) nap(); }
    if (c < 0) { close_(l); return -1100; }
    drain();
    sendto_(c, "data", 4, 0, 0);
    long at[2];
    int n = data_times(lp, cp, 6000, at);
    close_(c);
    close_(l);
    return n == 2 ? at[1] - at[0] : -1200 - n;
}
int main(void) {
    print("hello414: the first RTO of a connection whose peer sends no timestamps\n");
    rt = sock(2, 3, 6); rr = sock(2, 3, 255);
    long kid[2];
    long L = full_listener(40424, kid);

    long f = client_case(40424, 0);
    snprintf(msg, sizeof msg, "F: client, SYN answered at once: first data retransmission after %ld ms (150..800)", f);
    check(f >= 150 && f <= 800, msg);

    long b = client_case(40424, 1);
    snprintf(msg, sizeof msg, "B: client, second SYN answered: first data retransmission after %ld ms (2500..3800)", b);
    check(b >= 2500 && b <= 3800, msg);

    long l = server_case(40425, 40424, 0x7000);
    long s = server_finish(l, 40425, 40424, 0x7000, 0);
    snprintf(msg, sizeof msg, "S: server, SYN-ACK acknowledged at once: first data retransmission after %ld ms (150..800)", s);
    check(s >= 150 && s <= 800, msg);

    l = server_case(40426, 40424, 0x9000);
    long t = server_finish(l, 40426, 40424, 0x9000, 1);
    snprintf(msg, sizeof msg, "T: server, retransmitted SYN-ACK acknowledged: first data retransmission after %ld ms (2500..3800)", t);
    check(t >= 2500 && t <= 3800, msg);

    close_(kid[0]); close_(kid[1]); close_(L); close_(rt); close_(rr);
    print(failures == 0 ? "hello414: PASS\n" : "hello414: FAIL\n");
    return failures == 0 ? 0 : 1;
}
