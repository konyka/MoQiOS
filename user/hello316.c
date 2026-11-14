/* hello316: file leases (F_SETLEASE 1024, F_GETLEASE 1025). A lease belongs to the open file description; the kernel sends
 * the holder SIGIO when another open (or truncate) conflicts with it and holds that open until the holder gives the lease up
 * or downgrades it (Linux fs/locks.c: lease_open_conflict, generic_add_lease, __break_lease, target_leasetype).
 * Measured on the host (build with -DHOST; SIGIO's default action ends the process, so a handler is installed first):
 *   A. a read lease on the only open of the file: 0, F_GETLEASE 0; upgrading it to a write lease 0, F_GETLEASE 1; F_UNLCK 0,
 *      then F_GETLEASE 2; F_UNLCK with no lease is EAGAIN;
 *   B. a read lease while the file is open for writing (also through the caller's own O_RDWR) is EAGAIN; a write lease while
 *      another open exists is EAGAIN, on the only open (O_RDWR) it is 0 and F_GETLEASE says 1; two opens can each hold a read
 *      lease, and then a write lease on either is EAGAIN;
 *   C. an unknown lease type (7), a pipe and a directory are EINVAL; F_GETLEASE on a pipe is 2;
 *   D. under a read lease a child's O_WRONLY|O_NONBLOCK open is EAGAIN, the holder gets SIGIO once and F_GETLEASE then says 2
 *      (unlock pending); a child's O_RDONLY|O_NONBLOCK open succeeds;
 *   E. a child's blocking O_WRONLY open waits until the holder's SIGIO handler unlocks, then succeeds;
 *   F. under a write lease a child's O_RDONLY|O_NONBLOCK open is EAGAIN and the handler sees F_GETLEASE 0 (downgrade pending);
 *      F_RDLCK then succeeds; with the write lease back, a blocking read open succeeds once the handler downgrades;
 *   G. a child's truncate() breaks a read lease (SIGIO once) and succeeds after the handler unlocks;
 *   H. a dup shares the lease, which stays when one copy is closed and goes with the last close; another open of the file
 *      reports 2 and F_UNLCK there is EAGAIN;
 *   I. the holder's own O_WRONLY|O_NONBLOCK open is EAGAIN and its SIGIO has run when open returns;
 *   J. two read leases held by one process: one conflicting open delivers SIGIO once;
 *   K. ftruncate does not break a lease (Linux do_ftruncate has no break_lease: the fd is already open for writing, so any
 *      lease it can coexist with is its own): under a write lease on the only O_RDWR open, ftruncate there and in a forked
 *      child through the inherited fd both return 0, F_GETLEASE stays 1 and no SIGIO arrives. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long do_fcntl(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r < 0 ? -errno : r; }
static long op(const char *p, long fl) { long r = open(p, (int)fl, 0600); return r < 0 ? -errno : r; }
static long trunc0(const char *p) { long r = truncate(p, 0); return r < 0 ? -errno : r; }
static long mkd(const char *p) { long r = mkdir(p, 0700); return r < 0 ? -errno : r; }
static const char *F = "/tmp/h316a";
static const char *D = "/tmp/h316d";
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
static long do_fcntl(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long op(const char *p, long fl) { return open(p, fl, 0600); }
static long trunc0(const char *p) { return truncate(p, 0); }
static long mkd(const char *p) { return mkdir(p, 0700); }
static const char *F = "/tmp/h316a";
static const char *D = "/tmp/h316d";
static long now_ms(void) { long ts[2] = { 0, 0 }; syscall2(SYS_clock_gettime, 1, (long)ts); return ts[0] * 1000 + ts[1] / 1000000; }
#endif

#define C_SETLEASE 1024
#define C_GETLEASE 1025
#define T_RDLCK 0
#define T_WRLCK 1
#define T_UNLCK 2
#define M_RO 0
#define M_WO 1
#define M_RW 2
#define M_NB 0x800

static int failures;
static char msg[240];
static void check(int ok, const char *w) {
    print(ok ? "hello316:   ok   " : "hello316:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

/* The SIGIO handler: mode 0 only counts, 1 gives the lease on lease_fd up, 2 downgrades it to a read lease. */
static volatile int hits, mode, lease_fd = -1, seen = -9;
static void on_sigio(int s) {
    (void)s;
    hits++;
    seen = (int)do_fcntl(lease_fd, C_GETLEASE, 0);
    if (mode == 1) do_fcntl(lease_fd, C_SETLEASE, T_UNLCK);
    if (mode == 2) do_fcntl(lease_fd, C_SETLEASE, T_RDLCK);
}
static long setl(int fd, long t) { return do_fcntl(fd, C_SETLEASE, t); }
static long getl(int fd) { return do_fcntl(fd, C_GETLEASE, 0); }
static void wait_hits(int n) {
    for (int i = 0; i < 200 && hits < n; i++) usleep(5000);
}
static void arm(int fd, int m) {
    lease_fd = fd;
    mode = m;
    hits = 0;
    seen = -9;
}

