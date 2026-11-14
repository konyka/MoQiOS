/* hello320: O_ASYNC on a pipe (Linux fs/fcntl.c setfl, fasync_helper, kill_fasync, send_sigio_to_task; fs/pipe.c pipe_read,
 * pipe_write, pipe_release, pipe_fasync).
 * Measured on the host (build with -DHOST):
 *   A. F_SETFL O_ASYNC succeeds on both ends and F_GETFL reads back 0x2000 / 0x2001; with no owner nothing is signalled;
 *   B. with an owner and signal 0 every write sends a plain SIGIO (si_code SI_KERNEL, band 0, fd 0), even into a non-empty pipe;
 *   C. with F_SETSIG 40 a write sends 40 with POLL_IN (1), si_band POLLIN|POLLRDNORM (0x41) and the read end's fd;
 *   D. an O_ASYNC write end is signalled when the reader takes data: POLL_OUT (2), band 0x304, the write end's fd; a write does not
 *      signal the write end;
 *   E. closing the last write end signals the reader with POLL_IN; reading EOF signals nobody;
 *   F. closing the read end signals the writer with POLL_OUT; a write then fails EPIPE and signals nobody;
 *   G. clearing O_ASYNC stops the signals;
 *   H. O_ASYNC belongs to the open file description: a dup and a forked child see it, either clearing it clears it for both;
 *   I. a forked child's write signals the owner (the parent);
 *   J. an owner of -pgrp receives the signal;
 *   K. /dev/null and a regular file accept F_SETFL O_ASYNC (0) but do not read the bit back;
 *   L. closing one of two descriptors of the description keeps the signals coming.
 * The test puts itself in its own process group first, so a -pgrp owner signals only it. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long op(const char *p, long fl) { long r = open(p, (int)fl, 0600); return r < 0 ? -errno : r; }
static long wr(int fd) { long r = write(fd, "x", 1); return r < 0 ? -errno : r; }
static long rd(int fd) { char c; long r = read(fd, &c, 1); return r < 0 ? -errno : r; }
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
static long my_pgrp(void) { return getpgrp(); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long op(const char *p, long fl) { return open(p, fl, 0600); }
static long wr(int fd) { return write(fd, "x", 1); }
static long rd(int fd) { char c; return read(fd, &c, 1); }
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
static long my_pgrp(void) { return getpgid(0); }
#endif

#define C_GETFL 3
#define C_SETFL 4
#define C_SETOWN 8
#define C_SETSIG 10
#define A_SYNC 0x2000
#define S_IO 29
#define S_RT 40
static int failures;
static char msg[260];
static void check(int ok, const char *w) {
    print(ok ? "hello320:   ok   " : "hello320:   FAIL ");
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
static long setasync(int fd, int on) { long cur = fl(fd); return fc(fd, C_SETFL, on ? (cur | A_SYNC) : (cur & ~A_SYNC)); }

int main(void) {
    print("hello320: O_ASYNC on a pipe\n");
    handle(S_IO);
    handle(S_RT);
    ignore_pipe();
    setpgid(0, 0);
    long me = getpid(), pg = my_pgrp();

    int p[2] = { -1, -1 };
    pipe(p);
    long a0 = fc(p[0], C_SETFL, A_SYNC), a1 = fc(p[1], C_SETFL, A_SYNC), a2 = fl(p[0]), a3 = fl(p[1]);
    reset();
    long a4 = wr(p[1]), a5 = rd(p[0]);
    quiet();
    snprintf(msg, sizeof msg, "A: F_SETFL O_ASYNC on both ends reads back (%ld %ld 0x%lx 0x%lx; no owner: %ld %ld hits %ld)", a0, a1, a2, a3, a4, a5, hits);
    check(a0 == 0 && a1 == 0 && a2 == 0x2000 && a3 == 0x2001 && a4 == 1 && a5 == 1 && hits == 0, msg);

    fc(p[0], C_SETOWN, me);
    reset();
    wr(p[1]);
    long b0 = hits, b1 = g_sig, b2 = g_code, b3 = g_band, b4 = g_fd;
    wr(p[1]);
    long b5 = hits;
    rd(p[0]);
    rd(p[0]);
    snprintf(msg, sizeof msg, "B: signal 0: each write sends a plain SIGIO (hits %ld sig %ld code %ld band %ld fd %ld; second write hits %ld)", b0, b1, b2, b3,
             b4, b5);
    check(b0 == 1 && b1 == S_IO && b2 == 0x80 && b3 == 0 && b4 == 0 && b5 == 2, msg);

    fc(p[0], C_SETSIG, S_RT);
    reset();
    wr(p[1]);
    snprintf(msg, sizeof msg, "C: F_SETSIG 40: a write sends POLL_IN, band 0x41, the read fd (hits %ld sig %ld code %ld band 0x%lx fd %ld/%d)", hits, g_sig,
             g_code, g_band, g_fd, p[0]);
    check(hits == 1 && g_sig == S_RT && g_code == 1 && g_band == 0x41 && g_fd == p[0], msg);
    rd(p[0]);

    fc(p[0], C_SETOWN, 0);
    fc(p[1], C_SETOWN, me);
    fc(p[1], C_SETSIG, S_RT);
    reset();
    wr(p[1]);
    quiet();
    long d0 = hits;
    reset();
    rd(p[0]);
    snprintf(msg, sizeof msg, "D: a read signals the write end with POLL_OUT, band 0x304 (write hits %ld; read hits %ld sig %ld code %ld band 0x%lx fd %ld/%d)", d0,
             hits, g_sig, g_code, g_band, g_fd, p[1]);
    check(d0 == 0 && hits == 1 && g_sig == S_RT && g_code == 2 && g_band == 0x304 && g_fd == p[1], msg);

    fc(p[0], C_SETOWN, me);
    reset();
    close(p[1]);
    long e0 = hits, e1 = g_code, e2 = g_fd;
    reset();
    long e3 = rd(p[0]);
    quiet();
    snprintf(msg, sizeof msg, "E: closing the writer signals the reader with POLL_IN; EOF signals nobody (hits %ld code %ld fd %ld/%d; eof %ld hits %ld)", e0, e1,
             e2, p[0], e3, hits);
    check(e0 == 1 && e1 == 1 && e2 == p[0] && e3 == 0 && hits == 0, msg);
    close(p[0]);
    pipe(p);
    setasync(p[1], 1);
    fc(p[1], C_SETOWN, me);
    fc(p[1], C_SETSIG, S_RT);
    reset();
    close(p[0]);
    long f0 = hits, f1 = g_code, f2 = g_fd;
    reset();
    long f3 = wr(p[1]);
    quiet();
    snprintf(msg, sizeof msg, "F: closing the reader signals the writer with POLL_OUT; EPIPE signals nobody (hits %ld code %ld fd %ld/%d; write %ld hits %ld)", f0,
             f1, f2, p[1], f3, hits);
    check(f0 == 1 && f1 == 2 && f2 == p[1] && f3 == -32 && hits == 0, msg);
    close(p[1]);

    pipe(p);
    setasync(p[0], 1);
    fc(p[0], C_SETOWN, me);
    long g0 = setasync(p[0], 0), g1 = fl(p[0]);
    reset();
    wr(p[1]);
    quiet();
    rd(p[0]);
    snprintf(msg, sizeof msg, "G: clearing O_ASYNC stops the signals (%ld 0x%lx hits %ld)", g0, g1, hits);
    check(g0 == 0 && g1 == 0 && hits == 0, msg);

    setasync(p[0], 1);
    int dd = dup(p[0]);
    long h0 = fl(dd) & A_SYNC;
    setasync(dd, 0);
    long h1 = fl(p[0]) & A_SYNC;
    setasync(p[0], 1);
    long hc = fork();
    if (hc == 0) _exit((fl(p[0]) & A_SYNC) && setasync(p[0], 0) == 0 ? 0 : 1);
    int hst = -1;
    while (waitpid(hc, &hst, 0) != hc) {}
    long h2 = fl(p[0]) & A_SYNC, h3 = fl(dd) & A_SYNC;
    snprintf(msg, sizeof msg, "H: O_ASYNC belongs to the description (dup sees 0x%lx; dup clears: 0x%lx; child %d clears: 0x%lx 0x%lx)", h0, h1, hst, h2, h3);
    check(h0 == A_SYNC && h1 == 0 && hst == 0 && h2 == 0 && h3 == 0, msg);

    setasync(p[0], 1);
    reset();
    long ic = fork();
    if (ic == 0) _exit(wr(p[1]) == 1 ? 0 : 1);
    int ist = -1;
    while (waitpid(ic, &ist, 0) != ic) {}
    settle();
    snprintf(msg, sizeof msg, "I: a child's write signals the owner (child %d hits %ld sig %ld)", ist, hits, g_sig);
    check(ist == 0 && hits == 1 && g_sig == S_IO, msg);
    rd(p[0]);

    fc(p[0], C_SETOWN, -pg);
    reset();
    wr(p[1]);
    settle();
    snprintf(msg, sizeof msg, "J: a -pgrp owner receives the signal (hits %ld sig %ld)", hits, g_sig);
    check(hits == 1 && g_sig == S_IO, msg);
    rd(p[0]);
    fc(p[0], C_SETOWN, me);

    close(p[0]);
    reset();
    wr(p[1]);
    settle();
    long l0 = hits;
    rd(dd);
    close(dd);
    close(p[1]);
    snprintf(msg, sizeof msg, "L: closing one of two descriptors keeps the signals (hits %ld)", l0);
    check(l0 == 1, msg);

    int dn = (int)op("/dev/null", 2);
    long k0 = fc(dn, C_SETFL, A_SYNC), k1 = fl(dn) & A_SYNC;
    close(dn);
    int rf = (int)op("/tmp/h320a", 2 | O_CREAT | O_TRUNC);
    long k2 = fc(rf, C_SETFL, A_SYNC), k3 = fl(rf) & A_SYNC;
    close(rf);
    unlink("/tmp/h320a");
    snprintf(msg, sizeof msg, "K: /dev/null and a regular file accept O_ASYNC but do not keep it (%ld 0x%lx; %ld 0x%lx)", k0, k1, k2, k3);
    check(dn >= 0 && rf >= 0 && k0 == 0 && k1 == 0 && k2 == 0 && k3 == 0, msg);

    print(failures == 0 ? "hello320: PASS\n" : "hello320: FAIL\n");
    return failures;
}
