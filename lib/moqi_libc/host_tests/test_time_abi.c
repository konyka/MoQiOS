#include <assert.h>
#include <stddef.h>
#include <stdint.h>

#include "../include/moqi_syscalls.h"
#include "../include/errno.h"
#include "../include/time.h"

/* Recording stub for the syscall instruction: every call is logged and answered with one scripted reply. */
long stub_nr;
long stub_args[6];
int stub_calls;
long stub_reply;
int64_t stub_ts_sec, stub_ts_nsec; /* what a successful clock_gettime/clock_getres writes */
int64_t stub_tv_sec, stub_tv_usec; /* what a successful gettimeofday writes */
int64_t stub_rem_sec, stub_rem_nsec; /* what an interrupted sleep writes to rem */

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    stub_nr = nr;
    stub_args[0] = a1; stub_args[1] = a2; stub_args[2] = a3;
    stub_args[3] = a4; stub_args[4] = a5; stub_args[5] = a6;
    stub_calls++;
    long r = stub_reply;
    if (r == 0) {
        if (nr == SYS_clock_gettime || nr == SYS_clock_getres) {
            int64_t *ts = (int64_t *)a2;
            if (ts) { ts[0] = stub_ts_sec; ts[1] = stub_ts_nsec; }
        } else if (nr == SYS_gettimeofday) {
            int64_t *tv = (int64_t *)a1;
            if (tv) { tv[0] = stub_tv_sec; tv[1] = stub_tv_usec; }
        }
    }
    if (r == -4) {
        int64_t *rem = (int64_t *)((nr == SYS_nanosleep) ? a2 : a4);
        if (rem) { rem[0] = stub_rem_sec; rem[1] = stub_rem_nsec; }
    }
    return r;
}

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static void arm(long reply) {
    stub_calls = 0; stub_nr = -1; stub_reply = reply;
    for (int i = 0; i < 6; i++) stub_args[i] = -12345;
}
int main(void) {
    /* Constants and layouts are Linux x86_64's. */
    assert(CLOCK_REALTIME == 0 && CLOCK_MONOTONIC == 1 && CLOCK_PROCESS_CPUTIME_ID == 2 && CLOCK_THREAD_CPUTIME_ID == 3);
    assert(CLOCK_MONOTONIC_RAW == 4 && CLOCK_REALTIME_COARSE == 5 && CLOCK_MONOTONIC_COARSE == 6 && CLOCK_BOOTTIME == 7);
    assert(TIMER_ABSTIME == 1);
    assert(sizeof(struct timespec) == 16 && offsetof(struct timespec, tv_sec) == 0 && offsetof(struct timespec, tv_nsec) == 8);
    assert(sizeof(struct timeval) == 16 && offsetof(struct timeval, tv_sec) == 0 && offsetof(struct timeval, tv_usec) == 8);
    assert(SYS_clock_gettime == 228 && SYS_gettimeofday == 96 && SYS_nanosleep == 35);
    assert(SYS_clock_nanosleep == 247 && SYS_clock_getres == 269);

    /* clock_gettime: the clock id and the pointer pass through; 0 on success, the value is the kernel's. */
    errno_slot = 77;
    arm(0);
    stub_ts_sec = 1700000000; stub_ts_nsec = 123456789;
    struct timespec ts = { -1, -1 };
    assert(clock_gettime(CLOCK_REALTIME, &ts) == 0 && errno_slot == 77);
    assert(stub_nr == SYS_clock_gettime && stub_args[0] == 0 && stub_args[1] == (long)(uintptr_t)&ts);
    assert(ts.tv_sec == 1700000000 && ts.tv_nsec == 123456789);
    assert(clock_gettime(CLOCK_BOOTTIME, &ts) == 0 && stub_args[0] == 7);

    /* Failures: -1 and errno from the kernel (EINVAL for a bad clock, EFAULT for a bad pointer). */
    arm(-22);
    assert(clock_gettime(99, &ts) == -1 && errno == EINVAL);
    arm(-14);
    assert(clock_gettime(CLOCK_MONOTONIC, (struct timespec *)0) == -1 && errno == EFAULT);

    /* clock_getres, including the NULL result pointer glibc allows. */
    arm(0);
    stub_ts_sec = 0; stub_ts_nsec = 1;
    assert(clock_getres(CLOCK_MONOTONIC, &ts) == 0 && stub_nr == SYS_clock_getres && ts.tv_nsec == 1);
    arm(-22);
    assert(clock_getres(99, &ts) == -1 && errno == EINVAL);

    /* gettimeofday: the timezone argument is forwarded as given; tv is optional. */
    arm(0);
    stub_tv_sec = 1700000001; stub_tv_usec = 999999;
    struct timeval tv = { -1, -1 };
    assert(gettimeofday(&tv, (void *)0) == 0 && stub_nr == SYS_gettimeofday);
    assert(stub_args[0] == (long)(uintptr_t)&tv && stub_args[1] == 0);
    assert(tv.tv_sec == 1700000001 && tv.tv_usec == 999999);
    arm(-14);
    assert(gettimeofday(&tv, (void *)8) == -1 && errno == EFAULT && stub_args[1] == 8);

    /* time(): seconds from the realtime clock; stores through the pointer when given; no syscall error path. */
    arm(0);
    stub_ts_sec = 1700000002; stub_ts_nsec = 5;
    time_t t = 0;
    assert(time((time_t *)0) == 1700000002 && stub_nr == SYS_clock_gettime && stub_args[0] == CLOCK_REALTIME);
    assert(time(&t) == 1700000002 && t == 1700000002);
    /* The nanoseconds are truncated, never rounded up. */
    stub_ts_sec = 41; stub_ts_nsec = 999999999;
    assert(time((time_t *)0) == 41);
    /* If the clock cannot be read, time() is -1 with errno set (as glibc), and *t is not written. */
    arm(-22);
    t = 123;
    assert(time(&t) == (time_t)-1 && errno == EINVAL && t == 123);

    /* nanosleep: 0 or -1/errno; rem is forwarded; an interrupted sleep reports EINTR and writes the remainder. */
    arm(0);
    struct timespec req = { 1, 500 }, rem = { -1, -1 };
    assert(nanosleep(&req, &rem) == 0 && stub_nr == SYS_nanosleep);
    assert(stub_args[0] == (long)(uintptr_t)&req && stub_args[1] == (long)(uintptr_t)&rem);
    arm(-22);
    assert(nanosleep(&req, (struct timespec *)0) == -1 && errno == EINVAL && stub_args[1] == 0);
    arm(-4);
    stub_rem_sec = 0; stub_rem_nsec = 250;
    assert(nanosleep(&req, &rem) == -1 && errno == EINTR && rem.tv_sec == 0 && rem.tv_nsec == 250);

    /* clock_nanosleep: POSIX style, the error is the RETURN value and errno is not touched. */
    errno_slot = 55;
    arm(0);
    assert(clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &req, &rem) == 0);
    assert(stub_nr == SYS_clock_nanosleep && stub_args[0] == 1 && stub_args[1] == 1);
    assert(stub_args[2] == (long)(uintptr_t)&req && stub_args[3] == (long)(uintptr_t)&rem);
    arm(-22);
    assert(clock_nanosleep(99, 0, &req, &rem) == EINVAL && errno_slot == 55);
    arm(-4);
    stub_rem_sec = 3; stub_rem_nsec = 4;
    assert(clock_nanosleep(CLOCK_REALTIME, 0, &req, &rem) == EINTR && errno_slot == 55 && rem.tv_sec == 3 && rem.tv_nsec == 4);

    /* The error window is the last 4095 values, as in glibc: -4095 is an error, -4096 is a result. A clock id the kernel
     * answers with -4096 does not exist, but the wrapper must not guess: it only treats [-4095, -1] as errors. */
    arm(-4095);
    assert(clock_gettime(CLOCK_REALTIME, &ts) == -1 && errno == 4095);
    errno_slot = 5;
    arm(-4096);
    assert(clock_gettime(CLOCK_REALTIME, &ts) == 0 && errno_slot == 5);
    arm(-4095);
    assert(clock_nanosleep(CLOCK_REALTIME, 0, &req, &rem) == 4095);
    arm(-4096);
    assert(clock_nanosleep(CLOCK_REALTIME, 0, &req, &rem) == 0);

    /* sleep(): 0 when it slept the whole time, the unslept seconds (rounded up) when interrupted; sleep(0) is 0. */
    arm(0);
    assert(sleep(2) == 0 && stub_nr == SYS_nanosleep);
    {
        int64_t *r = (int64_t *)stub_args[0];
        assert(r[0] == 2 && r[1] == 0);
    }
    arm(-4);
    stub_rem_sec = 1; stub_rem_nsec = 1; /* 1.000000001 s left: rounds up to 2 */
    assert(sleep(5) == 2);
    stub_rem_sec = 3; stub_rem_nsec = 0;
    assert(sleep(5) == 3);
    stub_rem_sec = 0; stub_rem_nsec = 1;
    assert(sleep(5) == 1);
    /* sleep(0) is 0 and never reaches the kernel. */
    arm(0);
    assert(sleep(0) == 0 && stub_calls == 0);
    /* A sleep that fails for a reason other than a signal slept nothing: all the requested seconds are unslept, and the
     * rem the kernel did not write is not trusted (it would read as 0 seconds left). */
    arm(-22);
    stub_rem_sec = 0; stub_rem_nsec = 0;
    assert(sleep(7) == 7);
    arm(-14);
    assert(sleep(3) == 3);

    /* usleep(): microseconds split into seconds and nanoseconds; 0 or -1/errno; usec >= 1e6 is allowed here (glibc). */
    arm(0);
    assert(usleep(1500000) == 0 && stub_nr == SYS_nanosleep);
    {
        int64_t *r = (int64_t *)stub_args[0];
        assert(r[0] == 1 && r[1] == 500000000);
    }
    assert(usleep(1) == 0);
    {
        int64_t *r = (int64_t *)stub_args[0];
        assert(r[0] == 0 && r[1] == 1000);
    }
    arm(-4);
    stub_rem_sec = 0; stub_rem_nsec = 10;
    assert(usleep(100) == -1 && errno == EINTR);
    return 0;
}
