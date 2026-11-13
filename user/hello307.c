/* hello307: CLOCK_TAI (11) is a clock: clock_gettime, clock_getres, clock_nanosleep (relative and TIMER_ABSTIME) and timer_create
 * accept it; clock_settime refuses it (EINVAL) and timerfd_create too (EINVAL), as on Linux. TAI is REALTIME plus the kernel's TAI
 * offset, which is 0 until adjtimex(ADJ_TAI) sets it (this kernel has no adjtimex, so it stays 0). Measured on the host (build with
 * -DHOST): all of the above, with TAI - REALTIME equal to the offset adjtimex reports (37 s on an NTP-synchronised host). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/timex.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long gettime(long clk, long *ts) { long r = syscall(SYS_clock_gettime, clk, ts); return r < 0 ? -errno : r; }
static long getres(long clk, long *ts) { long r = syscall(SYS_clock_getres, clk, ts); return r < 0 ? -errno : r; }
static long settime(long clk, long *ts) { long r = syscall(SYS_clock_settime, clk, ts); return r < 0 ? -errno : r; }
static long csleep(long clk, long flags, long *ts) { long r = syscall(SYS_clock_nanosleep, clk, flags, ts, 0); return r < 0 ? -errno : r; }
static long tcreate(long clk, void *sev, int *id) { long r = syscall(SYS_timer_create, clk, sev, id); return r < 0 ? -errno : r; }
static void tdelete(int id) { syscall(SYS_timer_delete, id); }
static long tfd_create(long clk) { long r = syscall(SYS_timerfd_create, clk, 0); return r < 0 ? -errno : r; }
static long tai_offset_s(void) { struct timex tx; memset(&tx, 0, sizeof tx); adjtimex(&tx); return tx.tai; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long gettime(long clk, long *ts) { return syscall2(SYS_clock_gettime, clk, (long)ts); }
static long getres(long clk, long *ts) { return syscall2(SYS_clock_getres, clk, (long)ts); }
static long settime(long clk, long *ts) { return syscall2(270 /* native clock_settime */, clk, (long)ts); }
static long csleep(long clk, long flags, long *ts) { return syscall4(SYS_clock_nanosleep, clk, flags, (long)ts, 0); }
static long tcreate(long clk, void *sev, int *id) { return syscall3(192, clk, (long)sev, (long)id); }
static void tdelete(int id) { syscall1(196, id); }
static long tfd_create(long clk) { return syscall2(170, clk, 0); }
static long tai_offset_s(void) { return 0; }
#endif

#define TAI 11
#define REALTIME 0
#define MONOTONIC 1
#define ABSTIME 1

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello307:   ok   " : "hello307:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long ns_of(long *ts) { return ts[0] * 1000000000L + ts[1]; }
static long mono_ns(void) { long ts[2] = { 0, 0 }; gettime(MONOTONIC, ts); return ns_of(ts); }

int main(void) {
    print("hello307: CLOCK_TAI\n");
    long rt[2] = { 0, 0 }, tai[2] = { 0, 0 };
    long r1 = gettime(REALTIME, rt);
    long r2 = gettime(TAI, tai);
    long diff = ns_of(tai) - ns_of(rt);
    long want = tai_offset_s() * 1000000000L;
    snprintf(what, sizeof what, "A: clock_gettime(CLOCK_TAI) works and is REALTIME plus the TAI offset (%ld, %ld; offset %ld s, diff %ld ms)", r1, r2,
             want / 1000000000L, diff / 1000000);
    check(r1 == 0 && r2 == 0 && diff - want >= 0 && diff - want < 50000000L, what);

    long res[2] = { 9, 9 };
    long g = getres(TAI, res);
    snprintf(what, sizeof what, "B: clock_getres(CLOCK_TAI) is 1 ns (%ld, %ld.%09ld)", g, res[0], res[1]);
    check(g == 0 && res[0] == 0 && res[1] == 1, what);

    long rel[2] = { 0, 20000000L };
    long t0 = mono_ns();
    long s = csleep(TAI, 0, rel);
    long slept = (mono_ns() - t0) / 1000000;
    snprintf(what, sizeof what, "C: clock_nanosleep(CLOCK_TAI) sleeps 20 ms (%ld, %ld ms)", s, slept);
    check(s == 0 && slept >= 19 && slept < 200, what);

    long abs[2] = { 0, 0 };
    gettime(TAI, abs);
    abs[1] += 20000000L;
    if (abs[1] >= 1000000000L) {
        abs[0]++;
        abs[1] -= 1000000000L;
    }
    t0 = mono_ns();
    s = csleep(TAI, ABSTIME, abs);
    slept = (mono_ns() - t0) / 1000000;
    snprintf(what, sizeof what, "D: clock_nanosleep(CLOCK_TAI, TIMER_ABSTIME) wakes at the TAI deadline 20 ms ahead (%ld, %ld ms)", s, slept);
    check(s == 0 && slept >= 19 && slept < 200, what);

    long now[2] = { 0, 0 };
    gettime(TAI, now);
    long st = settime(TAI, now);
    snprintf(what, sizeof what, "E: clock_settime(CLOCK_TAI) is EINVAL (%ld)", st);
    check(st == -22, what);

    /* sigevent with SIGEV_NONE (1): the kernel reads value, signo, notify. */
    long sev[8] = { 0, (1L << 32) | 0, 0, 0, 0, 0, 0, 0 };
    int id = -1;
    long tc = tcreate(TAI, sev, &id);
    snprintf(what, sizeof what, "F: timer_create(CLOCK_TAI) succeeds (%ld)", tc);
    check(tc == 0, what);
    if (tc == 0) tdelete(id);

    long tf = tfd_create(TAI);
    snprintf(what, sizeof what, "G: timerfd_create(CLOCK_TAI) is EINVAL (%ld)", tf);
    check(tf == -22, what);
    if (tf >= 0) close((int)tf);

    print(failures == 0 ? "hello307: PASS\n" : "hello307: FAIL\n");
    return failures;
}
