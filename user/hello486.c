/* hello486: what poll reports after this end's own shutdown(SHUT_RD) (Linux tcp_poll: RCV_SHUTDOWN gives EPOLLIN | EPOLLRDNORM |
 * EPOLLRDHUP; unix_dgram_poll and unix_poll the same). Measured on the host (build with -DHOST):
 *   A. an AF_UNIX datagram pair: the peer's SHUT_WR leaves this end's revents 0 (a datagram socket has no peer half-close);
 *   B. this end's own SHUT_RD: POLLIN | POLLRDHUP (0x2001);
 *   C. an AF_UNIX stream pair after its own SHUT_RD: 0x2001 as well;
 *   D. an accepted TCP connection over 127.0.0.1 after its own SHUT_RD: 0x2001;
 *   E. a datagram end that shut its read side still reads what was queued before, then MSG_DONTWAIT is EAGAIN and a
 *      blocking recv returns 0 (unix_dgram_recvmsg: RCV_SHUTDOWN ends the wait);
 *   F. sends into a datagram socket that shut its read side are EPIPE, also sendto its bound name (unix_dgram_sendmsg);
 *   G. a datagram end that shut its write side gets EPIPE from send; none of these datagram EPIPEs raise SIGPIPE (only
 *      unix_stream_sendmsg sends one);
 *   H. SHUT_RDWR on a datagram socket adds POLLHUP: 0x2011;
 *   I. shutdown(SHUT_RD) of an AF_UNIX stream socket that was never connected is 0 and takes effect (0x2011, the
 *      never-connected stream already reports POLLHUP); Linux checks no connection state in unix_shutdown;
 *   J. a seqpacket pair after its own SHUT_RD: 0x2001. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <sys/socket.h>
#include <signal.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long pair_(int t, int *sv) { return rc(socketpair(1, t, 0, sv)); }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s) { return rc(listen((int)s, 4)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long shut(long s, int h) { return rc(shutdown((int)s, h)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long send_(long s, const void *b, long n, int f) { return rc(send((int)s, b, (size_t)n, f)); }
static long sendto_(long s, const void *b, long n, const void *a, int l) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)l)); }
static long recv_(long s, void *b, long n, int f) { return rc(recv((int)s, b, (size_t)n, f)); }
static void ignore_sigpipe(void) { sigset_t m; sigemptyset(&m); sigaddset(&m, SIGPIPE); sigprocmask(SIG_BLOCK, &m, 0); }
static int sigpipe_pending(void) { sigset_t m; sigpending(&m); return sigismember(&m, SIGPIPE); }
static int revents(long s) { struct pollfd p = { (int)s, POLLIN | POLLRDHUP, 0 }; poll(&p, 1, 0); return p.revents; }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
static long pair_(int t, int *sv) { return syscall4(128, 1, t, 0, (long)sv); }
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s) { return syscall2(119, s, 4); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long shut(long s, int h) { return syscall2(48, s, h); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long send_(long s, const void *b, long n, int f) { return syscall6(121, s, (long)b, n, f, 0, 0); }
static long sendto_(long s, const void *b, long n, const void *a, int l) { return syscall6(121, s, (long)b, n, 0, (long)a, l); }
static long recv_(long s, void *b, long n, int f) { return syscall6(122, s, (long)b, n, f, 0, 0); }
static void ignore_sigpipe(void) { unsigned long m = 1ul << 12; syscall4(14, 0, (long)&m, 0, 8); }
static int sigpipe_pending(void) { unsigned long m = 0; syscall2(219, (long)&m, 8); return (m >> 12) & 1; }
static int revents(long s) { struct { int fd; short ev, rev; } p = { (int)s, 0x2001, 0 }; syscall3(SYS_poll, (long)&p, 1, 0); return (unsigned short)p.rev; }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello486:   ok   " : "hello486:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
int main(void) {
    print("hello486: poll after this end's own SHUT_RD\n");
    int d[2], st[2];
    pair_(2, d);
    long s1 = shut(d[0], 1);
    int a = revents(d[1]);
    snprintf(msg, sizeof msg, "A: dgram peer SHUT_WR %ld, revents %#x (0 0)", s1, a);
    check(s1 == 0 && a == 0, msg);
    long s2 = shut(d[1], 0);
    int b = revents(d[1]);
    snprintf(msg, sizeof msg, "B: dgram own SHUT_RD %ld, revents %#x (0 0x2001)", s2, b);
    check(s2 == 0 && b == 0x2001, msg);
    pair_(1, st);
    long s3 = shut(st[1], 0);
    int c = revents(st[1]);
    snprintf(msg, sizeof msg, "C: stream own SHUT_RD %ld, revents %#x (0 0x2001)", s3, c);
    check(s3 == 0 && c == 0x2001, msg);
    int one = 1;
    struct { unsigned short fam, port; unsigned char addr[4]; unsigned char z[8]; } sa = { 2, (unsigned short)((40486 >> 8) | ((40486 & 0xff) << 8)), { 127, 0, 0, 1 }, { 0 } };
    long l = sock(2, 1, 0);
    setopt_(l, 1, 2, &one, 4);
    long bl = bind_(l, &sa, sizeof sa), li = listen_(l);
    long cl = sock(2, 1, 0);
    long cn = connect_(cl, &sa, sizeof sa);
    long ac = accept_(l);
    long s4 = shut(ac, 0);
    int dd = revents(ac);
    snprintf(msg, sizeof msg, "D: tcp bind %ld listen %ld connect %ld accept %d, own SHUT_RD %ld, revents %#x (0 0 0 1 0 0x2001)", bl, li, cn, ac >= 0, s4, dd);
    check(bl == 0 && li == 0 && cn == 0 && ac >= 0 && s4 == 0 && dd == 0x2001, msg);
    close_(ac);
    close_(cl);
    close_(l);
    ignore_sigpipe();
    char buf[8];
    int e[2];
    pair_(2, e);
    long q1 = send_(e[1], "ab", 2, 0), q2 = send_(e[1], "c", 1, 0);
    long es = shut(e[0], 0);
    long r1 = recv_(e[0], buf, 8, 0), r2 = recv_(e[0], buf, 8, 0x40), r3 = recv_(e[0], buf, 8, 0);
    snprintf(msg, sizeof msg, "E: sends %ld %ld, own SHUT_RD %ld, recv %ld, again %ld, nonblock %ld, blocking %ld (2 1 0 2 1 -11 0)", q1, q2, es, r1, r2, recv_(e[0], buf, 8, 0x40), r3);
    check(q1 == 2 && q2 == 1 && es == 0 && r1 == 2 && r2 == 1 && r3 == 0 && recv_(e[0], buf, 8, 0x40) == -11, msg);
    long f1 = send_(e[1], "x", 1, 0);
    struct { unsigned short fam; char path[8]; } un = { 1, { 0, 'h', '4', '8', '6', 'f', 0, 0 } };
    long g1 = sock(1, 2, 0), g2 = sock(1, 2, 0);
    long gb = bind_(g1, &un, 8);
    long gs = shut(g1, 0);
    long f2 = sendto_(g2, "x", 1, &un, 8);
    snprintf(msg, sizeof msg, "F: send to peer after its SHUT_RD %ld, bind %ld shut %ld sendto %ld (-32 0 0 -32)", f1, gb, gs, f2);
    check(f1 == -32 && gb == 0 && gs == 0 && f2 == -32, msg);
    int w[2];
    pair_(2, w);
    long ws = shut(w[0], 1);
    long g3 = send_(w[0], "x", 1, 0), g4 = send_(w[1], "y", 1, 0);
    int pend = sigpipe_pending();
    snprintf(msg, sizeof msg, "G: own SHUT_WR %ld, send %ld, reverse send %ld, SIGPIPE pending %d (0 -32 1 0)", ws, g3, g4, pend);
    check(ws == 0 && g3 == -32 && g4 == 1 && pend == 0, msg);
    long hs = shut(g2, 2);
    int h = revents(g2);
    snprintf(msg, sizeof msg, "H: unconnected dgram SHUT_RDWR %ld, revents %#x (0 0x2011)", hs, h);
    check(hs == 0 && h == 0x2011, msg);
    long u = sock(1, 1, 0);
    long us = shut(u, 0);
    int ur = revents(u);
    snprintf(msg, sizeof msg, "I: never-connected stream SHUT_RD %ld, revents %#x (0 0x2011)", us, ur);
    check(us == 0 && ur == 0x2011, msg);
    int sp[2];
    long sq = pair_(5, sp);
    long ss = shut(sp[0], 0);
    int sr = revents(sp[0]);
    snprintf(msg, sizeof msg, "J: seqpacket pair %ld, own SHUT_RD %ld, revents %#x (0 0 0x2001)", sq, ss, sr);
    check(sq == 0 && ss == 0 && sr == 0x2001, msg);
    close_(e[0]); close_(e[1]); close_(w[0]); close_(w[1]); close_(g1); close_(g2); close_(u); close_(sp[0]); close_(sp[1]);
    print(failures ? "hello486: FAIL\n" : "hello486: PASS\n");
    return failures ? 1 : 0;
}
