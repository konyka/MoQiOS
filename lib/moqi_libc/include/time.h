/* time.h — clocks, sleeping and the wall clock for moqi_libc, over the MoQiOS system calls.
 *
 * glibc conventions: success is 0 (time(): the seconds), failure is -1 with the kernel's errno in errno — except
 * clock_nanosleep, which like POSIX returns the error number itself and leaves errno alone. Constants and layouts are
 * Linux x86_64's.
 */
#ifndef MOQI_TIME_H
#define MOQI_TIME_H

#include "errno.h"

typedef long time_t;

struct timespec {
    long tv_sec;
    long tv_nsec;
};

struct timeval {
    long tv_sec;
    long tv_usec;
};

#define CLOCK_REALTIME           0
#define CLOCK_MONOTONIC          1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define CLOCK_THREAD_CPUTIME_ID  3
#define CLOCK_MONOTONIC_RAW      4
#define CLOCK_REALTIME_COARSE    5
#define CLOCK_MONOTONIC_COARSE   6
#define CLOCK_BOOTTIME           7

#define TIMER_ABSTIME 1

int clock_gettime(int clock_id, struct timespec *tp);
int clock_getres(int clock_id, struct timespec *res);
int gettimeofday(struct timeval *tv, void *tz);

/* Seconds since the epoch from CLOCK_REALTIME (nanoseconds truncated). If the clock cannot be read: (time_t)-1 with
 * errno set, and *t is not written. */
time_t time(time_t *t);

int nanosleep(const struct timespec *req, struct timespec *rem);

/* Returns the error number (0 on success), never touching errno. An interrupted sleep returns EINTR and, for a
 * relative sleep, writes the remaining time to *rem. */
int clock_nanosleep(int clock_id, int flags, const struct timespec *req, struct timespec *rem);

/* Seconds not slept (rounded up) when interrupted, else 0. */
unsigned int sleep(unsigned int seconds);

/* 0, or -1 with errno (EINTR when interrupted). Any microsecond count is accepted. */
int usleep(unsigned long usec);

#endif /* MOQI_TIME_H */
