/* hello201: the moqi_libc time API (clock_gettime, clock_getres, gettimeofday, time, nanosleep, clock_nanosleep, sleep,
 * usleep) through the real kernel. glibc convention: 0 / -1 with errno, except clock_nanosleep which returns the error
 * number. Expected errors were measured with glibc on Linux. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello201:   ok   " : "hello201:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static long long ns_of(const struct timespec *t) { return (long long)t->tv_sec * 1000000000LL + t->tv_nsec; }
static long long now_ns(int clock) {
    struct timespec t = { 0, 0 };
    if (clock_gettime(clock, &t) != 0) return -1;
    return ns_of(&t);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello201: libc time API\n");

    /* Clocks. */
    struct timespec a = { 0, 0 }, b = { 0, 0 };
    errno = 0;
    check(clock_gettime(CLOCK_MONOTONIC, &a) == 0 && errno == 0 && (a.tv_sec > 0 || a.tv_nsec > 0), "A: CLOCK_MONOTONIC reads");
    check(clock_gettime(CLOCK_MONOTONIC, &b) == 0 && ns_of(&b) >= ns_of(&a), "A: and does not go backwards");
    check(clock_gettime(CLOCK_REALTIME, &a) == 0 && a.tv_nsec >= 0 && a.tv_nsec < 1000000000L, "A: CLOCK_REALTIME reads with a valid nsec");
    check(clock_gettime(CLOCK_BOOTTIME, &a) == 0 && clock_gettime(CLOCK_MONOTONIC_RAW, &a) == 0 &&
              clock_gettime(CLOCK_REALTIME_COARSE, &a) == 0 && clock_gettime(CLOCK_MONOTONIC_COARSE, &a) == 0 &&
              clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &a) == 0 && clock_gettime(CLOCK_THREAD_CPUTIME_ID, &a) == 0,
          "A: the other clock ids Linux has all read");
    errno = 0;
    check(clock_gettime(99, &a) == -1 && errno == EINVAL, "A: an unknown clock is -1 / EINVAL");
    errno = 0;
    check(clock_gettime(CLOCK_MONOTONIC, (struct timespec *)0) == -1 && errno == EFAULT, "A: a NULL result is -1 / EFAULT");
    errno = 0;
    check(clock_getres(CLOCK_MONOTONIC, &a) == 0 && a.tv_sec == 0 && a.tv_nsec > 0, "A: clock_getres reports a resolution");
    check(clock_getres(CLOCK_MONOTONIC, (struct timespec *)0) == 0, "A: clock_getres accepts a NULL result");
    errno = 0;
    check(clock_getres(99, &a) == -1 && errno == EINVAL, "A: clock_getres of an unknown clock is -1 / EINVAL");

    /* Wall clock. */
    struct timeval tv = { 0, 0 };
    check(gettimeofday(&tv, (void *)0) == 0 && tv.tv_usec >= 0 && tv.tv_usec < 1000000, "B: gettimeofday reads with a valid usec");
    time_t t1 = time((time_t *)0), t2 = 0;
    check(time(&t2) >= t1 && t2 >= t1 && t1 > 0, "B: time() agrees with itself and is positive");
    check(clock_gettime(CLOCK_REALTIME, &a) == 0 && a.tv_sec >= t1 - 1 && a.tv_sec <= t1 + 5, "B: and with CLOCK_REALTIME");
    check(gettimeofday(&tv, (void *)0) == 0 && tv.tv_sec >= t1 - 1 && tv.tv_sec <= t1 + 5, "B: and with gettimeofday");

    /* Sleeping: the clock has to move by at least what was asked. */
    long long t0 = now_ns(CLOCK_MONOTONIC);
    struct timespec req = { 0, 30 * 1000000L };
    errno = 0;
    check(nanosleep(&req, (struct timespec *)0) == 0 && errno == 0, "C: nanosleep(30 ms) returns 0");
    check(now_ns(CLOCK_MONOTONIC) - t0 >= 30LL * 1000000, "C: and at least 30 ms went by");
    t0 = now_ns(CLOCK_MONOTONIC);
    check(usleep(25000) == 0 && now_ns(CLOCK_MONOTONIC) - t0 >= 25LL * 1000000, "C: usleep(25000) sleeps at least 25 ms");
    t0 = now_ns(CLOCK_MONOTONIC);
    check(sleep(0) == 0 && now_ns(CLOCK_MONOTONIC) - t0 < 20LL * 1000000, "C: sleep(0) returns at once");
    t0 = now_ns(CLOCK_MONOTONIC);
    check(sleep(1) == 0 && now_ns(CLOCK_MONOTONIC) - t0 >= 1000LL * 1000000, "C: sleep(1) sleeps a second and returns 0");
    t0 = now_ns(CLOCK_MONOTONIC);
    struct timespec rel = { 0, 20 * 1000000L };
    errno = 77;
    check(clock_nanosleep(CLOCK_MONOTONIC, 0, &rel, (struct timespec *)0) == 0 && errno == 77, "C: clock_nanosleep returns 0 and leaves errno alone");
    check(now_ns(CLOCK_MONOTONIC) - t0 >= 20LL * 1000000, "C: after at least 20 ms");
    struct timespec abs;
    clock_gettime(CLOCK_MONOTONIC, &abs);
    long long target = ns_of(&abs) + 20LL * 1000000;
    abs.tv_sec = (long)(target / 1000000000LL);
    abs.tv_nsec = (long)(target % 1000000000LL);
    check(clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &abs, (struct timespec *)0) == 0 && now_ns(CLOCK_MONOTONIC) >= target,
          "C: TIMER_ABSTIME sleeps until the absolute time");
    check(clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &abs, (struct timespec *)0) == 0, "C: an absolute time already past returns at once");

    /* Errors: nanosleep/usleep are -1 / errno, clock_nanosleep is the error number. */
    struct timespec neg = { -1, 0 }, big = { 0, 1000000000L }, negns = { 0, -1 };
    errno = 0;
    check(nanosleep(&neg, (struct timespec *)0) == -1 && errno == EINVAL, "D: nanosleep of a negative second is -1 / EINVAL");
    errno = 0;
    check(nanosleep(&big, (struct timespec *)0) == -1 && errno == EINVAL, "D: nsec = 1e9 is -1 / EINVAL");
    errno = 0;
    check(nanosleep(&negns, (struct timespec *)0) == -1 && errno == EINVAL, "D: a negative nsec is -1 / EINVAL");
    errno = 55;
    check(clock_nanosleep(CLOCK_MONOTONIC, 0, &big, (struct timespec *)0) == EINVAL && errno == 55,
          "D: clock_nanosleep returns EINVAL as its value and leaves errno alone");
    check(clock_nanosleep(99, 0, &rel, (struct timespec *)0) == EINVAL, "D: an unknown clock is EINVAL");
    check(clock_nanosleep(CLOCK_BOOTTIME, 0, &rel, (struct timespec *)0) == 0, "D: CLOCK_BOOTTIME sleeps like MONOTONIC");
    check(clock_nanosleep(CLOCK_MONOTONIC_RAW, 0, &rel, (struct timespec *)0) == EOPNOTSUPP &&
              clock_nanosleep(CLOCK_REALTIME_COARSE, 0, &rel, (struct timespec *)0) == EOPNOTSUPP &&
              clock_nanosleep(CLOCK_MONOTONIC_COARSE, 0, &rel, (struct timespec *)0) == EOPNOTSUPP &&
              clock_nanosleep(CLOCK_THREAD_CPUTIME_ID, 0, &rel, (struct timespec *)0) == EOPNOTSUPP,
          "D: MONOTONIC_RAW, the COARSE clocks and THREAD_CPUTIME are EOPNOTSUPP (Linux)");

    print(failures == 0 ? "hello201: PASS\n" : "hello201: FAIL\n");
    return failures;
}
