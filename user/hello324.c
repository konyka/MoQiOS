/* hello324: O_ASYNC on UDP sockets (Linux net/socket.c sock_fasync; net/core/sock.c sock_def_readable, sock_def_error_report;
 * net/ipv4/udp.c __udp_enqueue_schedule_skb, __udp4_lib_err).
 * Measured on the host (build with -DHOST), all on 127.0.0.1:
 *   A. F_SETFL O_ASYNC on a UDP socket reads back 0x2002; with no owner nothing is signalled;
 *   B. with an owner and signal 0 an arriving datagram sends a plain SIGIO (SI_KERNEL, band 0, fd 0);
 *   C. with F_SETSIG 40 every arriving datagram sends POLL_IN, band 0x41 and the socket's fd, also while earlier ones are unread;
 *   D. the socket's own sends signal nothing;
 *   E. O_ASYNC set before bind() keeps working after it;
 *   F. an ICMP port unreachable on a connected socket sends POLL_ERR (4), band 0x8 (POLLERR); recv then fails ECONNREFUSED;
 *   G. clearing O_ASYNC stops the signals;
 *   H. O_ASYNC belongs to the description: a dup and a forked child see it, and a datagram the child sends signals the owner;
 *   I. closing one of two descriptors of the description keeps the signals coming;
 *   J. after the last close, a new unarmed socket on the same port is not signalled. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long ret(long r) { return r < 0 ? -errno : r; }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long sk(void) { return ret(socket(2, 2, 0)); }
static long bnd(int fd, const void *a) { return ret(bind(fd, a, 16)); }
static long con(int fd, const void *a) { return ret(connect(fd, a, 16)); }
static long sto(int fd, const void *a) { return ret(sendto(fd, "u", 1, 0, a, a ? 16 : 0)); }
static long rcv(int fd) { char c; return ret(recv(fd, &c, 1, MSG_DONTWAIT)); }
static void pump(void) {}
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
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long sk(void) { return syscall3(41, 2, 2, 0); }
static long bnd(int fd, const void *a) { return syscall3(49, fd, (long)a, 16); }
static long con(int fd, const void *a) { return syscall3(42, fd, (long)a, 16); }
static long sto(int fd, const void *a) { return syscall6(44, fd, (long)"u", 1, 0, (long)a, a ? 16 : 0); }
static long rcv(int fd) { char c; return syscall6(45, fd, (long)&c, 1, 0x40, 0, 0); }
static void pump(void) { syscall1(104, 0); }
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
#endif

#define C_GETFL 3
#define C_SETFL 4
#define C_SETOWN 8
#define C_SETSIG 10
#define A_SYNC 0x2000
#define S_IO 29
#define S_RT 40
static int failures;
static char msg[320];
static void check(int ok, const char *w) {
    print(ok ? "hello324:   ok   " : "hello324:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void reset(void) {
    hits = 0;
    g_sig = g_code = g_band = g_fd = -9;
}
static void settle(void) { for (int i = 0; i < 60 && hits == 0; i++) { pump(); usleep(5000); } }
static void quiet(void) { for (int i = 0; i < 6; i++) { pump(); usleep(5000); } }
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
static void drain(int fd) { for (int i = 0; i < 16 && rcv(fd) >= 0; i++) {} }

int main(void) {
    print("hello324: O_ASYNC on UDP sockets\n");
    handle(S_IO);
    handle(S_RT);
    unsigned char pa[16], pb[16], pc[16], dead[16];
    mk(pa, 24321);
    mk(pb, 24322);
    mk(pc, 24323);
    mk(dead, 24329);

    int a = (int)sk(), b = (int)sk();
    long a0 = bnd(a, pa), a1 = bnd(b, pb), a2 = fc(a, C_SETFL, fl(a) | A_SYNC), a3 = fl(a);
    reset();
    long a4 = sto(b, pa);
    quiet();
    long a5 = rcv(a);
    snprintf(msg, sizeof msg, "A: F_SETFL O_ASYNC on a UDP socket reads back (%ld %ld %ld 0x%lx; no owner: %ld %ld hits %ld)", a0, a1, a2, a3, a4, a5, hits);
    check(a >= 0 && b >= 0 && a0 == 0 && a1 == 0 && a2 == 0 && a3 == 0x2002 && a4 == 1 && a5 == 1 && hits == 0, msg);

    fc(a, C_SETOWN, getpid());
    reset();
    sto(b, pa);
    settle();
    snprintf(msg, sizeof msg, "B: signal 0: a datagram sends a plain SIGIO (hits %ld sig %ld code %ld band %ld fd %ld)", hits, g_sig, g_code, g_band, g_fd);
    check(hits == 1 && g_sig == S_IO && g_code == 0x80 && g_band == 0 && g_fd == 0, msg);
    drain(a);

    fc(a, C_SETSIG, S_RT);
    reset();
    sto(b, pa);
    settle();
    long c0 = hits, c1 = g_sig, c2 = g_code, c3 = g_band, c4 = g_fd;
    sto(b, pa);
    for (int i = 0; i < 60 && hits < 2; i++) { pump(); usleep(5000); }
    snprintf(msg, sizeof msg, "C: F_SETSIG 40: each datagram sends POLL_IN, band 0x41, the fd (hits %ld sig %ld code %ld band 0x%lx fd %ld/%d; unread again %ld)", c0, c1,
             c2, c3, c4, a, hits);
    check(c0 == 1 && c1 == S_RT && c2 == 1 && c3 == 0x41 && c4 == a && hits == 2, msg);
    drain(a);

    reset();
    sto(a, pb);
    quiet();
    drain(b);
    snprintf(msg, sizeof msg, "D: the socket's own send signals nothing (hits %ld)", hits);
    check(hits == 0, msg);

    int e = (int)sk();
    arm(e, S_RT);
    long e0 = bnd(e, pc);
    reset();
    sto(b, pc);
    settle();
    snprintf(msg, sizeof msg, "E: O_ASYNC set before bind keeps working (%ld; hits %ld code %ld fd %ld/%d)", e0, hits, g_code, g_fd, e);
    check(e0 == 0 && hits == 1 && g_code == 1 && g_fd == e, msg);
    drain(e);
    close(e);

    int f = (int)sk();
    unsigned char pf[16];
    mk(pf, 24324);
    bnd(f, pf);
    long f0 = con(f, dead);
    arm(f, S_RT);
    reset();
    sto(f, 0);
    settle();
    long f1 = hits, f2 = g_code, f3 = g_band, f4 = g_fd;
    long f5 = rcv(f);
    snprintf(msg, sizeof msg, "F: port unreachable sends POLL_ERR, band 0x8 (%ld; hits %ld code %ld band 0x%lx fd %ld/%d; recv %ld)", f0, f1, f2, f3, f4, f, f5);
    check(f0 == 0 && f1 == 1 && f2 == 4 && f3 == 0x8 && f4 == f && f5 == -111, msg);
    close(f);

    long g0 = fc(a, C_SETFL, fl(a) & ~A_SYNC), g1 = fl(a);
    reset();
    sto(b, pa);
    quiet();
    drain(a);
    snprintf(msg, sizeof msg, "G: clearing O_ASYNC stops the signals (%ld 0x%lx hits %ld)", g0, g1, hits);
    check(g0 == 0 && g1 == 2 && hits == 0, msg);

    fc(a, C_SETFL, fl(a) | A_SYNC);
    int d = dup(a);
    long h0 = fl(d);
    reset();
    long hc = fork();
    if (hc == 0) _exit((fl(a) & A_SYNC) && sto(b, pa) == 1 ? 0 : 1);
    int hst = -1;
    while (waitpid(hc, &hst, 0) != hc) {}
    settle();
    snprintf(msg, sizeof msg, "H: the description keeps O_ASYNC (dup 0x%lx; child %d; hits %ld code %ld fd %ld/%d)", h0, hst, hits, g_code, g_fd, a);
    check(h0 == 0x2002 && hst == 0 && hits == 1 && g_code == 1 && g_fd == a, msg);
    drain(a);

    close(a);
    reset();
    sto(b, pa);
    settle();
    snprintf(msg, sizeof msg, "I: closing one of two descriptors keeps the signals (hits %ld)", hits);
    check(hits == 1, msg);
    drain(d);
    close(d);

    int j = (int)sk();
    long j0 = bnd(j, pa);
    fc(j, C_SETOWN, getpid());
    reset();
    sto(b, pa);
    quiet();
    long j1 = rcv(j);
    snprintf(msg, sizeof msg, "J: a new socket on the same port is not signalled (%ld %ld hits %ld)", j0, j1, hits);
    check(j0 == 0 && j1 == 1 && hits == 0, msg);
    close(j);
    close(b);

    print(failures == 0 ? "hello324: PASS\n" : "hello324: FAIL\n");
    return failures;
}
