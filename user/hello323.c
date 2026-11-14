/* hello323: O_ASYNC on AF_UNIX sockets (Linux net/socket.c sock_fasync, sock_wake_async; net/unix/af_unix.c unix_stream_sendmsg,
 * unix_dgram_sendmsg, unix_write_space, unix_shutdown, unix_release_sock, unix_stream_connect), and the status flags of a socket or
 * pipe description shared by its dup()s.
 * Measured on the host (build with -DHOST):
 *   A. F_SETFL O_ASYNC on a stream socketpair reads back 0x2002; with no owner nothing is signalled;
 *   B. with an owner and signal 0 a send by the peer sends a plain SIGIO (SI_KERNEL, band 0, fd 0);
 *   C. with F_SETSIG 40 every send by the peer sends POLL_IN, band 0x41 and the socket's fd;
 *   D. the socket's own sends and reads, and the peer reading what it sent, signal nothing;
 *   E. a non-blocking send that fills the peer to EAGAIN signals nothing, nor does the peer taking a little; the peer draining it
 *      sends POLL_OUT, band 0x304, once;
 *   F. the peer's shutdown(SHUT_RD) signals nothing, SHUT_WR sends POLL_IN, SHUT_RDWR sends POLL_HUP (6) with band 0x18;
 *   G. the peer closing a stream or seqpacket socket sends POLL_HUP, band 0x18;
 *   H. a datagram from the peer sends POLL_IN; the peer closing a datagram socket signals nothing; filling it to EAGAIN and draining
 *      it sends POLL_OUT;
 *   I. a connection reaching an O_ASYNC listener sends POLL_IN with the listener's fd; data sent before accept and accept itself
 *      signal nothing; a connected client is signalled with its own fd;
 *   J. a client still queued when its listener closes receives POLL_HUP;
 *   K. clearing O_ASYNC stops the signals;
 *   L. a forked child's send signals the owner;
 *   M. a stream reader blocked in recv() gets no POLL_IN, a datagram reader blocked in recv() does;
 *   N. the status flags belong to the description: a dup sees O_ASYNC; O_NONBLOCK set through a dup by F_SETFL or FIONBIO makes a
 *      read through the original fail EAGAIN, on a socket and on a pipe;
 *   O. RWF_NOWAIT on a dup'd pipe or socket fails EAGAIN and leaves the flags as they were. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long ret(long r) { return r < 0 ? -errno : r; }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long wr(int fd, const void *b, long n) { return ret(write(fd, b, n)); }
static long rd(int fd, void *b, long n) { return ret(read(fd, b, n)); }
static long sp(long type, int *sv) { return ret(socketpair(AF_UNIX, type, 0, sv)); }
static long sk(long type) { return ret(socket(AF_UNIX, type, 0)); }
static long bnd(int fd, const void *a, long n) { return ret(bind(fd, a, n)); }
static long lis(int fd) { return ret(listen(fd, 4)); }
static long con(int fd, const void *a, long n) { return ret(connect(fd, a, n)); }
static long acc(int fd) { return ret(accept(fd, 0, 0)); }
static long shut(int fd, long how) { return ret(shutdown(fd, how)); }
static long nbio(int fd, int on) { return ret(ioctl(fd, FIONBIO, &on)); }
static long nowait(int fd) { char c; struct iovec v = { &c, 1 }; return ret(preadv2(fd, &v, 1, -1, RWF_NOWAIT)); }
static volatile long g_sig, g_code, g_band, g_fd, hits;
static void on_sig(int s, siginfo_t *si, void *u) {
    (void)u;
    g_sig = s;
    g_code = si->si_code;
    g_band = si->si_band;
    g_fd = si->si_fd;
    hits++;
}
static void handle(int sig) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_sig;
    sa.sa_flags = SA_SIGINFO;
    sigaction(sig, &sa, 0);
}
static void ignore_pipe(void) { signal(SIGPIPE, SIG_IGN); }
typedef pthread_t thr_t;
static void thr_go(thr_t *t, void *(*f)(void *)) { pthread_create(t, 0, f, 0); }
static void thr_join(thr_t t) { pthread_join(t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/pthread.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long wr(int fd, const void *b, long n) { return write(fd, b, n); }
static long rd(int fd, void *b, long n) { return read(fd, b, n); }
static long sp(long type, int *sv) { return syscall4(53, 1, type, 0, (long)sv); }
static long sk(long type) { return syscall3(41, 1, type, 0); }
static long bnd(int fd, const void *a, long n) { return syscall3(49, fd, (long)a, n); }
static long lis(int fd) { return syscall2(50, fd, 4); }
static long con(int fd, const void *a, long n) { return syscall3(42, fd, (long)a, n); }
static long acc(int fd) { return syscall3(43, fd, 0, 0); }
static long shut(int fd, long how) { return syscall2(48, fd, how); }
static long nbio(int fd, int on) { return syscall3(165, fd, 0x5421, (long)&on); }
static long nowait(int fd) { char c; struct iovec v = { &c, 1 }; return syscall6(498, fd, (long)&v, 1, -1, 0, RWF_NOWAIT); }
struct kinfo { int signo, err, code, pad; long band; int fd; };
static volatile long g_sig, g_code, g_band, g_fd, hits;
static void on_sig(int s, struct kinfo *si, void *u) {
    (void)u;
    g_sig = s;
    g_code = si->code;
    g_band = si->band;
    g_fd = si->fd;
    hits++;
}
static void handle(int sig) {
    struct ksigaction sa = { (void (*)(int))on_sig, 0x4, (void *)0, 0 };
    sigaction(sig, &sa, (struct ksigaction *)0);
}
static void ignore_pipe(void) {
    struct ksigaction sa = { (void (*)(int))1, 0, (void *)0, 0 };
    sigaction(13, &sa, (struct ksigaction *)0);
}
typedef pthread_t thr_t;
static void thr_go(thr_t *t, void *(*f)(void *)) { pthread_create(t, (void *)0, f, (void *)0); }
static void thr_join(thr_t t) { pthread_join(t, (void **)0); }
#endif
#ifdef HOST
static long rcv(int fd) { char c; return ret(recv(fd, &c, 1, 0)); }
#else
static long rcv(int fd) { char c; return syscall6(45, fd, (long)&c, 1, 0, 0, 0); }
#endif

#define C_GETFL 3
#define C_SETFL 4
#define C_SETOWN 8
#define C_SETSIG 10
#define A_SYNC 0x2000
#define NBLK 0x800
#define S_IO 29
#define S_RT 40
#define ST 1
#define DG 2
#define SQ 5
static int failures;
static char msg[320];
static void check(int ok, const char *w) {
    print(ok ? "hello323:   ok   " : "hello323:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void reset(void) {
    hits = 0;
    g_sig = g_code = g_band = g_fd = -9;
}
static void settle(void) { for (int i = 0; i < 40 && hits == 0; i++) usleep(5000); }
static void quiet(void) { usleep(20000); }
static long fl(int fd) { return fc(fd, C_GETFL, 0); }
static void arm(int fd, int sig) {
    fc(fd, C_SETOWN, getpid());
    fc(fd, C_SETSIG, sig);
    fc(fd, C_SETFL, fl(fd) | A_SYNC);
}
static void nonblock(int fd) { fc(fd, C_SETFL, fl(fd) | NBLK); }
static long fill(int fd) {
    char b[256];
    memset(b, 1, sizeof b);
    long tot = 0, r;
    while ((r = wr(fd, b, sizeof b)) > 0) tot += r;
    return r == -11 ? tot : r;
}
static long drain(int fd) {
    char b[512];
    long got = 0, r;
    while ((r = rd(fd, b, sizeof b)) > 0) got += r;
    return got;
}
struct addr { unsigned short family; char path[108]; };
static const char *PATH = "/tmp/h323.sock";
static long alen(struct addr *a) {
    memset(a, 0, sizeof *a);
    a->family = 1;
    strcpy(a->path, PATH);
    return 2 + (long)strlen(PATH) + 1;
}

/* A probe that could block: run it in a child, which is killed if it has not finished within a second (2 = it hung). */
static int g_probe_fd;
static int (*g_probe)(int);
static long guarded(int (*f)(int), int fd) {
    g_probe = f;
    g_probe_fd = fd;
    long c = fork();
    if (c == 0) _exit(g_probe(g_probe_fd));
    int st = -1;
    for (int i = 0; i < 100; i++) {
        if (waitpid(c, &st, 1) == c) return (st >> 8) & 0xff;
        usleep(10000);
    }
    kill(c, 9);
    while (waitpid(c, &st, 0) != c) {}
    return 2;
}
static int p_read(int fd) { char c; return rd(fd, &c, 1) == -11 ? 0 : 1; }
static int p_recv(int fd) { return rcv(fd) == -11 ? 0 : 1; }
static int p_nowait(int fd) { return nowait(fd) == -11 && (fl(fd) & NBLK) == 0 ? 0 : 1; }

