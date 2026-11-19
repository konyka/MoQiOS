/* hello439: the zero-window probe (persist) timer starts from the connection's RTO (Linux tcp_check_probe_timer /
 * tcp_probe_timer: tcp_probe0_when = tcp_probe0_base(sk) << icsk_probes_out, tcp_probe0_base = max(icsk_rto, TCP_RTO_MIN)),
 * and the initial RTO before any sample is TCP_TIMEOUT_INIT, 1 s (RFC 6298). This kernel used a fixed 2 s for the first probe and
 * as the initial RTO. The peer is forged as in hello420: the client connects to a listener whose accept queue is full, the test
 * answers its SYN at once with a SYN-ACK of window 0 through an IPPROTO_RAW socket (so the handshake gives an RTT sample of about
 * 0 and the RTO is TCP_RTO_MIN, 200 ms), and the client queues 1500 bytes it cannot send. Measured on the host (build with -DHOST,
 * run as root in `unshare --map-auto --map-root-user -n` with lo up and
 * `nft add table ip f; nft add chain ip f out '{ type filter hook output priority 0; }'; nft add rule ip f out tcp flags rst drop`):
 *   P. the first window probe comes 150..900 ms after the data was queued, the second 1.5 to 3 times as long after the first. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
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
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long poll_ev(long s) { struct pollfd p = { (int)s, POLLIN | POLLOUT, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : p.revents; }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void close_(long s) { close((int)s); }
static long send_eor(long s, const void *b, long n) { return rc(send((int)s, b, (size_t)n, MSG_EOR | MSG_NOSIGNAL)); }
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
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long poll_ev(long s) { struct { int fd; short ev, rev; } p = { (int)s, 1 | 4, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void close_(long s) { syscall1(11, s); }
static long send_eor(long s, const void *b, long n) { return syscall6(44, s, (long)b, n, 0x80 | 0x4000, 0, 0); }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello439:   ok   " : "hello439:   FAIL ");
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
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static void drain(void) { unsigned char a[16]; int l = 16; while (recvfrom_(rt, seg, sizeof seg, a, &l) >= 0) l = 16; }
static unsigned int rd32(const unsigned char *p) { return (unsigned int)(p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]); }
static void wr32(unsigned char *p, unsigned int v) { p[0] = (unsigned char)(v >> 24); p[1] = (unsigned char)(v >> 16); p[2] = (unsigned char)(v >> 8); p[3] = (unsigned char)v; }
/* The client's SYN to `dport`: its source port and sequence number in *sport / *iss; 0, or -1 when none came. */
static long grab_syn(int dport, int *sport, unsigned *iss) {
    unsigned char a[16];
    for (int k = 0; k < 150; k++) {
        int l = 16;
        long n = recvfrom_(rt, seg, sizeof seg, a, &l);
        if (n < 0) { nap(); continue; }
        int off = (seg[0] & 15) * 4;
        if ((seg[off + 2] << 8 | seg[off + 3]) == dport && (seg[off + 13] & 0x12) == 0x02) {
            *sport = seg[off] << 8 | seg[off + 1];
            *iss = rd32(seg + off + 4);
            return 0;
        }
    }
    return -1;
}
#define PEER_ISS 0x40700000u
/* A segment from the listener's port `lport` to the client's `cport`: 127.0.0.1 -> 127.0.0.1, no options. */
static void forge(int lport, int cport, unsigned seq, unsigned ack, int flags, int win) {
    unsigned char p[40];
    memset(p, 0, sizeof p);
    p[0] = 0x45; p[3] = 40; p[8] = 64; p[9] = 6; p[12] = 127; p[15] = 1; p[16] = 127; p[19] = 1;
    unsigned char *t = p + 20;
    t[0] = (unsigned char)(lport >> 8); t[1] = (unsigned char)lport; t[2] = (unsigned char)(cport >> 8); t[3] = (unsigned char)cport;
    wr32(t + 4, seq);
    wr32(t + 8, ack);
    t[12] = 0x50; t[13] = (unsigned char)flags; t[14] = (unsigned char)(win >> 8); t[15] = (unsigned char)win;
    unsigned int s = 0x7f00 + 0x0001 + 0x7f00 + 0x0001 + 6 + 20;
    for (int i = 0; i < 20; i += 2) s += (unsigned int)(t[i] << 8 | t[i + 1]);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    s = ~s & 0xffff;
    t[16] = (unsigned char)(s >> 8); t[17] = (unsigned char)s;
    unsigned char d[16];
    mk4(d, 0);
    sendto_(rr, p, 40, d, 16);
}
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
/* A client connected to a forged peer on `port` that advertised window 0, with TCP_NODELAY and 1500 bytes queued: the socket (or a
 * negative code); its port and the sequence number of its first data byte in *cport / *una, the time the data was queued in *t0. */
static long forged(int port, int *cport, unsigned *una, long *t0) {
    long s = sock(2, 1 | NONBLOCK, 0);
    seti(s, 6, 1, 1);
    unsigned char a[16];
    mk4(a, port);
    drain();
    connect_(s, a, 16);
    unsigned iss = 0;
    if (grab_syn(port, cport, &iss) < 0) { close_(s); return -1000; }
    forge(port, *cport, PEER_ISS, iss + 1, 0x12, 0);
    *una = iss + 1;
    for (int i = 0; i < 50; i++) {
        if (poll_ev(s) & 4) break;
        nap();
    }
    drain();
    static char data[1500];
    *t0 = now_ms();
    long q = send_eor(s, data, 1500);
    if (q != 1500) { close_(s); return -1001; }
    return s;
}
/* The times (ms after `t0`) of the first `n` segments from the client port `cport` to `port` that carry no SYN; -1 where none came
 * within `limit_ms`. */
static void probes(int port, int cport, long t0, long limit_ms, long *at, int n) {
    for (int i = 0; i < n; i++) at[i] = -1;
    int got = 0;
    unsigned char a[16];
    while (got < n && now_ms() - t0 < limit_ms) {
        int l = 16;
        long r = recvfrom_(rt, seg, sizeof seg, a, &l);
        if (r < 0) { nap(); continue; }
        int off = (seg[0] & 15) * 4;
        int sp = seg[off] << 8 | seg[off + 1], dp = seg[off + 2] << 8 | seg[off + 3];
        if (sp != cport || dp != port || (seg[off + 13] & 0x02)) continue;
        at[got++] = now_ms() - t0;
    }
}
int main(void) {
    print("hello439: the zero-window probe timer starts from the connection's RTO\n");
    rt = sock(2, 3, 6); rr = sock(2, 3, 255);
    long kid[2];
    long L = full_listener(40531, kid);
    int cp = 0;
    unsigned una = 0;
    long t0 = 0;
    long s = forged(40531, &cp, &una, &t0);
    long at[2];
    if (s >= 0) probes(40531, cp, t0, 6000, at, 2);
    long gap = (at[0] >= 0 && at[1] >= 0) ? at[1] - at[0] : -1;
    snprintf(msg, sizeof msg, "P: forged peer %ld; first window probe after %ld ms, second %ld ms later (>=0; 150..900; 1.5x..3x of the first)", s, at[0], gap);
    check(s >= 0 && at[0] >= 150 && at[0] <= 900 && gap * 2 >= at[0] * 3 && gap <= at[0] * 3 + 100, msg);
    if (s >= 0) close_(s);
    close_(kid[0]); close_(kid[1]); close_(L); close_(rt); close_(rr);
    print(failures == 0 ? "hello439: PASS\n" : "hello439: FAIL\n");
    return failures == 0 ? 0 : 1;
}
