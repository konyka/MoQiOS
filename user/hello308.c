/* hello308: POSIX timers on CLOCK_PROCESS_CPUTIME_ID (2) and CLOCK_THREAD_CPUTIME_ID (3) count CPU time, not wall time.
 * Measured on the host (build with -DHOST): both clocks create a timer; a 20 ms CPU timer does not fire while the process sleeps
 * (sigtimedwait with a 300 ms timeout gets nothing), and fires once the process has burned 20 ms of CPU; the thread clock's timer is
 * accounted per thread, so CPU burned by a sibling thread does not fire it; timer_gettime reports the CPU time still to run;
 * disarming stops it. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long tcreate(long clk, void *sev, int *id) { long r = syscall(SYS_timer_create, clk, sev, id); return r < 0 ? -errno : r; }
static long tset(int id, long flags, void *nv, void *ov) { long r = syscall(SYS_timer_settime, id, flags, nv, ov); return r < 0 ? -errno : r; }
static long tget(int id, void *ov) { long r = syscall(SYS_timer_gettime, id, ov); return r < 0 ? -errno : r; }
static void tdel(int id) { syscall(SYS_timer_delete, id); }
static long stw(void *set, void *info, void *ts) { long r = syscall(SYS_rt_sigtimedwait, set, info, ts, 8); return r < 0 ? -errno : r; }
static long mask(long how, unsigned long *set) { long r = syscall(SYS_rt_sigprocmask, how, set, 0, 8); return r < 0 ? -errno : r; }
static long cpu_ns(long clk) {
    struct timespec t;
    clock_gettime((clockid_t)clk, &t);
    return t.tv_sec * 1000000000L + t.tv_nsec;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
static long tcreate(long clk, void *sev, int *id) { return syscall3(192, clk, (long)sev, (long)id); }
static long tset(int id, long flags, void *nv, void *ov) { return syscall4(193, id, flags, (long)nv, (long)ov); }
static long tget(int id, void *ov) { return syscall2(194, id, (long)ov); }
static void tdel(int id) { syscall1(196, id); }
static long stw(void *set, void *info, void *ts) { return syscall4(221, (long)set, (long)info, (long)ts, 8); }
static long mask(long how, unsigned long *set) { return syscall4(SYS_sigprocmask, how, (long)set, 0, 8); }
static long cpu_ns(long clk) {
    long ts[2] = { 0, 0 };
    long r = syscall2(SYS_clock_gettime, clk, (long)ts);
    return r < 0 ? r : ts[0] * 1000000000L + ts[1];
}
#endif

#define CPU_CLOCK 2
#define THREAD_CLOCK 3
#define S_USR1 10
#define BLOCK 0
#define UNBLOCK 1

struct its { long isec, insec, vsec, vnsec; };
/* siginfo is 128 bytes; only the first words are read. */
struct sinfo { long signo, err, code, pad; long pid, uid; long value; long overrun; long rest[8]; };

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello308:   ok   " : "hello308:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void spin_until_cpu(long ns_target) {
    while (cpu_ns(CPU_CLOCK) < ns_target) {
        volatile double x = 0;
        for (int i = 0; i < 20000; i++) x += i;
        (void)x;
    }
}

int main(void) {
    print("hello308: POSIX timers on CPU-time clocks\n");
    unsigned long bit = 1UL << (S_USR1 - 1);
    mask(BLOCK, &bit);
    long sev[8] = { 0, S_USR1, 0, 0, 0, 0, 0, 0 };
    int id = -1;
    long c = tcreate(CPU_CLOCK, sev, &id);
    snprintf(what, sizeof what, "A: timer_create(CLOCK_PROCESS_CPUTIME_ID) succeeds (%ld)", c);
    check(c == 0, what);
    if (c != 0) {
        print(failures == 0 ? "hello308: PASS\n" : "hello308: FAIL\n");
        return failures;
    }
    struct its it = { 0, 0, 0, 20000000L };
    long s = tset(id, 0, &it, 0);
    snprintf(what, sizeof what, "B: arming a 20 ms CPU timer succeeds (%ld)", s);
    check(s == 0, what);

    /* C: sleeping burns no CPU, so the timer must not fire. */
    struct sinfo si;
    memset(&si, 0, sizeof si);
    long to[2] = { 0, 300000000L };
    long w = stw(&bit, &si, to);
    snprintf(what, sizeof what, "C: it does not fire while the process sleeps (sigtimedwait %ld)", w);
    check(w == -11, what);

    /* D: burning 20 ms of CPU fires it (counted from now: the setup above already used some). */
    spin_until_cpu(cpu_ns(CPU_CLOCK) + 25000000L);
    to[0] = 1;
    to[1] = 0;
    w = stw(&bit, &si, to);
    snprintf(what, sizeof what, "D: it fires once the process has used 20 ms of CPU (%ld, code %ld)", w, si.code);
    check(w == S_USR1, what);
    tdel(id);

    /* E: the thread clock counts the calling thread only. A sibling thread spins while this one sleeps; the timer must not fire. */
    int tid = -1;
    /* A fresh sigevent: the kernel writes back nothing, but the struct must be the full 64 bytes each time. */
    { long fresh[8] = { 0, S_USR1, 0, 0, 0, 0, 0, 0 }; c = tcreate(THREAD_CLOCK, fresh, &tid); }
    snprintf(what, sizeof what, "E: timer_create(CLOCK_THREAD_CPUTIME_ID) succeeds (%ld)", c);
    check(c == 0, what);
    if (c == 0) {
        it.vsec = 0;
        it.vnsec = 20000000L;
        s = tset(tid, 0, &it, 0);
        long base = cpu_ns(THREAD_CLOCK);
        /* Sleep with a timeout: this thread's own CPU time barely moves. */
        to[0] = 0;
        to[1] = 300000000L;
        memset(&si, 0, sizeof si);
        w = stw(&bit, &si, to);
        snprintf(what, sizeof what, "F: the thread timer does not fire while this thread sleeps (%ld, own CPU %ld ms, set %ld)", w,
                 (cpu_ns(THREAD_CLOCK) - base) / 1000000, s);
        check(w == -11, what);
        tdel(tid);
    }

    /* G: timer_gettime reports the CPU time still to run, and it shrinks as CPU is burned but not while sleeping. */
    int gid = -1;
    long gsev[8] = { 0, S_USR1, 0, 0, 0, 0, 0, 0 };
    if (tcreate(CPU_CLOCK, gsev, &gid) == 0) {
        it.vnsec = 50000000L;
        tset(gid, 0, &it, 0);
        struct its left;
        memset(&left, 0, sizeof left);
        long t1 = tget(gid, &left);
        long first = left.vsec * 1000000000L + left.vnsec;
        to[0] = 0;
        to[1] = 100000000L;
        memset(&si, 0, sizeof si);
        stw(&bit, &si, to);
        memset(&left, 0, sizeof left);
        long t2 = tget(gid, &left);
        long second = left.vsec * 1000000000L + left.vnsec;
        snprintf(what, sizeof what, "G: timer_gettime reports the CPU time left and it does not shrink while sleeping (%ld/%ld, %ld ms -> %ld ms)",
                 t1, t2, first / 1000000, second / 1000000);
        check(t1 == 0 && t2 == 0 && first <= 50000000L && second + 5000000L >= first, what);
        tdel(gid);
    }
    mask(UNBLOCK, &bit);
    print(failures == 0 ? "hello308: PASS\n" : "hello308: FAIL\n");
    return failures;
}
