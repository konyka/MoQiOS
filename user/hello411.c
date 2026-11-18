/* hello411: how long an established connection retransmits before it gives up, and TCP_RTO_MAX_MS (Linux tcp_write_timeout,
 * retransmits_timed_out, tcp_model_timeout, tcp_retransmit_timer, do_tcp_setsockopt). Without TCP_USER_TIMEOUT an established
 * connection gives up on time, not on a count: once the oldest unacknowledged data has waited what tcp_retries2 (15) exponentially
 * backed-off retransmissions from TCP_RTO_MIN (200 ms) would take with the RTO capped at TCP_RTO_MAX_MS (about 924 s for the
 * default 120 s; 14.4 s for 1000 ms). The peer is forged as in hello411. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with lo up and RSTs dropped with nft, see hello411):
 *   A. TCP_RTO_MAX_MS reads 120000; 999, 120001 and a 2-byte value are EINVAL; 1000 reads 1000;
 *   R. with TCP_RTO_MAX_MS 1000, data nobody acknowledges ends the connection after 13 to 19 s (SO_ERROR 110), after 8 to 22
 *      retransmissions, none of them more than 1.6 s after the previous one;
 *   C. a connect to a full listener with TCP_RTO_MAX_MS 1000 and TCP_SYNCNT 3 fails with ETIMEDOUT after 3.5 to 6.5 s, after 3 to
 *      5 SYNs. */
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
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static long poll_ev(long s) { struct pollfd p = { (int)s, POLLIN | POLLOUT, 0 }; long r = rc(poll(&p, 1, 0)); return r < 0 ? r : p.revents; }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void close_(long s) { close((int)s); }
static long rc_name(long s, void *a, int *l) { return rc(getsockname((int)s, a, (socklen_t *)l)); }
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
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long poll_ev(long s) { struct { int fd; short ev, rev; } p = { (int)s, 1 | 4, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void close_(long s) { syscall1(11, s); }
static long rc_name(long s, void *a, int *l) { return syscall3(51, s, (long)a, (long)l); }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello411:   ok   " : "hello411:   FAIL ");
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
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static int soerr(long s) { return geti(s, 1, 4); }
static void drain(void) { unsigned char a[16]; int l = 16; while (recvfrom_(rt, seg, sizeof seg, a, &l) >= 0) l = 16; }
/* The client's SYN to `dport`, seen by the raw TCP socket: its length (IP header included) or -1. */
static long grab_syn(int dport) {
    unsigned char a[16];
    for (int k = 0; k < 150; k++) {
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
/* Answer the SYN in `seg` with a SYN-ACK from the listener's port: 127.0.0.1 -> 127.0.0.1, window 65535, no options. */
static void synack(void) {
    int off = (seg[0] & 15) * 4;
    unsigned char p[40];
    memset(p, 0, sizeof p);
    p[0] = 0x45; p[3] = 40; p[8] = 64; p[9] = 6; p[12] = 127; p[15] = 1; p[16] = 127; p[19] = 1;
    unsigned char *t = p + 20;
    t[0] = seg[off + 2]; t[1] = seg[off + 3]; t[2] = seg[off]; t[3] = seg[off + 1];
    wr32(t + 4, 0x40700000u);
    wr32(t + 8, rd32(seg + off + 4) + 1);
    t[12] = 0x50; t[13] = 0x12; t[14] = 0xff; t[15] = 0xff;
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
/* A client connected to the forged peer on `port`, with TCP_RTO_MAX_MS 1000: the socket, or a negative errno. */
static long forged_rto(int port) {
    long s = sock(2, 1 | NONBLOCK, 0);
    seti(s, 6, 44, 1000);
    unsigned char a[16];
    mk4(a, port);
    drain();
    connect_(s, a, 16);
    if (grab_syn(port) < 0) { close_(s); return -1000; }
    synack();
    for (int i = 0; i < 50; i++) {
        if (poll_ev(s) & 4) return s;
        nap();
    }
    close_(s);
    return -1001;
}
/* Count the client's segments on port `sport` that carry data, until POLLERR on `s` or `limit` ms: the ms to POLLERR or -1. `n` gets
 * the count, `gap` the longest wait between two of them (from the first). */
static long count_rtx(long s, int sport, int syn, long limit, int *n, long *gap) {
    long t0 = now_ms(), last = -1;
    *n = 0;
    *gap = 0;
    unsigned char a[16];
    while (now_ms() - t0 < limit) {
        int l = 16;
        long r = recvfrom_(rt, seg, sizeof seg, a, &l);
        if (r > 0) {
            int off = (seg[0] & 15) * 4;
            int doff = (seg[off + 12] >> 4) * 4;
            int sp = seg[off] << 8 | seg[off + 1];
            int is = syn ? (seg[off + 13] & 0x12) == 0x02 : r - off - doff > 0;
            if (sp == sport && is) {
                long t = now_ms();
                if (last >= 0 && t - last > *gap) *gap = t - last;
                last = t;
                (*n)++;
            }
            continue;
        }
        if (poll_ev(s) & 8) return now_ms() - t0;
        nap();
    }
    return -1;
}
static int lport(long s) { unsigned char a[16]; int l = 16; memset(a, 0, 16); if (rc_name(s, a, &l) < 0) return -1; return a[2] << 8 | a[3]; }
int main(void) {
    print("hello411: how long an established connection retransmits, and TCP_RTO_MAX_MS\n");
    rt = sock(2, 3, 6); rr = sock(2, 3, 255);
    long kid[2];
    long L = full_listener(40411, kid);

    long a = sock(2, 1, 0);
    int a0 = geti(a, 6, 44);
    long a9 = seti(a, 6, 44, 999);
    long ah = seti(a, 6, 44, 120001);
    short two = 1500;
    long a2 = setopt(a, 6, 44, &two, 2);
    long a1 = seti(a, 6, 44, 1000);
    int r1 = geti(a, 6, 44);
    snprintf(msg, sizeof msg, "A: TCP_RTO_MAX_MS default %d; 999 %ld, 120001 %ld, 2 bytes %ld (-22 -22 -22); 1000 %ld reads %d", a0, a9, ah, a2, a1, r1);
    check(a0 == 120000 && a9 == -22 && ah == -22 && a2 == -22 && a1 == 0 && r1 == 1000, msg);
    close_(a);

    long t = forged_rto(40411);
    int tp = t >= 0 ? lport(t) : -1;
    long tw = t >= 0 ? sendto_(t, "data", 4, 0, 0) : t;
    int tn = 0;
    long tg = 0, tt = t >= 0 ? count_rtx(t, tp, 0, 30000, &tn, &tg) : -1;
    int tse = t >= 0 ? soerr(t) : -1;
    snprintf(msg, sizeof msg, "R: forged peer %ld, send %ld; POLLERR after %ld ms, SO_ERROR %d, %d data segments, longest gap %ld ms (4, 13000..19000, 110, 9..23, <= 1600)", t, tw, tt, tse, tn, tg);
    check(t >= 0 && tw == 4 && tt >= 13000 && tt <= 19000 && tse == 110 && tn >= 9 && tn <= 23 && tg <= 1600, msg);
    if (t >= 0) close_(t);

    long c = sock(2, 1 | NONBLOCK, 0);
    seti(c, 6, 44, 1000);
    seti(c, 6, 7, 3);
    unsigned char ca[16];
    mk4(ca, 40411);
    drain();
    long cc = connect_(c, ca, 16);
    int cp = lport(c);
    int cn = 0;
    long cg = 0, ct = count_rtx(c, cp, 1, 15000, &cn, &cg);
    int cse = soerr(c);
    snprintf(msg, sizeof msg, "C: connect with TCP_RTO_MAX_MS 1000, TCP_SYNCNT 3: %ld; POLLERR after %ld ms, SO_ERROR %d, %d SYNs, longest gap %ld ms (-115, 3500..6500, 110, 3..5, <= 1600)", cc, ct, cse, cn, cg);
    check(cc == -115 && ct >= 3500 && ct <= 6500 && cse == 110 && cn >= 3 && cn <= 5 && cg <= 1600, msg);
    close_(c);

    close_(kid[0]); close_(kid[1]); close_(L); close_(rt); close_(rr);
    print(failures == 0 ? "hello411: PASS\n" : "hello411: FAIL\n");
    return failures == 0 ? 0 : 1;
}