static int m_fd;
static void *m_reader(void *u) {
    (void)u;
    char c;
    rd(m_fd, &c, 1);
    return 0;
}
static long blocked_reader(long type) {
    int sv[2];
    sp(type, sv);
    arm(sv[0], S_RT);
    m_fd = sv[0];
    thr_t t;
    thr_go(&t, m_reader);
    usleep(60000);
    reset();
    wr(sv[1], "x", 1);
    thr_join(t);
    quiet();
    long h = hits;
    close(sv[0]);
    close(sv[1]);
    return h;
}

int main(void) {
    print("hello323: O_ASYNC on AF_UNIX sockets\n");
    handle(S_IO);
    handle(S_RT);
    ignore_pipe();
    char c = 0;
    int sv[2] = { -1, -1 };

    long a0 = sp(ST, sv), a1 = fc(sv[0], C_SETFL, fl(sv[0]) | A_SYNC), a2 = fl(sv[0]);
    reset();
    long a3 = wr(sv[1], "x", 1), a4 = rd(sv[0], &c, 1);
    quiet();
    snprintf(msg, sizeof msg, "A: F_SETFL O_ASYNC on a socketpair reads back (%ld %ld 0x%lx; no owner: %ld %ld hits %ld)", a0, a1, a2, a3, a4, hits);
    check(a0 == 0 && a1 == 0 && a2 == 0x2002 && a3 == 1 && a4 == 1 && hits == 0, msg);

    fc(sv[0], C_SETOWN, getpid());
    reset();
    wr(sv[1], "x", 1);
    settle();
    snprintf(msg, sizeof msg, "B: signal 0: a peer send sends a plain SIGIO (hits %ld sig %ld code %ld band %ld fd %ld)", hits, g_sig, g_code, g_band, g_fd);
    check(hits == 1 && g_sig == S_IO && g_code == 0x80 && g_band == 0 && g_fd == 0, msg);
    rd(sv[0], &c, 1);

    fc(sv[0], C_SETSIG, S_RT);
    reset();
    wr(sv[1], "x", 1);
    settle();
    long c0 = hits, c1 = g_sig, c2 = g_code, c3 = g_band, c4 = g_fd;
    wr(sv[1], "x", 1);
    quiet();
    snprintf(msg, sizeof msg, "C: F_SETSIG 40: each peer send sends POLL_IN, band 0x41, the fd (hits %ld sig %ld code %ld band 0x%lx fd %ld/%d; again %ld)", c0,
             c1, c2, c3, c4, sv[0], hits);
    check(c0 == 1 && c1 == S_RT && c2 == 1 && c3 == 0x41 && c4 == sv[0] && hits == 2, msg);
    rd(sv[0], &c, 1);
    rd(sv[0], &c, 1);

    reset();
    wr(sv[0], "y", 1);
    rd(sv[1], &c, 1);
    wr(sv[1], "z", 1);
    quiet();
    long d0 = hits;
    reset();
    rd(sv[0], &c, 1);
    quiet();
    snprintf(msg, sizeof msg, "D: own sends and reads, and the peer reading them, signal nothing (hits %ld after the peer's send; %ld after)", d0, hits);
    check(d0 == 1 && hits == 0, msg);

    nonblock(sv[0]);
    nonblock(sv[1]);
    reset();
    long e0 = fill(sv[0]);
    quiet();
    long e1 = hits;
    char small[64];
    rd(sv[1], small, sizeof small);
    quiet();
    long e2 = hits;
    long e3 = drain(sv[1]);
    settle();
    snprintf(msg, sizeof msg, "E: filling to EAGAIN then draining sends POLL_OUT once (filled %ld hits %ld; little %ld; drained %ld: hits %ld code %ld band 0x%lx fd %ld)",
             e0, e1, e2, e3, hits, g_code, g_band, g_fd);
    check(e0 > 0 && e1 == 0 && e2 == 0 && e3 > 0 && hits == 1 && g_code == 2 && g_band == 0x304 && g_fd == sv[0], msg);
    close(sv[0]);
    close(sv[1]);

    long f[3][3];
    for (int how = 0; how < 3; how++) {
        sp(ST, sv);
        arm(sv[0], S_RT);
        reset();
        shut(sv[1], how);
        settle();
        f[how][0] = hits;
        f[how][1] = g_code;
        f[how][2] = g_band;
        close(sv[0]);
        close(sv[1]);
    }
    snprintf(msg, sizeof msg, "F: peer shutdown: RD nothing (%ld), WR POLL_IN (%ld %ld 0x%lx), RDWR POLL_HUP (%ld %ld 0x%lx)", f[0][0], f[1][0], f[1][1], f[1][2],
             f[2][0], f[2][1], f[2][2]);
    check(f[0][0] == 0 && f[1][0] == 1 && f[1][1] == 1 && f[1][2] == 0x41 && f[2][0] == 1 && f[2][1] == 6 && f[2][2] == 0x18, msg);

    long g[2][4];
    for (int k = 0; k < 2; k++) {
        sp(k == 0 ? ST : SQ, sv);
        arm(sv[0], S_RT);
        reset();
        close(sv[1]);
        settle();
        g[k][0] = hits;
        g[k][1] = g_code;
        g[k][2] = g_band;
        g[k][3] = g_fd == sv[0];
        close(sv[0]);
    }
    snprintf(msg, sizeof msg, "G: the peer closing sends POLL_HUP, band 0x18 (stream %ld %ld 0x%lx %ld; seqpacket %ld %ld 0x%lx %ld)", g[0][0], g[0][1], g[0][2],
             g[0][3], g[1][0], g[1][1], g[1][2], g[1][3]);
    check(g[0][0] == 1 && g[0][1] == 6 && g[0][2] == 0x18 && g[0][3] && g[1][0] == 1 && g[1][1] == 6 && g[1][2] == 0x18 && g[1][3], msg);

    sp(DG, sv);
    arm(sv[0], S_RT);
    reset();
    wr(sv[1], "d", 1);
    settle();
    long h0 = hits, h1 = g_code, h2 = g_band;
    rd(sv[0], &c, 1);
    reset();
    close(sv[1]);
    quiet();
    long h3 = hits;
    close(sv[0]);
    sp(DG, sv);
    arm(sv[0], S_RT);
    nonblock(sv[0]);
    nonblock(sv[1]);
    reset();
    long h4 = fill(sv[0]);
    quiet();
    long h5 = hits;
    drain(sv[1]);
    settle();
    snprintf(msg, sizeof msg, "H: datagram: a peer send sends POLL_IN (%ld %ld 0x%lx); the peer closing nothing (%ld); fill %ld (%ld) and drain: POLL_OUT (%ld %ld 0x%lx)",
             h0, h1, h2, h3, h4, h5, hits, g_code, g_band);
    check(h0 == 1 && h1 == 1 && h2 == 0x41 && h3 == 0 && h4 > 0 && h5 == 0 && hits == 1 && g_code == 2 && g_band == 0x304, msg);
    close(sv[0]);
    close(sv[1]);

    struct addr ad;
    long al = alen(&ad);
    unlink(PATH);
    int l = (int)sk(ST);
    long i0 = bnd(l, &ad, al), i1 = lis(l);
    arm(l, S_RT);
    int cl = (int)sk(ST);
    reset();
    long i2 = con(cl, &ad, al);
    settle();
    long i3 = hits, i4 = g_code, i5 = g_fd;
    reset();
    wr(cl, "q", 1);
    quiet();
    long i6 = hits;
    int sv_acc = (int)acc(l);
    quiet();
    long i7 = hits;
    arm(cl, S_RT);
    reset();
    wr(sv_acc, "r", 1);
    settle();
    snprintf(msg, sizeof msg, "I: a connection signals the listener (%ld %ld; %ld %ld fd %ld/%d); early data %ld, accept %ld; the client gets its own fd (%ld %ld/%d)",
             i0 | i1, i2, i3, i4, i5, l, i6, i7, hits, g_fd, cl);
    check(i0 == 0 && i1 == 0 && i2 == 0 && i3 == 1 && i4 == 1 && i5 == l && i6 == 0 && sv_acc >= 0 && i7 == 0 && hits == 1 && g_fd == cl, msg);
    close(sv_acc);
    close(cl);

    int q = (int)sk(ST);
    con(q, &ad, al);
    arm(q, S_RT);
    reset();
    close(l);
    settle();
    snprintf(msg, sizeof msg, "J: a client still queued when its listener closes gets POLL_HUP (hits %ld code %ld band 0x%lx fd %ld/%d)", hits, g_code, g_band, g_fd, q);
    check(hits == 1 && g_code == 6 && g_band == 0x18 && g_fd == q, msg);
    close(q);
    unlink(PATH);

    sp(ST, sv);
    arm(sv[0], S_RT);
    long k0 = fc(sv[0], C_SETFL, fl(sv[0]) & ~A_SYNC), k1 = fl(sv[0]);
    reset();
    wr(sv[1], "k", 1);
    quiet();
    rd(sv[0], &c, 1);
    snprintf(msg, sizeof msg, "K: clearing O_ASYNC stops the signals (%ld 0x%lx hits %ld)", k0, k1, hits);
    check(k0 == 0 && k1 == 2 && hits == 0, msg);

    arm(sv[0], 0);
    reset();
    long lc = fork();
    if (lc == 0) _exit(wr(sv[1], "c", 1) == 1 ? 0 : 1);
    int lst = -1;
    while (waitpid(lc, &lst, 0) != lc) {}
    settle();
    snprintf(msg, sizeof msg, "L: a child's send signals the owner (child %d hits %ld sig %ld)", lst, hits, g_sig);
    check(lst == 0 && hits == 1 && g_sig == S_IO, msg);
    rd(sv[0], &c, 1);
    close(sv[0]);
    close(sv[1]);

    long m0 = blocked_reader(ST), m1 = blocked_reader(DG);
    snprintf(msg, sizeof msg, "M: a blocked stream reader gets no POLL_IN (%ld), a blocked datagram reader does (%ld)", m0, m1);
    check(m0 == 0 && m1 == 1, msg);

    sp(ST, sv);
    fc(sv[0], C_SETFL, fl(sv[0]) | A_SYNC);
    int dd = dup(sv[0]);
    long n0 = fl(dd);
    fc(dd, C_SETFL, fl(dd) | NBLK);
    long n1 = fl(sv[0]) & NBLK, n2 = guarded(p_read, sv[0]), n3 = guarded(p_recv, sv[0]);
    fc(dd, C_SETFL, fl(dd) & ~NBLK);
    long n4 = nbio(dd, 1), n5 = fl(sv[0]) & NBLK, n6 = guarded(p_read, sv[0]);
    nbio(dd, 0);
    long n7 = fl(sv[0]) & NBLK;
    int pp[2];
    pipe(pp);
    int pd = dup(pp[0]);
    fc(pd, C_SETFL, fl(pd) | NBLK);
    long n8 = guarded(p_read, pp[0]);
    nbio(pd, 0);
    long n9 = fl(pp[0]) & NBLK;
    nbio(pd, 1);
    long n10 = guarded(p_read, pp[0]);
    nbio(pd, 0);
    snprintf(msg, sizeof msg, "N: flags belong to the description (dup 0x%lx; F_SETFL via dup 0x%lx read %ld recv %ld; FIONBIO %ld 0x%lx read %ld, off 0x%lx; pipe %ld 0x%lx %ld)",
             n0, n1, n2, n3, n4, n5, n6, n7, n8, n9, n10);
    check(n0 == 0x2002 && n1 == NBLK && n2 == 0 && n3 == 0 && n4 == 0 && n5 == NBLK && n6 == 0 && n7 == 0 && n8 == 0 && n9 == 0 && n10 == 0, msg);

    long o0 = guarded(p_nowait, pp[0]), o1 = guarded(p_nowait, sv[0]), o2 = fl(pp[0]), o3 = fl(sv[0]);
    snprintf(msg, sizeof msg, "O: RWF_NOWAIT on a dup'd pipe and socket is EAGAIN and keeps the flags (%ld %ld 0x%lx 0x%lx)", o0, o1, o2, o3);
    check(o0 == 0 && o1 == 0 && o2 == 0 && o3 == 0x2002, msg);
    close(pd);
    close(pp[0]);
    close(pp[1]);
    close(dd);
    close(sv[0]);
    close(sv[1]);

    print(failures == 0 ? "hello323: PASS\n" : "hello323: FAIL\n");
    return failures;
}
