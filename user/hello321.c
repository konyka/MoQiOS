/* hello321: fcntl F_SETOWN_EX (15) and F_GETOWN_EX (16) (Linux fs/fcntl.c f_setown_ex, f_getown_ex, send_sigio).
 * Measured on the host (build with -DHOST):
 *   A. a fresh open reads back type F_OWNER_TID (0) and pid 0;
 *   B. F_SETOWN of a pid reads back F_OWNER_PID (1), of -pgrp F_OWNER_PGRP (2) with the positive group id;
 *   C. F_SETOWN_EX TID / PID / PGRP succeed; F_GETOWN reports the pid, the pid, and -pgrp;
 *   D. a type other than 0..2 is EINVAL and leaves the owner;
 *   E. an unknown id, or a negative one, is ESRCH for every type and leaves the owner;
 *   F. id 0 is accepted for every type and keeps the type; F_SETOWN 0 afterwards makes the type PID;
 *   G. a bad pointer is EFAULT for both, a bad descriptor EBADF;
 *   H. the owner and its type belong to the open file description (a dup and a forked child see them);
 *   I. F_SETLEASE with no owner sets F_OWNER_PID; with a TID owner already set it keeps it;
 *   J. an O_ASYNC pipe with a TID owner signals that thread only: blocked there, it waits there (no other thread takes it);
 *   K. a PID owner gets a process-directed signal: another thread takes it while the named one blocks it, the named one otherwise. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long op(const char *p, long fl) { long r = open(p, (int)fl, 0600); return r < 0 ? -errno : r; }
static long my_tid(void) { return syscall(SYS_gettid); }
static void mask_io(int block) {
    sigset_t m;
    sigemptyset(&m);
    sigaddset(&m, SIGIO);
    pthread_sigmask(block ? SIG_BLOCK : SIG_UNBLOCK, &m, 0);
}
static long my_pgrp(void) { return getpgrp(); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/pthread.h"
#include "../lib/moqi_libc/include/time.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long op(const char *p, long fl) { return open(p, fl, 0600); }
static long my_tid(void) { return syscall0(SYS_gettid); }
static void mask_io(int block) {
    unsigned long m = 1UL << (29 - 1);
    syscall4(SYS_sigprocmask, block ? 0 : 1, (long)&m, 0, 8);
}
static long my_pgrp(void) { return getpgid(0); }
#endif

struct fo { int type; int pid; };
#define C_SETFL 4
#define C_SETOWN 8
#define C_GETOWN 9
#define C_SETOWN_EX 15
#define C_GETOWN_EX 16
#define C_SETLEASE 1024
#define A_SYNC 0x2000

static int failures;
static char msg[260];
static void check(int ok, const char *w) {
    print(ok ? "hello321:   ok   " : "hello321:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long setex(int fd, int type, long pid) { struct fo s = { type, (int)pid }; return fc(fd, C_SETOWN_EX, (long)&s); }
static struct fo getex(int fd) { struct fo o = { -9, -9 }; fc(fd, C_GETOWN_EX, (long)&o); return o; }

static volatile long hits, got_tid, helper_tid, stop;
static void on_io(int s) { (void)s; got_tid = my_tid(); hits++; }
static void *helper(void *a) {
    mask_io(a != 0);
    helper_tid = my_tid();
    while (!stop) usleep(1000);
    return 0;
}
#ifdef HOST
static void handle_io(void) { signal(SIGIO, on_io); }
#else
static void handle_io(void) {
    struct ksigaction sa = { on_io, 0, (void *)0, 0 };
    sigaction(29, &sa, (struct ksigaction *)0);
}
#endif

/* Start a helper thread (blocking SIGIO if asked), point the pipe's owner at (type, pid; -1 = the helper), block SIGIO in the
 * main thread if asked, write and read one byte, wait, unblock, and report which thread ran the handler: 1 main, 2 helper,
 * 0 none, 3 several. */
