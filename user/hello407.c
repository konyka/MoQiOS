/* hello407: TCP_USER_TIMEOUT, and the error an established connection ends with when its peer stops answering (Linux
 * tcp_sock_set_user_timeout, tcp_write_timeout, tcp_clamp_rto_to_user_timeout, tcp_keepalive_timer, tcp_write_err). The peer is
 * forged: the client connects to a listener whose accept queue is full, so its SYN is dropped, and the test answers it with a
 * SYN-ACK of its own through an IPPROTO_RAW socket; nothing acknowledges what the client sends after that. MoQiOS drops a segment
 * that belongs to no connection; Linux answers it with a RST, so on the host the RSTs are dropped with nft. Measured on the host
 * (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up and
 * `nft add table ip f; nft add chain ip f out '{ type filter hook output priority 0; }'; nft add rule ip f out tcp flags rst drop`):
 *   A. TCP_USER_TIMEOUT reads 0; -1 and a 2-byte value are EINVAL; 1500 reads 1500, 0 reads 0 again;
 *   T. with TCP_USER_TIMEOUT 1000, data nobody acknowledges ends the connection after 1 to 4 s: poll reports POLLIN, POLLERR and
 *      POLLHUP; the first recv is ETIMEDOUT, SO_ERROR is then 0, recv returns 0 and send is EPIPE;
 *   S. the same, with send looking first: send is ETIMEDOUT, then recv returns 0;
 *   K. SO_KEEPALIVE with TCP_KEEPIDLE 1, TCP_KEEPINTVL 1, TCP_KEEPCNT 2 and no answer: POLLERR after 2 to 6 s, SO_ERROR 110;
 *   U. the same with TCP_KEEPCNT 9 and TCP_USER_TIMEOUT 2500: POLLERR after 2 to 6 s (the count alone would take 10 s);
 *   C. a connect to the full listener with TCP_USER_TIMEOUT 1000 fails with ETIMEDOUT after 1 to 4 s (POLLERR, SO_ERROR 110). */
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
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello407:   ok   " : "hello407:   FAIL ");
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
/* A client connected to the forged peer on `port`, with TCP_USER_TIMEOUT `ut` (-1: left alone): the socket, or a negative errno. */
static long forged(int port, int ut) {
    long s = sock(2, 1 | NONBLOCK, 0);
    if (ut >= 0) seti(s, 6, 18, ut);
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
/* Wait up to `limit` ms for POLLERR on `s`: the ms it took, or -1. `ev` gets the revents. */
static long wait_err(long s, long limit, long *ev) {
    long t0 = now_ms();
    while (now_ms() - t0 < limit) {
        *ev = poll_ev(s);
        if (*ev & 8) return now_ms() - t0;
        nap();
    }
    return -1;
}
int main(void) {
    print("hello407: TCP_USER_TIMEOUT and the timeout of an established connection\n");
    rt = sock(2, 3, 6); rr = sock(2, 3, 255);
    long kid[2];
    long L = full_listener(40410, kid);

    long a = sock(2, 1, 0);
    int a0 = geti(a, 6, 18);
    long am = seti(a, 6, 18, -1);
    short two = 5;
    long a2 = setopt(a, 6, 18, &two, 2);
    long a15 = seti(a, 6, 18, 1500);
    int r15 = geti(a, 6, 18);
    long az = seti(a, 6, 18, 0);
    int rz = geti(a, 6, 18);
    snprintf(msg, sizeof msg, "A: default %d; -1 %ld, 2 bytes %ld (-22 -22); 1500 %ld reads %d; 0 %ld reads %d", a0, am, a2, a15, r15, az, rz);
    check(a0 == 0 && am == -22 && a2 == -22 && a15 == 0 && r15 == 1500 && az == 0 && rz == 0, msg);
    close_(a);

    long t = forged(40410, 1000);
    long tw = t >= 0 ? sendto_(t, "data", 4, 0, 0) : t;
    long tev = 0, tt = t >= 0 ? wait_err(t, 8000, &tev) : -1;
    unsigned char b[8];
    int bl = 0;
    long tr1 = t >= 0 ? recvfrom_(t, b, sizeof b, 0, &bl) : -1;
    int tse = t >= 0 ? soerr(t) : -1;
    long tr2 = t >= 0 ? recvfrom_(t, b, sizeof b, 0, &bl) : -1;
    long ts = t >= 0 ? sendto_(t, "x", 1, 0, 0) : -1;
    snprintf(msg, sizeof msg, "T: forged peer %ld, send %ld; POLLERR after %ld ms rev 0x%lx; recv %ld, SO_ERROR %d, recv %ld, send %ld (4, 1000..4000, IN|ERR|HUP, -110 0 0 -32)", t, tw, tt, tev, tr1, tse, tr2, ts);
    check(t >= 0 && tw == 4 && tt >= 900 && tt <= 4000 && (tev & 0x19) == 0x19 && tr1 == -110 && tse == 0 && tr2 == 0 && ts == -32, msg);
    if (t >= 0) close_(t);

    long s = forged(40410, 1000);
    long sw = s >= 0 ? sendto_(s, "data", 4, 0, 0) : s;
    long sev = 0, st = s >= 0 ? wait_err(s, 8000, &sev) : -1;
    long ss = s >= 0 ? sendto_(s, "x", 1, 0, 0) : -1;
    long sr = s >= 0 ? recvfrom_(s, b, sizeof b, 0, &bl) : -1;
    snprintf(msg, sizeof msg, "S: forged peer %ld, send %ld; POLLERR after %ld ms; send %ld, recv %ld (4, 1000..4000, -110 0)", s, sw, st, ss, sr);
    check(s >= 0 && sw == 4 && st >= 900 && st <= 4000 && ss == -110 && sr == 0, msg);
    if (s >= 0) close_(s);

    long k = forged(40410, -1);
    if (k >= 0) { seti(k, 1, 9, 1); seti(k, 6, 4, 1); seti(k, 6, 5, 1); seti(k, 6, 6, 2); }
    long kev = 0, kt = k >= 0 ? wait_err(k, 9000, &kev) : -1;
    int kse = k >= 0 ? soerr(k) : -1;
    snprintf(msg, sizeof msg, "K: forged peer %ld; keepalive idle 1 intvl 1 cnt 2: POLLERR after %ld ms, SO_ERROR %d (2000..6000, 110)", k, kt, kse);
    check(k >= 0 && kt >= 1800 && kt <= 6000 && kse == 110, msg);
    if (k >= 0) close_(k);

    long u = forged(40410, -1);
    if (u >= 0) { seti(u, 1, 9, 1); seti(u, 6, 4, 1); seti(u, 6, 5, 1); seti(u, 6, 6, 9); seti(u, 6, 18, 2500); }
    long uev = 0, utt = u >= 0 ? wait_err(u, 12000, &uev) : -1;
    int use = u >= 0 ? soerr(u) : -1;
    snprintf(msg, sizeof msg, "U: forged peer %ld; keepalive cnt 9 with TCP_USER_TIMEOUT 2500: POLLERR after %ld ms, SO_ERROR %d (2000..6000, 110)", u, utt, use);
    check(u >= 0 && utt >= 1800 && utt <= 6000 && use == 110, msg);
    if (u >= 0) close_(u);

    long c = sock(2, 1 | NONBLOCK, 0);
    seti(c, 6, 18, 1000);
    unsigned char ca[16];
    mk4(ca, 40410);
    long cc = connect_(c, ca, 16);
    long cev = 0, ct = wait_err(c, 8000, &cev);
    int cse = soerr(c);
    snprintf(msg, sizeof msg, "C: connect to the full listener with TCP_USER_TIMEOUT 1000: %ld; POLLERR after %ld ms, SO_ERROR %d (-115, 900..4000, 110)", cc, ct, cse);
    check(cc == -115 && ct >= 900 && ct <= 4000 && cse == 110, msg);
    close_(c);

    close_(kid[0]); close_(kid[1]); close_(L); close_(rt); close_(rr);
    print(failures == 0 ? "hello407: PASS\n" : "hello407: FAIL\n");
    return failures == 0 ? 0 : 1;
}
