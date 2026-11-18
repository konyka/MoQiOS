/* hello420: TCP_NOTSENT_LOWAT when the peer's window opens (Linux tcp_event_new_data_sent -> tcp_check_space -> tcp_new_space ->
 * sk_stream_write_space). Data that goes out because a window update arrived lowers the bytes not yet sent, and a writer blocked on
 * the limit, or an epoll waiting for EPOLLOUT, hears it then, not at some later ACK. The peer is forged as in hello407: the client
 * connects to a listener whose accept queue is full, the test answers its SYN with a SYN-ACK of window 0 through an IPPROTO_RAW
 * socket, and a child later sends a pure ACK that opens the window to 65535; nothing acknowledges data after that. Measured on the
 * host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up and
 * `nft add table ip f; nft add chain ip f out '{ type filter hook output priority 0; }'; nft add rule ip f out tcp flags rst drop`):
 *   W. with TCP_NODELAY, TCP_NOTSENT_LOWAT 1024 and 1500 bytes queued against window 0: no POLLOUT and a non-blocking send of 100 is
 *      EAGAIN; a blocking send of 100 under SO_SNDTIMEO 3000 ms returns 100 within 250..1500 ms of the start once the window opens
 *      at about 300 ms;
 *   E. the same set-up with an epoll registered for EPOLLOUT: epoll_wait with a 3000 ms timeout returns EPOLLOUT within 250..1500 ms. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/wait.h>
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
static long fork_(void) { return fork(); }
static long send_eor(long s, const void *b, long n) { return rc(send((int)s, b, (size_t)n, MSG_EOR | MSG_NOSIGNAL)); }
static void wait_(long pid) { int st = 0; waitpid((pid_t)pid, &st, 0); }
static void exit_(int c) { _exit(c); }
static long ep_create(void) { return rc(epoll_create1(0)); }
static long ep_add_out(long ep, long s) { struct epoll_event e = { EPOLLOUT, { .u64 = 7 } }; return rc(epoll_ctl((int)ep, EPOLL_CTL_ADD, (int)s, &e)); }
static long ep_wait(long ep, long ms, unsigned *ev) { struct epoll_event e = { 0, { 0 } }; long r = rc(epoll_wait((int)ep, &e, 1, (int)ms)); *ev = e.events; return r; }
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
static long fork_(void) { return syscall0(57); }
static long send_eor(long s, const void *b, long n) { return syscall6(44, s, (long)b, n, 0x80 | 0x4000, 0, 0); }
static void wait_(long pid) { int st = 0; syscall3(6, pid, (long)&st, 0); }
static void exit_(int c) { syscall1(2, c); }
struct epev { unsigned events; unsigned long data; } __attribute__((packed));
static long ep_create(void) { return syscall1(146, 0); }
static long ep_add_out(long ep, long s) { struct epev e = { 4, 7 }; return syscall4(147, ep, 1, s, (long)&e); }
static long ep_wait(long ep, long ms, unsigned *ev) { struct epev e = { 0, 0 }; long r = syscall4(148, ep, (long)&e, 1, ms); *ev = e.events; return r; }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello420:   ok   " : "hello420:   FAIL ");
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
/* A client connected to a forged peer on `port` that advertised window 0, with TCP_NODELAY and TCP_NOTSENT_LOWAT 1024 and 1500
 * bytes queued: the socket (or a negative code); its port and the sequence number of its first data byte in *cport / *una. */
static long forged(int port, int *cport, unsigned *una) {
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
    seti(s, 6, 25, 1024);
    static char data[1500];
    long q = send_eor(s, data, 1500);
    if (q != 1500) { close_(s); return -1001; }
    return s;
}
/* The pure ACK that opens the window, sent by a child after about 300 ms. */
static long open_later(int port, int cport, unsigned una) {
    long pid = fork_();
    if (pid == 0) {
        for (int i = 0; i < 15; i++) nap();
        forge(port, cport, PEER_ISS + 1, una, 0x10, 65535);
        exit_(0);
    }
    return pid;
}
int main(void) {
    print("hello420: TCP_NOTSENT_LOWAT when the peer's window opens\n");
    rt = sock(2, 3, 6); rr = sock(2, 3, 255);
    long kid[2];
    long L = full_listener(40521, kid);
    static char b[100];

    int wp = 0;
    unsigned wu = 0;
    long w = forged(40521, &wp, &wu);
    long wev = w >= 0 ? poll_ev(w) : -1;
    long wn = w >= 0 ? sendto_(w, b, 100, 0, 0) : -1;
    long tv[2] = { 3, 0 };
    if (w >= 0) setopt(w, 1, 21, tv, 16);
    long wr = -1, wt = -1;
    if (w >= 0) {
#ifdef HOST
        int fl = fcntl((int)w, F_GETFL); fcntl((int)w, F_SETFL, fl & ~O_NONBLOCK);
#else
        syscall3(72, w, 4, 0);
#endif
        long pid = open_later(40521, wp, wu);
        long t0 = now_ms();
        wr = sendto_(w, b, 100, 0, 0);
        wt = now_ms() - t0;
        wait_(pid);
    }
    snprintf(msg, sizeof msg, "W: forged peer %ld; before the window opens POLLOUT %ld, send %ld; blocking send %ld after %ld ms (>=0, 0, -11; 100, 250..1500)", w, wev & 4, wn, wr, wt);
    check(w >= 0 && (wev & 4) == 0 && wn == -11 && wr == 100 && wt >= 250 && wt <= 1500, msg);
    if (w >= 0) close_(w);

    int ep_ = 0;
    unsigned eu = 0;
    long e = forged(40521, &ep_, &eu);
    long eev = e >= 0 ? poll_ev(e) : -1;
    long ep = ep_create();
    long ea = e >= 0 ? ep_add_out(ep, e) : -1;
    unsigned got = 0;
    long en0 = e >= 0 ? ep_wait(ep, 0, &got) : -1;
    long er = -1, et = -1;
    if (e >= 0 && ea == 0) {
        long pid = open_later(40521, ep_, eu);
        long t0 = now_ms();
        er = ep_wait(ep, 3000, &got);
        et = now_ms() - t0;
        wait_(pid);
    }
    snprintf(msg, sizeof msg, "E: forged peer %ld; POLLOUT %ld, EPOLL_CTL_ADD %ld, epoll_wait(0) %ld; epoll_wait(3000) %ld events 0x%x after %ld ms (>=0, 0, 0, 0; 1, 0x4, 250..1500)", e, eev & 4, ea, en0, er, got, et);
    check(e >= 0 && (eev & 4) == 0 && ea == 0 && en0 == 0 && er == 1 && (got & 4) && et >= 250 && et <= 1500, msg);
    close_(ep);
    if (e >= 0) close_(e);

    close_(kid[0]); close_(kid[1]); close_(L); close_(rt); close_(rr);
    print(failures == 0 ? "hello420: PASS\n" : "hello420: FAIL\n");
    return failures == 0 ? 0 : 1;
}
