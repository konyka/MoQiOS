/* hello318: fcntl F_SETOWN (8), F_GETOWN (9), F_SETSIG (10), F_GETSIG (11) and the signal a lease break sends (Linux fs/fcntl.c
 * f_setown, f_getown, f_owner_sig, send_sigio_to_task; fs/locks.c lease_setup, lease_modify, lease_break_callback).
 * Measured on the host (build with -DHOST):
 *   A. a fresh open has owner 0 and signal 0;
 *   B. F_SETSIG accepts 0..64 (64 reads back), 65, -1 and 1000 are EINVAL and leave it; the argument is an int (2^32 + 5 sets 5);
 *   C. F_SETOWN of the caller's pid reads back the pid, of -pgrp reads back -pgrp; an unknown pid or group is ESRCH and leaves
 *      the owner; INT_MIN is EINVAL; 0 clears it; the argument is an int (2^32 + pid sets pid);
 *   D. owner and signal belong to the open file description: a dup and a forked child see them, another open of the file does not;
 *   E. F_SETLEASE makes the caller the owner when there is none and keeps an owner already set (-pgrp: the break reaches us);
 *   F. with F_SETSIG 35 a break delivers signal 35 with si_code POLL_MSG (3), si_band POLLIN|POLLRDNORM|POLLMSG (0x441) and
 *      si_fd the descriptor the lease was taken through;
 *   G. with signal 0 the break sends a plain SIGIO (si_code SI_KERNEL, si_fd 0);
 *   H. with SIGUSR1 the break sends SIGUSR1 with POLL_MSG and the fd;
 *   I. F_UNLCK clears owner and signal; F_UNLCK with no lease (EAGAIN) leaves the signal;
 *   J. with the owner cleared while the lease is held, a break signals nobody (the opener still gets EAGAIN);
 *   K. F_SETSIG while the lease is held changes the signal the break sends;
 *   L. a pipe accepts both and reads them back; a bad descriptor is EBADF for all four.
 * The test puts itself in its own process group first, so a -pgrp owner signals only it (and its children). */
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
/* F_GETOWN returns -pgrp for a group owner, so only -1 means an error. */
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long op(const char *p, long fl) { long r = open(p, (int)fl, 0600); return r < 0 ? -errno : r; }
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
static long my_pgrp(void) { return getpgrp(); }
static const char *F = "/tmp/h318a";
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long op(const char *p, long fl) { return open(p, fl, 0600); }
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
static long my_pgrp(void) { return getpgid(0); }
static const char *F = "h318a.txt";
#endif

#define C_SETOWN 8
#define C_GETOWN 9
#define C_SETSIG 10
#define C_GETSIG 11
#define C_SETLEASE 1024
#define C_GETLEASE 1025
#define T_RDLCK 0
#define T_UNLCK 2
#define M_RO 0
#define M_WO 1
#define M_RW 2
#define M_NB 0x800
#define S_IO 29
#define S_USR1 10
#define S_RT 35

