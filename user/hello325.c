/* hello325: O_ASYNC on TCP sockets (Linux net/socket.c sock_fasync; net/core/sock.c sock_def_readable, sock_def_error_report,
 * sk_stream_write_space; net/ipv4/tcp_input.c tcp_reset, tcp_fin, tcp_rcv_state_process).
 * Measured on the host (build with -DHOST), all on 127.0.0.1; the listener is armed with signal 42, the client with 41, the
 * accepted socket with 40:
 *   A. F_SETFL O_ASYNC on a listening TCP socket reads back 0x2002;
 *   B. a connection that finishes its handshake sends the listener POLL_IN, band 0x41 and the listener's fd;
 *   C. the connecting client gets POLL_OUT, band 0x304 and its fd once the handshake completes;
 *   D. every segment of data that arrives sends POLL_IN to the receiver, also while earlier data is unread;
 *   E. the socket's own reads and writes signal nothing;
 *   F. clearing O_ASYNC stops the signals;
 *   G. a sender that filled its buffer (EAGAIN) gets POLL_OUT (2) once the peer drains it;
 *   H. the peer's SHUT_WR (FIN) sends POLL_IN;
 *   I. O_ASYNC belongs to the description: a dup reads it back;
 *   J. a peer that closes with unread data resets the connection: POLL_ERR (4), band 0x8;
 *   K. a refused connect sends the client POLL_ERR (4), band 0x8. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long ret(long r) { return r < 0 ? -errno : r; }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long sk(void) { return ret(socket(2, 1, 0)); }
static long bnd(int fd, const void *a) { return ret(bind(fd, a, 16)); }
static long lsn(int fd) { return ret(listen(fd, 4)); }
static long con(int fd, const void *a) { return ret(connect(fd, a, 16)); }
static long acc(int fd) { return ret(accept(fd, 0, 0)); }
static long snd(int fd, const void *b, long n) { return ret(send(fd, b, n, MSG_NOSIGNAL)); }
static long sndnb(int fd, const void *b, long n) { return ret(send(fd, b, n, MSG_NOSIGNAL | MSG_DONTWAIT)); }
static long rcv(int fd, void *b, long n) { return ret(recv(fd, b, n, MSG_DONTWAIT)); }
static long shut(int fd, int how) { return ret(shutdown(fd, how)); }
static void pump(void) {}
static volatile long cnt[64], code[64], band[64], sfd[64];
static void on_sig(int s, siginfo_t *si, void *u) {
    (void)u;
    cnt[s]++;
    code[s] = si->si_code;
    band[s] = si->si_band;
    sfd[s] = si->si_fd;
}
static void handle(int sig) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_sig;
    sa.sa_flags = SA_SIGINFO;
    sigaction(sig, &sa, 0);
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long sk(void) { return syscall3(41, 2, 1, 0); }
static long bnd(int fd, const void *a) { return syscall3(49, fd, (long)a, 16); }
static long lsn(int fd) { return syscall2(50, fd, 4); }
static long con(int fd, const void *a) { return syscall3(42, fd, (long)a, 16); }
static long acc(int fd) { return syscall3(43, fd, 0, 0); }
static long snd(int fd, const void *b, long n) { return syscall6(44, fd, (long)b, n, 0x4000, 0, 0); }
static long sndnb(int fd, const void *b, long n) { return syscall6(44, fd, (long)b, n, 0x4040, 0, 0); }
static long rcv(int fd, void *b, long n) { return syscall6(45, fd, (long)b, n, 0x40, 0, 0); }
static long shut(int fd, int how) { return syscall2(48, fd, how); }
static void pump(void) { syscall1(104, 0); }
struct kinfo { int signo, err, code, pad; long band; int fd; };
static volatile long cnt[64], code[64], band[64], sfd[64];
static void on_sig(int s, struct kinfo *si, void *u) {
    (void)u;
    cnt[s]++;
    code[s] = si->code;
    band[s] = si->band;
    sfd[s] = si->fd;
}
static void handle(int sig) {
    struct ksigaction sa = { (void (*)(int))on_sig, 0x4, (void *)0, 0 };
    sigaction(sig, &sa, (struct ksigaction *)0);
}
#endif

#define C_GETFL 3
#define C_SETFL 4
#define C_SETOWN 8
#define C_SETSIG 10
#define A_SYNC 0x2000
#define S_SRV 40
#define S_CLI 41
#define S_LSN 42
static int failures;
static char msg[360];
static char big[4096];
static void check(int ok, const char *w) {
    print(ok ? "hello325:   ok   " : "hello325:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void reset(void) {
    for (int i = 0; i < 64; i++) cnt[i] = 0, code[i] = band[i] = sfd[i] = -9;
}
static void await(int sig, long n) { for (int i = 0; i < 100 && cnt[sig] < n; i++) { pump(); usleep(5000); } }
static void quiet(void) { for (int i = 0; i < 8; i++) { pump(); usleep(5000); } }
static long fl(int fd) { return fc(fd, C_GETFL, 0); }
static void arm(int fd, int sig) {
    fc(fd, C_SETOWN, getpid());
    fc(fd, C_SETSIG, sig);
    fc(fd, C_SETFL, fl(fd) | A_SYNC);
}
static void mk(unsigned char *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static long connect_wait(int fd, const void *a) {
    long r = con(fd, a);
    for (int i = 0; i < 100 && (r == -115 || r == -114 || r == -11 || r == -4); i++) {
        pump();
        usleep(5000);
        r = con(fd, a);
    }
    return r == -106 ? 0 : r;
}
static long accept_wait(int fd) {
    long r = acc(fd);
    for (int i = 0; i < 100 && r == -11; i++) {
        pump();
        usleep(5000);
        r = acc(fd);
    }
    return r;
}
static void drain(int fd) {
    for (int i = 0; i < 4; i++) {
        while (rcv(fd, big, sizeof big) > 0) {}
        quiet();
    }
}

int main(void) {
    print("hello325: O_ASYNC on TCP sockets\n");
#ifdef HOST
    signal(SIGPIPE, SIG_IGN);
#endif
    handle(S_SRV);
    handle(S_CLI);
    handle(S_LSN);
    unsigned char pa[16], dead[16];
    mk(pa, 24331);
    mk(dead, 24339);

    int ls = (int)sk();
    long a0 = bnd(ls, pa), a1 = lsn(ls);
    arm(ls, S_LSN);
    long a2 = fl(ls);
    snprintf(msg, sizeof msg, "A: F_SETFL O_ASYNC on a listening TCP socket reads back (%d %ld %ld 0x%lx)", ls, a0, a1, a2);
    check(ls >= 0 && a0 == 0 && a1 == 0 && a2 == 0x2002, msg);

    int c = (int)sk();
    arm(c, S_CLI);
    reset();
    long b0 = connect_wait(c, pa);
    await(S_LSN, 1);
    await(S_CLI, 1);
    int s = (int)accept_wait(ls);
    long b1 = fl(s);
    snprintf(msg, sizeof msg, "B: a finished handshake sends the listener POLL_IN, band 0x41, its fd (connect %ld; hits %ld code %ld band 0x%lx fd %ld/%d; accepted 0x%lx)",
             b0, cnt[S_LSN], code[S_LSN], band[S_LSN], sfd[S_LSN], ls, b1);
    check(b0 == 0 && s >= 0 && cnt[S_LSN] >= 1 && code[S_LSN] == 1 && band[S_LSN] == 0x41 && sfd[S_LSN] == ls && b1 == 2, msg);
    snprintf(msg, sizeof msg, "C: the client gets POLL_OUT, band 0x304, its fd (hits %ld code %ld band 0x%lx fd %ld/%d)", cnt[S_CLI], code[S_CLI], band[S_CLI],
             sfd[S_CLI], c);
    check(cnt[S_CLI] >= 1 && code[S_CLI] == 2 && band[S_CLI] == 0x304 && sfd[S_CLI] == c, msg);

    arm(s, S_SRV);
    quiet();
    reset();
    snd(c, "x", 1);
    await(S_SRV, 1);
    long d0 = cnt[S_SRV], d1 = code[S_SRV], d2 = band[S_SRV], d3 = sfd[S_SRV];
    snd(c, "y", 1);
    await(S_SRV, 2);
    quiet();
    snprintf(msg, sizeof msg, "D: arriving data sends POLL_IN, band 0x41, the fd, also while unread (hits %ld code %ld band 0x%lx fd %ld/%d; again %ld; client %ld)", d0,
             d1, d2, d3, s, cnt[S_SRV], cnt[S_CLI]);
    check(d0 == 1 && d1 == 1 && d2 == 0x41 && d3 == s && cnt[S_SRV] == 2 && cnt[S_CLI] == 0, msg);

    reset();
    drain(s);
    snd(s, "z", 1);
    await(S_CLI, 1);
    quiet();
    snprintf(msg, sizeof msg, "E: the socket's own reads and writes signal nothing (server %ld; client %ld code %ld fd %ld/%d)", cnt[S_SRV], cnt[S_CLI], code[S_CLI],
             sfd[S_CLI], c);
    check(cnt[S_SRV] == 0 && cnt[S_CLI] == 1 && code[S_CLI] == 1 && sfd[S_CLI] == c, msg);
    drain(c);

    long f0 = fc(s, C_SETFL, fl(s) & ~A_SYNC), f1 = fl(s);
    reset();
    snd(c, "w", 1);
    quiet();
    snprintf(msg, sizeof msg, "F: clearing O_ASYNC stops the signals (%ld 0x%lx hits %ld)", f0, f1, cnt[S_SRV]);
    check(f0 == 0 && f1 == 2 && cnt[S_SRV] == 0, msg);
    drain(s);
    fc(s, C_SETFL, fl(s) | A_SYNC);

    long g0 = 0, g1 = 0;
    for (int i = 0; i < 4000; i++) {
        g1 = sndnb(c, big, sizeof big);
        if (g1 < 0) break;
        g0 += g1;
        if (i % 8 == 7) pump();
    }
    quiet();
    reset();
    drain(s);
    await(S_CLI, 1);
    snprintf(msg, sizeof msg, "G: a full sender gets POLL_OUT once the peer drains (queued %ld then %ld; hits %ld code %ld fd %ld/%d)", g0, g1, cnt[S_CLI], code[S_CLI],
             sfd[S_CLI], c);
    check(g0 > 0 && g1 == -11 && cnt[S_CLI] >= 1 && code[S_CLI] == 2 && sfd[S_CLI] == c, msg);
    drain(s);

    reset();
    long h0 = shut(c, 1);
    await(S_SRV, 1);
    quiet();
    snprintf(msg, sizeof msg, "H: the peer's SHUT_WR sends POLL_IN (%ld; hits %ld code %ld band 0x%lx fd %ld/%d)", h0, cnt[S_SRV], code[S_SRV], band[S_SRV], sfd[S_SRV], s);
    check(h0 == 0 && cnt[S_SRV] >= 1 && code[S_SRV] == 1 && sfd[S_SRV] == s, msg);

    int d = dup(s);
    long i0 = fl(d);
    close(d);
    snprintf(msg, sizeof msg, "I: a dup shares O_ASYNC (0x%lx)", i0);
    check(i0 == 0x2002, msg);

    snd(s, "q", 1);
    await(S_CLI, 1);
    quiet();
    reset();
    close(c);
    await(S_SRV, 1);
    quiet();
    snprintf(msg, sizeof msg, "J: a reset sends POLL_ERR, band 0x8 (hits %ld code %ld band 0x%lx fd %ld/%d)", cnt[S_SRV], code[S_SRV], band[S_SRV], sfd[S_SRV], s);
    check(cnt[S_SRV] >= 1 && code[S_SRV] == 4 && band[S_SRV] == 0x8 && sfd[S_SRV] == s, msg);
    close(s);
    close(ls);

    int k = (int)sk();
    arm(k, S_CLI);
    reset();
    long k0 = connect_wait(k, dead);
    await(S_CLI, 1);
    snprintf(msg, sizeof msg, "K: a refused connect sends POLL_ERR, band 0x8 (connect %ld; hits %ld code %ld band 0x%lx fd %ld/%d)", k0, cnt[S_CLI], code[S_CLI],
             band[S_CLI], sfd[S_CLI], k);
    check(k0 == -111 && cnt[S_CLI] >= 1 && code[S_CLI] == 4 && band[S_CLI] == 0x8 && sfd[S_CLI] == k, msg);
    close(k);

    print(failures == 0 ? "hello325: PASS\n" : "hello325: FAIL\n");
    return failures;
}