static int p[2];
static long route(int type, long pid, int main_blocks, int helper_blocks, long *set_rc) {
    pthread_t th;
    helper_tid = 0;
    stop = 0;
    pthread_create(&th, 0, helper, (void *)(long)helper_blocks);
    while (!helper_tid) usleep(1000);
    mask_io(main_blocks);
    *set_rc = setex(p[0], type, pid == -1 ? helper_tid : pid);
    hits = 0;
    got_tid = 0;
    char c = 'x';
    write(p[1], &c, 1);
    read(p[0], &c, 1);
    for (int i = 0; i < 40 && hits == 0; i++) usleep(5000);
    mask_io(0);
    for (int i = 0; i < 40 && hits == 0; i++) usleep(5000);
    long main_tid = my_tid(), h = helper_tid, n = hits, g = got_tid;
    stop = 1;
    pthread_join(th, 0);
    if (n == 0) return 0;
    if (n > 1) return 3;
    return g == main_tid ? 1 : g == h ? 2 : 4;
}

int main(void) {
    print("hello321: F_SETOWN_EX / F_GETOWN_EX\n");
    handle_io();
    setpgid(0, 0);
    long me = getpid(), pg = my_pgrp();
    pipe(p);
    int fd = p[0];

    struct fo a = getex(fd);
    long a0 = fc(fd, C_GETOWN_EX, (long)&a);
    snprintf(msg, sizeof msg, "A: a fresh open is TID 0 (%ld: type %d pid %d)", a0, a.type, a.pid);
    check(a0 == 0 && a.type == 0 && a.pid == 0, msg);

    fc(fd, C_SETOWN, me);
    struct fo b0 = getex(fd);
    fc(fd, C_SETOWN, -pg);
    struct fo b1 = getex(fd);
    snprintf(msg, sizeof msg, "B: F_SETOWN pid is PID, -pgrp is PGRP with the group id (%d %d; %d %d)", b0.type, b0.pid, b1.type, b1.pid);
    check(b0.type == 1 && b0.pid == me && b1.type == 2 && b1.pid == pg, msg);

    long c0 = setex(fd, 0, me), c1 = fc(fd, C_GETOWN, 0);
    struct fo c2 = getex(fd);
    long c3 = setex(fd, 1, me), c4 = fc(fd, C_GETOWN, 0);
    struct fo c5 = getex(fd);
    long c6 = setex(fd, 2, pg), c7 = fc(fd, C_GETOWN, 0);
    struct fo c8 = getex(fd);
    snprintf(msg, sizeof msg, "C: TID/PID/PGRP set and read back (%ld %ld %d/%d; %ld %ld %d/%d; %ld %ld %d/%d)", c0, c1, c2.type, c2.pid, c3, c4, c5.type,
             c5.pid, c6, c7, c8.type, c8.pid);
    check(c0 == 0 && c1 == me && c2.type == 0 && c2.pid == me && c3 == 0 && c4 == me && c5.type == 1 && c5.pid == me && c6 == 0 && c7 == -pg &&
              c8.type == 2 && c8.pid == pg,
          msg);

    long d0 = setex(fd, 3, me), d1 = setex(fd, -1, me);
    struct fo d2 = getex(fd);
    snprintf(msg, sizeof msg, "D: a bad type is EINVAL and keeps the owner (%ld %ld; %d %d)", d0, d1, d2.type, d2.pid);
    check(d0 == -22 && d1 == -22 && d2.type == 2 && d2.pid == pg, msg);

    long e0 = setex(fd, 0, 999999), e1 = setex(fd, 1, 999999), e2 = setex(fd, 2, 999999);
    long e3 = setex(fd, 0, -me), e4 = setex(fd, 1, -me), e5 = setex(fd, 2, -pg);
    struct fo e6 = getex(fd);
    snprintf(msg, sizeof msg, "E: unknown or negative ids are ESRCH and keep the owner (%ld %ld %ld; %ld %ld %ld; %d %d)", e0, e1, e2, e3, e4, e5, e6.type,
             e6.pid);
    check(e0 == -3 && e1 == -3 && e2 == -3 && e3 == -3 && e4 == -3 && e5 == -3 && e6.type == 2 && e6.pid == pg, msg);

    long f0 = setex(fd, 0, 0);
    struct fo f1 = getex(fd);
    long f2 = setex(fd, 2, 0);
    struct fo f3 = getex(fd);
    long f4 = fc(fd, C_GETOWN, 0);
    setex(fd, 0, me);
    fc(fd, C_SETOWN, 0);
    struct fo f5 = getex(fd);
    snprintf(msg, sizeof msg, "F: id 0 keeps the type; F_SETOWN 0 makes it PID (%ld %d/%d; %ld %d/%d getown %ld; %d/%d)", f0, f1.type, f1.pid, f2, f3.type,
             f3.pid, f4, f5.type, f5.pid);
    check(f0 == 0 && f1.type == 0 && f1.pid == 0 && f2 == 0 && f3.type == 2 && f3.pid == 0 && f4 == 0 && f5.type == 1 && f5.pid == 0, msg);

    struct fo gs = { 0, (int)me }, go;
    long g0 = fc(fd, C_SETOWN_EX, 1), g1 = fc(fd, C_GETOWN_EX, 1), g2 = fc(99, C_SETOWN_EX, (long)&gs), g3 = fc(99, C_GETOWN_EX, (long)&go);
    snprintf(msg, sizeof msg, "G: a bad pointer is EFAULT, a bad fd EBADF (%ld %ld %ld %ld)", g0, g1, g2, g3);
    check(g0 == -14 && g1 == -14 && g2 == -9 && g3 == -9, msg);

    setex(fd, 0, me);
    int dd = dup(fd);
    struct fo h0 = getex(dd);
    close(dd);
    long hc = fork();
    if (hc == 0) {
        struct fo o = getex(fd);
        _exit(o.type == 0 && o.pid == me ? 0 : 1);
    }
    int hst = -1;
    while (waitpid(hc, &hst, 0) != hc) {}
    snprintf(msg, sizeof msg, "H: the owner and its type belong to the description (dup %d/%d, child %d)", h0.type, h0.pid, hst);
    check(h0.type == 0 && h0.pid == me && hst == 0, msg);

    const char *F = "/tmp/h321a";
    long fcr = op(F, 2 | O_CREAT | O_TRUNC);
    if (fcr >= 0) close((int)fcr);
    int lf = (int)op(F, 0);
    long i0 = fc(lf, C_SETLEASE, 0);
    struct fo i1 = getex(lf);
    fc(lf, C_SETLEASE, 2);
    setex(lf, 0, me);
    long i2 = fc(lf, C_SETLEASE, 0);
    struct fo i3 = getex(lf);
    fc(lf, C_SETLEASE, 2);
    close(lf);
    unlink(F);
    snprintf(msg, sizeof msg, "I: F_SETLEASE sets a PID owner, keeps a TID one (%ld %d/%d; %ld %d/%d)", i0, i1.type, i1.pid, i2, i3.type, i3.pid);
    check(i0 == 0 && i1.type == 1 && i1.pid == me && i2 == 0 && i3.type == 0 && i3.pid == me, msg);

    fc(fd, C_SETFL, A_SYNC);
    long j0r, j1r, j2r;
    long j0 = route(0, -1, 0, 0, &j0r);
    long j1 = route(0, -1, 0, 1, &j1r);
    long j2 = route(0, me, 1, 0, &j2r);
    snprintf(msg, sizeof msg, "J: a TID owner is signalled itself, never another thread (helper %ld; helper blocks %ld; main blocks %ld) (%ld %ld %ld)", j0, j1,
             j2, j0r, j1r, j2r);
    check(j0r == 0 && j1r == 0 && j2r == 0 && j0 == 2 && j1 == 0 && j2 == 1, msg);

    long k0r, k1r;
    long k0 = route(1, me, 1, 0, &k0r);
    long k1 = route(1, me, 0, 0, &k1r);
    snprintf(msg, sizeof msg, "K: a PID owner gets a process-directed signal (main blocks: %ld; none blocks: %ld) (%ld %ld)", k0, k1, k0r, k1r);
    check(k0r == 0 && k1r == 0 && k0 == 2 && k1 == 1, msg);
    close(p[0]);
    close(p[1]);

    print(failures == 0 ? "hello321: PASS\n" : "hello321: FAIL\n");
    return failures;
}