static int failures;
static char msg[240];
static void check(int ok, const char *w) {
    print(ok ? "hello318:   ok   " : "hello318:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void reset(void) {
    hits = 0;
    g_sig = g_code = g_band = g_fd = -9;
}
/* A forked child opens F for writing without blocking (breaking any lease): 0 or the errno. Waits briefly for the signal. */
static long breaker(void) {
    long c = fork();
    if (c == 0) {
        long w = op(F, M_WO | M_NB);
        _exit(w < 0 ? (int)-w : 0);
    }
    int st = 0;
    while (waitpid(c, &st, 0) != c) {}
    for (int i = 0; i < 40 && hits == 0; i++) usleep(5000);
    return (st >> 8) & 0xff;
}

int main(void) {
    print("hello318: F_SETOWN / F_GETOWN / F_SETSIG / F_GETSIG\n");
    handle(S_IO);
    handle(S_USR1);
    handle(S_RT);
    setpgid(0, 0); /* a group of our own: the -pgrp owner in C and E must not signal whoever started us */
    long me = getpid(), pg = my_pgrp();
    long fcr = op(F, M_RW | O_CREAT | O_TRUNC);
    if (fcr >= 0) close((int)fcr);
    int fd = (int)op(F, M_RO);

    long a0 = fc(fd, C_GETOWN, 0), a1 = fc(fd, C_GETSIG, 0);
    snprintf(msg, sizeof msg, "A: a fresh open has owner 0 and signal 0 (%ld %ld)", a0, a1);
    check(fd >= 0 && a0 == 0 && a1 == 0, msg);

    long b0 = fc(fd, C_SETSIG, 0), b1 = fc(fd, C_SETSIG, 64), b2 = fc(fd, C_GETSIG, 0);
    long b3 = fc(fd, C_SETSIG, 65), b4 = fc(fd, C_SETSIG, -1), b5 = fc(fd, C_SETSIG, 1000), b6 = fc(fd, C_GETSIG, 0);
    long b7 = fc(fd, C_SETSIG, 0x100000005L), b8 = fc(fd, C_GETSIG, 0);
    fc(fd, C_SETSIG, 0);
    snprintf(msg, sizeof msg, "B: F_SETSIG takes 0..64 (%ld %ld get %ld; %ld %ld %ld get %ld; 2^32+5 %ld get %ld)", b0, b1, b2, b3, b4, b5, b6, b7, b8);
    check(b0 == 0 && b1 == 0 && b2 == 64 && b3 == -22 && b4 == -22 && b5 == -22 && b6 == 64 && b7 == 0 && b8 == 5, msg);

    long c0 = fc(fd, C_SETOWN, me), c1 = fc(fd, C_GETOWN, 0);
    long c2 = fc(fd, C_SETOWN, -pg), c3 = fc(fd, C_GETOWN, 0);
    long c4 = fc(fd, C_SETOWN, 999999), c5 = fc(fd, C_SETOWN, -999999), c6 = fc(fd, C_GETOWN, 0);
    long c7 = fc(fd, C_SETOWN, -0x7fffffffL - 1);
    long c8 = fc(fd, C_SETOWN, 0), c9 = fc(fd, C_GETOWN, 0);
    long c10 = fc(fd, C_SETOWN, 0x100000000L + me), c11 = fc(fd, C_GETOWN, 0);
    fc(fd, C_SETOWN, 0);
    snprintf(msg, sizeof msg, "C: F_SETOWN pid, -pgrp, unknown, INT_MIN, 0 (%ld %ld; %ld %ld; %ld %ld %ld; %ld; %ld %ld; 2^32+pid %ld %ld)", c0, c1, c2,
             c3, c4, c5, c6, c7, c8, c9, c10, c11);
    check(c0 == 0 && c1 == me && c2 == 0 && c3 == -pg && c4 == -3 && c5 == -3 && c6 == -pg && c7 == -22 && c8 == 0 && c9 == 0 && c10 == 0 &&
              c11 == me,
          msg);

    fc(fd, C_SETOWN, me);
    fc(fd, C_SETSIG, 40);
    int dd = dup(fd);
    long d0 = fc(dd, C_GETOWN, 0), d1 = fc(dd, C_GETSIG, 0);
    close(dd);
    int other = (int)op(F, M_RO);
    long d2 = fc(other, C_GETOWN, 0), d3 = fc(other, C_GETSIG, 0);
    close(other);
    long dc = fork();
    if (dc == 0) _exit(fc(fd, C_GETOWN, 0) == me && fc(fd, C_GETSIG, 0) == 40 ? 0 : 1);
    int dst = -1;
    while (waitpid(dc, &dst, 0) != dc) {}
    fc(fd, C_SETOWN, 0);
    fc(fd, C_SETSIG, 0);
    snprintf(msg, sizeof msg, "D: owner and signal belong to the description (dup %ld %ld, other open %ld %ld, child %d)", d0, d1, d2, d3, dst);
    check(d0 == me && d1 == 40 && d2 == 0 && d3 == 0 && dst == 0, msg);

    long e0 = fc(fd, C_SETLEASE, T_RDLCK), e1 = fc(fd, C_GETOWN, 0);
    fc(fd, C_SETLEASE, T_UNLCK);
    fc(fd, C_SETOWN, -pg);
    long e2 = fc(fd, C_SETLEASE, T_RDLCK), e3 = fc(fd, C_GETOWN, 0);
    reset();
    long e4 = breaker();
    long eh = hits, es = g_sig;
    fc(fd, C_SETLEASE, T_UNLCK);
    snprintf(msg, sizeof msg, "E: F_SETLEASE sets the owner only when there is none (%ld %ld; %ld %ld; break %ld hits %ld sig %ld)", e0, e1, e2, e3, e4,
             eh, es);
    check(e0 == 0 && e1 == me && e2 == 0 && e3 == -pg && e4 == 11 && eh == 1 && es == S_IO, msg);

    long f0 = fc(fd, C_SETSIG, S_RT), f1 = fc(fd, C_SETLEASE, T_RDLCK);
    reset();
    long f2 = breaker();
    snprintf(msg, sizeof msg, "F: F_SETSIG 35: the break sends 35 with POLL_MSG, the band and the fd (%ld %ld %ld: hits %ld sig %ld code %ld band 0x%lx fd %ld/%d)",
             f0, f1, f2, hits, g_sig, g_code, g_band, g_fd, fd);
    check(f0 == 0 && f1 == 0 && f2 == 11 && hits == 1 && g_sig == S_RT && g_code == 3 && g_band == 0x441 && g_fd == fd, msg);
    fc(fd, C_SETLEASE, T_UNLCK);

    fc(fd, C_SETSIG, 0);
    fc(fd, C_SETLEASE, T_RDLCK);
    reset();
    long g0 = breaker();
    snprintf(msg, sizeof msg, "G: signal 0: a plain SIGIO (%ld: hits %ld sig %ld code %ld fd %ld)", g0, hits, g_sig, g_code, g_fd);
    check(g0 == 11 && hits == 1 && g_sig == S_IO && g_code == 0x80 && g_fd == 0, msg);
    fc(fd, C_SETLEASE, T_UNLCK);

    fc(fd, C_SETSIG, S_USR1);
    fc(fd, C_SETLEASE, T_RDLCK);
    reset();
    long h0 = breaker();
    snprintf(msg, sizeof msg, "H: SIGUSR1 with POLL_MSG and the fd (%ld: hits %ld sig %ld code %ld fd %ld)", h0, hits, g_sig, g_code, g_fd);
    check(h0 == 11 && hits == 1 && g_sig == S_USR1 && g_code == 3 && g_fd == fd, msg);

    long i0 = fc(fd, C_SETLEASE, T_UNLCK), i1 = fc(fd, C_GETOWN, 0), i2 = fc(fd, C_GETSIG, 0);
    fc(fd, C_SETSIG, 12);
    long i3 = fc(fd, C_SETLEASE, T_UNLCK), i4 = fc(fd, C_GETSIG, 0);
    fc(fd, C_SETSIG, 0);
    snprintf(msg, sizeof msg, "I: F_UNLCK clears owner and signal (%ld %ld %ld; no lease %ld keeps %ld)", i0, i1, i2, i3, i4);
    check(i0 == 0 && i1 == 0 && i2 == 0 && i3 == -11 && i4 == 12, msg);

    fc(fd, C_SETLEASE, T_RDLCK);
    long j0 = fc(fd, C_SETOWN, 0);
    reset();
    long j1 = breaker();
    snprintf(msg, sizeof msg, "J: owner cleared while held: the break signals nobody (%ld %ld hits %ld)", j0, j1, hits);
    check(j0 == 0 && j1 == 11 && hits == 0, msg);
    fc(fd, C_SETLEASE, T_UNLCK);

    fc(fd, C_SETLEASE, T_RDLCK);
    long k0 = fc(fd, C_SETSIG, S_RT);
    reset();
    long k1 = breaker();
    snprintf(msg, sizeof msg, "K: F_SETSIG while held changes the break's signal (%ld %ld hits %ld sig %ld)", k0, k1, hits, g_sig);
    check(k0 == 0 && k1 == 11 && hits == 1 && g_sig == S_RT, msg);
    fc(fd, C_SETLEASE, T_UNLCK);
    close(fd);

    int p[2] = { -1, -1 };
    pipe(p);
    long l0 = fc(p[0], C_SETSIG, S_USR1), l1 = fc(p[0], C_GETSIG, 0), l2 = fc(p[0], C_SETOWN, me), l3 = fc(p[0], C_GETOWN, 0);
    close(p[0]);
    close(p[1]);
    long l4 = fc(99, C_GETOWN, 0), l5 = fc(99, C_SETOWN, me), l6 = fc(99, C_GETSIG, 0), l7 = fc(99, C_SETSIG, 1);
    snprintf(msg, sizeof msg, "L: a pipe takes both; a bad fd is EBADF (%ld %ld %ld %ld; %ld %ld %ld %ld)", l0, l1, l2, l3, l4, l5, l6, l7);
    check(l0 == 0 && l1 == S_USR1 && l2 == 0 && l3 == me && l4 == -9 && l5 == -9 && l6 == -9 && l7 == -9, msg);

    unlink(F);
    print(failures == 0 ? "hello318: PASS\n" : "hello318: FAIL\n");
    return failures;
}
