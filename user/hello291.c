/* hello291: timerfd expiries are measured in nanoseconds, not scheduler ticks.
 * Measured on the host (build with -DHOST): timerfd_gettime right after arming 1.234567891 s reports no more than that and
 * within a few milliseconds of it; none of 20 one-shot 15 ms timers wakes a blocked read() early; an absolute CLOCK_MONOTONIC
 * deadline 30 ms ahead is not reached early; a 20 ms periodic timer counts 10 expirations over 210 ms; timerfd_settime's
 * old value reports the remaining time to the nanosecond as well. */
#ifdef HOST
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long tfd_create(long clk, long flags) { return syscall(SYS_timerfd_create, clk, flags); }
static long tfd_settime(long fd, long flags, void *nv, void *ov) { return syscall(SYS_timerfd_settime, fd, flags, nv, ov); }
static long tfd_gettime(long fd, void *cv) { return syscall(SYS_timerfd_gettime, fd, cv); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
static long tfd_create(long clk, long flags) { return syscall2(170, clk, flags); }
static long tfd_settime(long fd, long flags, void *nv, void *ov) { return syscall4(171, fd, flags, (long)nv, (long)ov); }
static long tfd_gettime(long fd, void *cv) { return syscall2(172, fd, (long)cv); }
#endif

#define MONO 1
#define ABSTIME 1

struct its { long isec, insec, vsec, vnsec; };

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello291:   ok   " : "hello291:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long now_ns(void) {
    struct timespec t;
    clock_gettime(MONO, &t);
    return t.tv_sec * 1000000000L + t.tv_nsec;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long arm(long fd, long flags, long vns, long ins, struct its *old) {
    struct its v = { ins / 1000000000L, ins % 1000000000L, vns / 1000000000L, vns % 1000000000L };
    return tfd_settime(fd, flags, &v, old);
}
static long value_ns(const struct its *v) { return v->vsec * 1000000000L + v->vnsec; }

int main(void) {
    print("hello291: timerfd expiries in nanoseconds\n");
    long fd = tfd_create(MONO, 0);
    check(fd >= 0, "timerfd_create(CLOCK_MONOTONIC) succeeds");
    if (fd < 0) { print("hello291: FAIL\n"); return 1; }

    /* A: the remaining time is reported to the nanosecond, never more than was set. */
    struct its cur;
    memset(&cur, 0, sizeof cur);
    long set = 1234567891L;
    arm(fd, 0, set, 0, 0);
    tfd_gettime(fd, &cur);
    long left = value_ns(&cur);
    snprintf(msg, sizeof msg, "A: timerfd_gettime after arming 1.234567891 s reports no more than that, within 5 ms (%ld ns)", left);
    check(left <= set && left > set - 5000000L, msg);
    struct its old;
    memset(&old, 0, sizeof old);
    arm(fd, 0, 0, 0, &old);
    left = value_ns(&old);
    snprintf(msg, sizeof msg, "A: the old value timerfd_settime returns is no more than that either (%ld ns)", left);
    check(left <= set && left > set - 50000000L, msg);

    /* B: a blocked read never returns before the timer's time. */
    long early = 0, shortest = 1L << 62;
    for (int i = 0; i < 20; i++) {
        long t0 = now_ns();
        arm(fd, 0, 15000000L, 0, 0);
        unsigned long long n = 0;
        long r = read((int)fd, &n, 8);
        long took = now_ns() - t0;
        if (r != 8 || n != 1 || took < 15000000L) early++;
        if (took < shortest) shortest = took;
    }
    snprintf(msg, sizeof msg, "B: no 15 ms timer wakes read() early (early %ld of 20, shortest %ld us)", early, shortest / 1000);
    check(early == 0, msg);

    /* C: an absolute deadline is not reached early. */
    long t0 = now_ns();
    arm(fd, ABSTIME, t0 + 30000000L, 0, 0);
    unsigned long long n = 0;
    long r = read((int)fd, &n, 8);
    long took = now_ns() - t0;
    snprintf(msg, sizeof msg, "C: an absolute CLOCK_MONOTONIC deadline 30 ms ahead is not reached early (%ld, %llu, %ld us)", r, n, took / 1000);
    check(r == 8 && n == 1 && took >= 30000000L, msg);

    /* D: a periodic timer counts every interval. */
    arm(fd, 0, 20000000L, 20000000L, 0);
    nap(210);
    n = 0;
    r = read((int)fd, &n, 8);
    arm(fd, 0, 0, 0, 0);
    snprintf(msg, sizeof msg, "D: a 20 ms periodic timer counts 10 expirations over 210 ms (%ld, %llu)", r, n);
    check(r == 8 && n >= 9 && n <= 11, msg);

    close((int)fd);
    print(failures ? "hello291: FAIL\n" : "hello291: PASS\n");
    return failures ? 1 : 0;
}
