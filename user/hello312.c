/* hello312: TIMER_ABSTIME on the CPU-time clocks (CLOCK_PROCESS_CPUTIME_ID 2, CLOCK_THREAD_CPUTIME_ID 3): it_value is a reading of
 * the CPU clock, not an amount of CPU time from now (Linux posix_cpu_timer_set adds `now` only without TIMER_ABSTIME).
 * Measured on the host (build with -DHOST): a deadline 20 ms of CPU ahead reports at most 20 ms left and fires once that CPU is
 * burned; a deadline already passed fires without burning more CPU; a deadline 10 s ahead reports at most 10 s left and does not
 * fire while the process sleeps; the thread clock behaves the same way. */
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
#define ABSTIME 1
#define NS 1000000000L

struct its { long isec, insec, vsec, vnsec; };
struct sinfo { long signo, err, code, pad; long pid, uid; long value; long overrun; long rest[8]; };

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello312:   ok   " : "hello312:   FAIL ");
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
static int make(long clk) {
    long sev[8] = { 0, S_USR1, 0, 0, 0, 0, 0, 0 };
    int id = -1;
    return tcreate(clk, sev, &id) == 0 ? id : -1;
}
static long arm_at(int id, long abs_ns) {
    struct its it = { 0, 0, abs_ns / NS, abs_ns % NS };
    return tset(id, ABSTIME, &it, 0);
}
static long left_ns(int id) {
    struct its l;
    memset(&l, 0, sizeof l);
    long r = tget(id, &l);
    return r < 0 ? r : l.vsec * NS + l.vnsec;
}
static long wait_ms(unsigned long *bit, long ms) {
    struct sinfo si;
    memset(&si, 0, sizeof si);
    long to[2] = { ms / 1000, (ms % 1000) * 1000000L };
    return stw(bit, &si, to);
}

int main(void) {
    print("hello312: TIMER_ABSTIME on CPU-time clocks\n");
    unsigned long bit = 1UL << (S_USR1 - 1);
    mask(BLOCK, &bit);
    spin_until_cpu(cpu_ns(CPU_CLOCK) + 30000000L);

    int id = make(CPU_CLOCK);
    long now = cpu_ns(CPU_CLOCK);
    long s = arm_at(id, now + 20000000L);
    long left = left_ns(id);
    snprintf(what, sizeof what, "A: an absolute deadline 20 ms of CPU ahead reports at most 20 ms left (set %ld, left %ld us)", s, left / 1000);
    check(id >= 0 && s == 0 && left > 0 && left <= 20000000L, what);
    spin_until_cpu(now + 25000000L);
    long w = wait_ms(&bit, 1000);
    snprintf(what, sizeof what, "B: it fires once the CPU clock passes the deadline (%ld)", w);
    check(w == S_USR1, what);

    now = cpu_ns(CPU_CLOCK);
    s = arm_at(id, now - 1000000L);
    w = wait_ms(&bit, 300);
    snprintf(what, sizeof what, "C: a deadline the CPU clock has already passed fires without more CPU (set %ld, wait %ld)", s, w);
    check(s == 0 && w == S_USR1, what);

    now = cpu_ns(CPU_CLOCK);
    s = arm_at(id, now + 10 * NS);
    left = left_ns(id);
    w = wait_ms(&bit, 300);
    snprintf(what, sizeof what, "D: a deadline 10 s ahead reports at most 10 s left and does not fire while asleep (set %ld, left %ld ms, wait %ld)",
             s, left / 1000000, w);
    check(s == 0 && left > 9 * NS && left <= 10 * NS && w == -11, what);
    tdel(id);

    int tid = make(THREAD_CLOCK);
    long tnow = cpu_ns(THREAD_CLOCK);
    s = arm_at(tid, tnow + 20000000L);
    left = left_ns(tid);
    snprintf(what, sizeof what, "E: the thread clock takes an absolute deadline too (set %ld, left %ld us)", s, left / 1000);
    check(tid >= 0 && s == 0 && left > 0 && left <= 20000000L, what);
    s = arm_at(tid, cpu_ns(THREAD_CLOCK) - 1000000L);
    w = wait_ms(&bit, 300);
    snprintf(what, sizeof what, "F: a passed thread-clock deadline fires (set %ld, wait %ld)", s, w);
    check(s == 0 && w == S_USR1, what);
    tdel(tid);

    mask(UNBLOCK, &bit);
    print(failures == 0 ? "hello312: PASS\n" : "hello312: FAIL\n");
    return failures;
}