/* A forked child opens F with flags (kind 0) or truncates it (kind 1): 0 or the negative errno. */
static long child(int kind, long flags) {
    long c = fork();
    if (c == 0) {
        long r = kind == 0 ? op(F, flags) : trunc0(F);
        if (kind == 0 && r >= 0) {
            close((int)r);
            r = 0;
        }
        _exit(r < 0 ? (int)-r : 0);
    }
    int st = 0;
    while (waitpid(c, &st, 0) != c) {}
    return -(long)((st >> 8) & 0xff);
}
int main(void) {
    print("hello316: file leases (F_SETLEASE, F_GETLEASE)\n");
    signal(SIGIO, on_sigio);
    rmdir(D);
    long fc = op(F, M_RW | O_CREAT | O_TRUNC);
    if (fc >= 0) close((int)fc);

    int fd = (int)op(F, M_RO);
    long a1 = setl(fd, T_RDLCK), a2 = getl(fd);
    long a3 = setl(fd, T_WRLCK), a4 = getl(fd);
    long a5 = setl(fd, T_UNLCK), a6 = getl(fd);
    long a7 = setl(fd, T_UNLCK);
    snprintf(msg, sizeof msg, "A: read lease, upgrade, unlock, unlock with none (%ld %ld %ld %ld %ld %ld %ld)", a1, a2, a3, a4, a5, a6, a7);
    check(fc >= 0 && fd >= 0 && a1 == 0 && a2 == 0 && a3 == 0 && a4 == 1 && a5 == 0 && a6 == 2 && a7 == -11, msg);

    int fw = (int)op(F, M_WO);
    long b1 = setl(fd, T_RDLCK);
    close(fw);
    int frw = (int)op(F, M_RW);
    long b2 = setl(frw, T_RDLCK), b3 = setl(frw, T_WRLCK);
    close(fd);
    long b4 = setl(frw, T_WRLCK), b5 = getl(frw);
    setl(frw, T_UNLCK);
    close(frw);
    int r1 = (int)op(F, M_RO), r2 = (int)op(F, M_RO);
    long b6 = setl(r1, T_RDLCK), b7 = setl(r2, T_RDLCK), b8 = setl(r1, T_WRLCK);
    setl(r1, T_UNLCK);
    setl(r2, T_UNLCK);
    close(r1);
    close(r2);
    snprintf(msg, sizeof msg, "B: lease conflicts with existing opens (%ld %ld %ld %ld %ld %ld %ld %ld)", b1, b2, b3, b4, b5, b6, b7, b8);
    check(b1 == -11 && b2 == -11 && b3 == -11 && b4 == 0 && b5 == 1 && b6 == 0 && b7 == 0 && b8 == -11, msg);

    fd = (int)op(F, M_RO);
    int p[2] = { -1, -1 };
    pipe(p);
    long c0 = mkd(D);
    int dfd = (int)op(D, M_RO | O_DIRECTORY);
    long c1 = setl(fd, 7), c2 = setl(p[0], T_RDLCK), c3 = getl(p[0]), c4 = setl(dfd, T_RDLCK);
    close(p[0]);
    close(p[1]);
    close(dfd);
    snprintf(msg, sizeof msg, "C: bad type, pipe and directory are EINVAL (%ld %ld %ld %ld %ld)", c0, c1, c2, c3, c4);
    check(c0 == 0 && dfd >= 0 && c1 == -22 && c2 == -22 && c3 == 2 && c4 == -22, msg);
    long d0 = setl(fd, T_RDLCK);
    arm(fd, 0);
    long d1 = child(0, M_WO | M_NB);
    wait_hits(1);
    long d2 = getl(fd), dh = hits;
    long d3 = child(0, M_RO | M_NB);
    long d4 = setl(fd, T_UNLCK);
    snprintf(msg, sizeof msg, "D: a non-blocking write open breaks a read lease (%ld %ld sigio %ld lease %ld, read open %ld, unlock %ld)", d0, d1,
             dh, d2, d3, d4);
    check(d0 == 0 && d1 == -11 && dh == 1 && d2 == 2 && d3 == 0 && d4 == 0, msg);

    long e0 = setl(fd, T_RDLCK);
    arm(fd, 1);
    long t0 = now_ms();
    long e1 = child(0, M_WO);
    long ems = now_ms() - t0;
    long e2 = getl(fd);
    snprintf(msg, sizeof msg, "E: a blocking write open waits for the holder to unlock (%ld %ld sigio %d lease %ld, %ld ms)", e0, e1, hits, e2, ems);
    check(e0 == 0 && e1 == 0 && hits == 1 && e2 == 2 && ems < 5000, msg);

    long f0 = setl(fd, T_WRLCK);
    arm(fd, 0);
    long f1 = child(0, M_RO | M_NB);
    wait_hits(1);
    long fs = seen, fh = hits;
    long f2 = setl(fd, T_RDLCK), f3 = getl(fd);
    setl(fd, T_UNLCK);
    long f4 = setl(fd, T_WRLCK);
    arm(fd, 2);
    long f5 = child(0, M_RO);
    long f6 = getl(fd), fh2 = hits;
    setl(fd, T_UNLCK);
    snprintf(msg, sizeof msg, "F: a read open breaks a write lease to a read lease (%ld %ld sigio %ld seen %ld, %ld %ld; %ld %ld %ld sigio %ld)", f0,
             f1, fh, fs, f2, f3, f4, f5, f6, fh2);
    check(f0 == 0 && f1 == -11 && fh == 1 && fs == 0 && f2 == 0 && f3 == 0 && f4 == 0 && f5 == 0 && f6 == 0 && fh2 == 1, msg);

    long g0 = setl(fd, T_RDLCK);
    arm(fd, 1);
    long g1 = child(1, 0);
    snprintf(msg, sizeof msg, "G: truncate breaks a read lease (%ld %ld sigio %d lease %ld)", g0, g1, hits, getl(fd));
    check(g0 == 0 && g1 == 0 && hits == 1 && getl(fd) == 2, msg);

    arm(fd, 0);
    long h0 = setl(fd, T_RDLCK);
    int dd = dup(fd);
    close(fd);
    long h1 = getl(dd);
    int other = (int)op(F, M_RO);
    long h2 = getl(other), h3 = setl(other, T_UNLCK);
    close(other);
    long h4 = child(0, M_WO | M_NB);
    close(dd);
    long h5 = child(0, M_WO | M_NB);
    snprintf(msg, sizeof msg, "H: a dup shares the lease until the last close (%ld %ld other %ld %ld, %ld then %ld, sigio %d)", h0, h1, h2, h3, h4,
             h5, hits);
    check(h0 == 0 && h1 == 0 && h2 == 2 && h3 == -11 && h4 == -11 && h5 == 0, msg);

    fd = (int)op(F, M_RO);
    long i0 = setl(fd, T_RDLCK);
    arm(fd, 0);
    long i1 = op(F, M_WO | M_NB);
    long ih = hits;
    if (i1 >= 0) close((int)i1);
    long i2 = setl(fd, T_UNLCK);
    close(fd);
    snprintf(msg, sizeof msg, "I: the holder's own non-blocking write open is EAGAIN (%ld %ld sigio %ld, unlock %ld)", i0, i1, ih, i2);
    check(i0 == 0 && i1 == -11 && ih == 1 && i2 == 0, msg);

    r1 = (int)op(F, M_RO);
    r2 = (int)op(F, M_RO);
    long j0 = setl(r1, T_RDLCK), j1 = setl(r2, T_RDLCK);
    arm(r1, 0);
    long j2 = child(0, M_WO | M_NB);
    wait_hits(1);
    usleep(50000);
    long jh = hits;
    setl(r1, T_UNLCK);
    setl(r2, T_UNLCK);
    close(r1);
    close(r2);
    snprintf(msg, sizeof msg, "J: two read leases of one process, one conflicting open, one SIGIO (%ld %ld %ld sigio %ld)", j0, j1, j2, jh);
    check(j0 == 0 && j1 == 0 && j2 == -11 && jh == 1, msg);

    fd = (int)op(F, M_RW);
    long k0 = setl(fd, T_WRLCK);
    arm(fd, 0);
    long k1 = ftruncate(fd, 2);
    long kc = fork();
    if (kc == 0) _exit(ftruncate(fd, 1) == 0 ? 0 : 1);
    int kst = -1;
    while (waitpid(kc, &kst, 0) != kc) {}
    usleep(50000);
    long k2 = getl(fd), kh = hits;
    setl(fd, T_UNLCK);
    close(fd);
    snprintf(msg, sizeof msg, "K: ftruncate does not break the caller's write lease (%ld %ld child %d lease %ld sigio %ld)", k0, k1, (kst >> 8) & 0xff,
             k2, kh);
    check(k0 == 0 && k1 == 0 && kst == 0 && k2 == 1 && kh == 0, msg);

    unlink(F);
    rmdir(D);
    print(failures == 0 ? "hello316: PASS\n" : "hello316: FAIL\n");
    return failures;
}
