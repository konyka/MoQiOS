/* hello309: exec drops what the old image armed: its POSIX timers are deleted, so no timer signal reaches the new image, and its
 * mq_notify registration is removed, so the new image can register again (not EBUSY). Measured on the host (build with -DHOST): a
 * 100 ms timer armed before exec sends nothing in the new image's 300 ms wait; mq_notify from the new image succeeds. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long tcreate(long clk, void *sev, int *id) { long r = syscall(SYS_timer_create, clk, sev, id); return r < 0 ? -errno : r; }
static long tset(int id, long flags, void *nv) { long r = syscall(SYS_timer_settime, id, flags, nv, 0); return r < 0 ? -errno : r; }
static long stw(void *set, void *info, void *ts) { long r = syscall(SYS_rt_sigtimedwait, set, info, ts, 8); return r < 0 ? -errno : r; }
static long mask(long how, unsigned long *set) { long r = syscall(SYS_rt_sigprocmask, how, set, 0, 8); return r < 0 ? -errno : r; }
static long mqopen(const char *n, int creat) {
    struct mq_attr a = { 0, 4, 16, 0 };
    mqd_t q = creat ? mq_open(n, O_CREAT | O_RDWR, 0600, &a) : mq_open(n, O_RDWR);
    return q < 0 ? -errno : q;
}
static long mqnotify(long q, int sig) {
    struct sigevent sev;
    memset(&sev, 0, sizeof sev);
    sev.sigev_notify = SIGEV_SIGNAL;
    sev.sigev_signo = sig;
    return mq_notify((mqd_t)q, &sev) < 0 ? -errno : 0;
}
static void mqgone(const char *n) { mq_unlink(n); }
static long doexec(const char *self, const char *arg) { execl(self, self, arg, (char *)0); return -errno; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
static long tcreate(long clk, void *sev, int *id) { return syscall3(192, clk, (long)sev, (long)id); }
static long tset(int id, long flags, void *nv) { return syscall4(193, id, flags, (long)nv, 0); }
static long stw(void *set, void *info, void *ts) { return syscall4(221, (long)set, (long)info, (long)ts, 8); }
static long mask(long how, unsigned long *set) { return syscall4(SYS_sigprocmask, how, (long)set, 0, 8); }
static long mqopen(const char *n, int creat) {
    long a[4] = { 0, 4, 16, 0 };
    return creat ? syscall4(186, (long)n, 02 | 0x40, 0600, (long)a) : syscall4(186, (long)n, 02, 0, 0);
}
static long mqnotify(long q, int sig) {
    long sev[8] = { 0, sig, 0, 0, 0, 0, 0, 0 };
    return syscall2(190 /* mq_notify */, q, (long)sev);
}
static void mqgone(const char *n) { syscall1(187, (long)n); }
static long doexec(const char *self, const char *arg) {
    const char *argv[3] = { self, arg, 0 };
    const char *envp[1] = { 0 };
    return syscall3(SYS_execve, (long)self, (long)argv, (long)envp);
}
#endif

#define S_USR1 10
#define S_USR2 12
#define BLOCK 0
#define QNAME "/h309q"

static int failures;
static char what[200];
static void check(int ok, const char *w) {
    print(ok ? "hello309:   ok   " : "hello309:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

int main(int argc, char **argv) {
    unsigned long both = (1UL << (S_USR1 - 1)) | (1UL << (S_USR2 - 1));
    if (argc > 1 && strcmp(argv[1], "after") == 0) {
        /* The new image: nothing the old one armed may reach it. */
        mask(BLOCK, &both);
        long info[16];
        long to[2] = { 0, 300000000L };
        long r = stw(&both, info, to);
        snprintf(what, sizeof what, "A: a timer armed before exec sends no signal into the new image (%ld)", r);
        check(r == -11, what);
        long q = mqopen(QNAME, 0);
        long nr = q >= 0 ? mqnotify(q, S_USR2) : q;
        snprintf(what, sizeof what, "B: the old image's mq_notify registration is gone: the new image can register (%ld)", nr);
        check(nr == 0, what);
        mqgone(QNAME);
        print(failures == 0 ? "hello309: PASS\n" : "hello309: FAIL\n");
        return failures;
    }
    print("hello309: exec drops the old image's timers and mq_notify registration\n");
    mask(BLOCK, &both);
    long sev[8] = { 0, S_USR1, 0, 0, 0, 0, 0, 0 };
    int id = -1;
    long c = tcreate(1 /* CLOCK_MONOTONIC */, sev, &id);
    long its[4] = { 0, 0, 0, 100000000L };
    long s = c == 0 ? tset(id, 0, its) : c;
    mqgone(QNAME);
    long q = mqopen(QNAME, 1);
    long nr = q >= 0 ? mqnotify(q, S_USR2) : q;
    if (c != 0 || s != 0 || nr != 0) {
        snprintf(what, sizeof what, "setup: timer %ld/%ld, mq %ld, notify %ld", c, s, q, nr);
        check(0, what);
        print("hello309: FAIL\n");
        return 1;
    }
    long e = doexec(argv[0], "after");
    snprintf(what, sizeof what, "exec failed (%ld)", e);
    check(0, what);
    print("hello309: FAIL\n");
    return 1;
}
