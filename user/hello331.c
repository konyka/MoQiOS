/* hello331: O_ASYNC on fd 0 when it is the terminal (Linux: fd 0 is an open file description of the tty like any other, so
 * drivers/tty/tty_io.c __tty_fasync and n_tty kill_fasync(POLL_IN) apply to it; fork and dup share the description, fs/fcntl.c setfl).
 * Measured on the host (build with -DHOST: a raw pty slave dup'd onto fd 0 stands in for the console, master writes stand in for TIOCSTI):
 *   A. F_SETFL O_ASYNC on fd 0 reads back with O_ASYNC set;
 *   B. enabling it on fd 0 without an owner makes the caller (or the terminal's foreground group) the owner;
 *   C. with F_SETSIG 40 an arriving character sends POLL_IN, band 0x41 and si_fd 0;
 *   D. a dup of fd 0 shares O_ASYNC; closing the dup leaves fd 0 armed;
 *   E. a forked child sees O_ASYNC on its fd 0, and the parent is still signalled after the child exits;
 *   F. a forked child clearing O_ASYNC on its fd 0 clears it for the parent too (one description), and nothing is signalled;
 *   G. clearing O_ASYNC on fd 0 stops the signals. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long io(long fd, unsigned long cmd, void *a) { long r = ioctl(fd, cmd, a); return r == -1 ? -errno : r; }
static int master;
static int open_tty(void) {
    master = posix_openpt(O_RDWR | O_NOCTTY);
    grantpt(master);
    unlockpt(master);
    int s = open(ptsname(master), O_RDWR | O_NOCTTY);
    struct termios t;
    tcgetattr(s, &t);
    cfmakeraw(&t);
    tcsetattr(s, TCSANOW, &t);
    dup2(s, 0);
    return s;
}
static void inj(int fd, char c) { (void)fd; write(master, &c, 1); }
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
static long io(long fd, unsigned long cmd, void *a) { return syscall3(165, fd, (long)cmd, (long)a); }
static int open_tty(void) { return (int)open("/dev/tty", 2, 0); }
static void inj(int fd, char c) { io(fd, 0x5412, &c); }
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
#define C_GETOWN 9
#define C_SETOWN 8
#define C_SETSIG 10
#define A_SYNC 0x2000
#define LARGEFILE 0x8000
#define S_IO 29
#define S_RT 40
static int failures;
static char msg[360];
static char buf[64];
static void check(int ok, const char *w) {
    print(ok ? "hello331:   ok   " : "hello331:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void reset(void) {
    for (int i = 0; i < 64; i++) cnt[i] = 0, code[i] = band[i] = sfd[i] = -9;
}
static void await(int sig, long n) { for (int i = 0; i < 100 && cnt[sig] < n; i++) usleep(5000); }
static void quiet(void) { usleep(40000); }
static long fl(int fd) { return fc(fd, C_GETFL, 0) & ~LARGEFILE; }
static long eat(int fd) { return read(fd, buf, sizeof buf); }

int main(void) {
    print("hello331: O_ASYNC on fd 0 as the terminal\n");
    handle(S_IO);
    handle(S_RT);
    int t = open_tty();
    long before = fl(0);
    long a0 = fc(0, C_SETFL, before | A_SYNC), a1 = fl(0);
    snprintf(msg, sizeof msg, "A: F_SETFL O_ASYNC on fd 0 reads back (%ld 0x%lx -> 0x%lx)", a0, before, a1);
    check(t >= 0 && before >= 0 && a0 == 0 && a1 == (before | A_SYNC), msg);

    int pg = -1;
    long b0 = fc(0, C_GETOWN, 0), bp = io(0, 0x540F, &pg);
    snprintf(msg, sizeof msg, "B: enabling it makes the caller (or the foreground group) the owner (%ld; pid %ld pgrp %ld/%d)", b0, (long)getpid(), bp, pg);
    check(b0 == getpid() || (bp == 0 && pg > 0 && b0 == -pg), msg);
    fc(0, C_SETOWN, getpid());
    fc(0, C_SETSIG, S_RT);

    reset();
    inj(t, 'a');
    await(S_RT, 1);
    snprintf(msg, sizeof msg, "C: an arriving character sends POLL_IN, band 0x41, si_fd 0 (hits %ld code %ld band 0x%lx fd %ld)", cnt[S_RT], code[S_RT], band[S_RT],
             sfd[S_RT]);
    check(cnt[S_RT] == 1 && code[S_RT] == 1 && band[S_RT] == 0x41 && sfd[S_RT] == 0, msg);
    eat(t);

    int d = dup(0);
    long d0 = fl(d);
    close(d);
    reset();
    inj(t, 'b');
    await(S_RT, 1);
    snprintf(msg, sizeof msg, "D: a dup of fd 0 shares O_ASYNC (0x%lx), closing it leaves fd 0 armed (hits %ld fd %ld)", d0, cnt[S_RT], sfd[S_RT]);
    check(d >= 0 && (d0 & A_SYNC) && cnt[S_RT] == 1 && sfd[S_RT] == 0, msg);
    eat(t);

    long ek = fork();
    if (ek == 0) _exit((fl(0) & A_SYNC) ? 0 : 1);
    int est = -1;
    while (waitpid(ek, &est, 0) != ek) {}
    reset();
    inj(t, 'c');
    await(S_RT, 1);
    snprintf(msg, sizeof msg, "E: a forked child sees O_ASYNC on fd 0 (status %d), the parent is still signalled after it exits (hits %ld)", est, cnt[S_RT]);
    check(est == 0 && cnt[S_RT] == 1, msg);
    eat(t);

    long fk = fork();
    if (fk == 0) _exit(fc(0, C_SETFL, fl(0) & ~A_SYNC) == 0 ? 0 : 1);
    int fst = -1;
    while (waitpid(fk, &fst, 0) != fk) {}
    long f0 = fl(0);
    reset();
    inj(t, 'd');
    quiet();
    snprintf(msg, sizeof msg, "F: a child clearing O_ASYNC on fd 0 clears it for the parent (status %d, 0x%lx, hits %ld)", fst, f0, cnt[S_RT]);
    check(fst == 0 && (f0 & A_SYNC) == 0 && cnt[S_RT] == 0, msg);
    eat(t);

    fc(0, C_SETFL, fl(0) | A_SYNC);
    long g0 = fc(0, C_SETFL, fl(0) & ~A_SYNC), g1 = fl(0);
    reset();
    inj(t, 'e');
    quiet();
    snprintf(msg, sizeof msg, "G: clearing O_ASYNC on fd 0 stops the signals (%ld 0x%lx hits %ld)", g0, g1, cnt[S_RT]);
    check(g0 == 0 && (g1 & A_SYNC) == 0 && cnt[S_RT] == 0, msg);
    eat(t);
    close(t);

    print(failures == 0 ? "hello331: PASS\n" : "hello331: FAIL\n");
    return failures;
}
