/* hello327: F_GETOWN / F_GETOWN_EX once the owner is gone (Linux fs/fcntl.c f_getown, f_getown_ex: pid_task() or 0).
 * Measured on the host (build with -DHOST):
 *   A. a PID owner that was killed but not yet reaped still reads back (a zombie keeps its pid);
 *   B. once reaped, F_GETOWN is 0 and F_GETOWN_EX is type PID, pid 0;
 *   C. a TID owner whose thread was joined reads back type TID, pid 0, and F_GETOWN 0;
 *   D. F_SETOWN_EX to that exited tid is ESRCH;
 *   E. a PGRP owner whose only member is a zombie still reads back -pgrp; once reaped it reads 0 (type PGRP, pid 0);
 *   F. a PGRP owner whose leader is reaped while another member lives still reads -pgrp; with every member gone, 0. */
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
static long my_tid(void) { return syscall(SYS_gettid); }
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
static long my_tid(void) { return syscall0(SYS_gettid); }
#endif

struct fo { int type; int pid; };
#define C_SETOWN 8
#define C_GETOWN 9
#define C_SETOWN_EX 15
#define C_GETOWN_EX 16

static int failures;
static char msg[260];
static void check(int ok, const char *w) {
    print(ok ? "hello327:   ok   " : "hello327:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long setex(int fd, int type, long pid) { struct fo s = { type, (int)pid }; return fc(fd, C_SETOWN_EX, (long)&s); }
static struct fo getex(int fd) { struct fo o = { -9, -9 }; fc(fd, C_GETOWN_EX, (long)&o); return o; }

static volatile long tidv, go;
static void *thr(void *a) {
    (void)a;
    tidv = my_tid();
    while (!go) usleep(1000);
    return 0;
}

/* Wait (up to ~2 s) until F_GETOWN on fd reads `want`. */
static long settle(int fd, long want) {
    long v = fc(fd, C_GETOWN, 0);
    for (int i = 0; i < 200 && v != want; i++) {
        usleep(10000);
        v = fc(fd, C_GETOWN, 0);
    }
    return v;
}

int main(void) {
    print("hello327: F_GETOWN / F_GETOWN_EX after the owner is gone\n");
    int p[2];
    pipe(p);
    int fd = p[0];

    long c = fork();
    if (c == 0) {
        for (;;) usleep(100000);
    }
    long a0 = fc(fd, C_SETOWN, c);
    kill((int)c, 9);
    usleep(100000);
    long a1 = fc(fd, C_GETOWN, 0);
    struct fo a2 = getex(fd);
    snprintf(msg, sizeof msg, "A: a killed, unreaped PID owner still reads back (%ld %ld; %d/%d; want %ld)", a0, a1, a2.type, a2.pid, c);
    check(a0 == 0 && a1 == c && a2.type == 1 && a2.pid == c, msg);

    int st = 0;
    while (waitpid((int)c, &st, 0) != c) {}
    long b0 = settle(fd, 0);
    struct fo b1 = getex(fd);
    snprintf(msg, sizeof msg, "B: once reaped, F_GETOWN 0 and F_GETOWN_EX PID/0 (%ld; %d/%d)", b0, b1.type, b1.pid);
    check(b0 == 0 && b1.type == 1 && b1.pid == 0, msg);

    pthread_t th;
    tidv = 0;
    go = 0;
    pthread_create(&th, 0, thr, 0);
    while (!tidv) usleep(1000);
    long t = tidv;
    long c0 = setex(fd, 0, t);
    struct fo c1 = getex(fd);
    go = 1;
    pthread_join(th, 0);
    long c2 = settle(fd, 0);
    struct fo c3 = getex(fd);
    snprintf(msg, sizeof msg, "C: a joined TID owner reads TID/0 and F_GETOWN 0 (set %ld live %d/%d; %ld %d/%d; tid %ld)", c0, c1.type, c1.pid, c2, c3.type,
             c3.pid, t);
    check(c0 == 0 && c1.type == 0 && c1.pid == t && c2 == 0 && c3.type == 0 && c3.pid == 0, msg);

    long d0 = setex(fd, 0, t);
    snprintf(msg, sizeof msg, "D: F_SETOWN_EX to the exited tid is ESRCH (%ld)", d0);
    check(d0 == -3, msg);

    long g = fork();
    if (g == 0) {
        setpgid(0, 0);
        for (;;) usleep(100000);
    }
    setpgid((int)g, (int)g);
    usleep(20000);
    long e0 = fc(fd, C_SETOWN, -g);
    kill((int)g, 9);
    usleep(100000);
    long e1 = fc(fd, C_GETOWN, 0);
    while (waitpid((int)g, &st, 0) != g) {}
    long e2 = settle(fd, 0);
    struct fo e3 = getex(fd);
    snprintf(msg, sizeof msg, "E: a PGRP owner reads -pgrp while its member is a zombie, 0 once reaped (%ld %ld %ld %d/%d; group %ld)", e0, e1, e2, e3.type,
             e3.pid, g);
    check(e0 == 0 && e1 == -g && e2 == 0 && e3.type == 2 && e3.pid == 0, msg);

    int q[2];
    pipe(q);
    long l = fork();
    if (l == 0) {
        setpgid(0, 0);
        long m = fork();
        if (m == 0) {
            for (;;) usleep(100000);
        }
        int mi = (int)m;
        write(q[1], &mi, sizeof mi);
        _exit(0);
    }
    setpgid((int)l, (int)l);
    int member = 0;
    read(q[0], &member, sizeof member);
    long f0 = fc(fd, C_SETOWN, -l);
    while (waitpid((int)l, &st, 0) != l) {}
    usleep(20000);
    long f1 = fc(fd, C_GETOWN, 0);
    kill(member, 9);
    long f2 = settle(fd, 0);
    snprintf(msg, sizeof msg, "F: leader reaped, member alive reads -pgrp; every member gone reads 0 (%ld %ld %ld; group %ld member %d)", f0, f1, f2, l,
             member);
    check(f0 == 0 && f1 == -l && f2 == 0, msg);
    close(q[0]);
    close(q[1]);
    close(p[0]);
    close(p[1]);

    print(failures == 0 ? "hello327: PASS\n" : "hello327: FAIL\n");
    return failures;
}
