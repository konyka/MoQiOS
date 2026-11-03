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

/* glibc's layout (56 bytes). The local time zone is always UTC here: no TZ database, no DST. */
struct tm {
    int         tm_sec;
    int         tm_min;
    int         tm_hour;
    int         tm_mday;
    int         tm_mon;
    int         tm_year;
    int         tm_wday;
    int         tm_yday;
    int         tm_isdst;
    long        tm_gmtoff;
    const char *tm_zone;
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

/* ---- calendar conversion (timeconv.c) ------------------------------------------------------------------------- */

#include <stddef.h>

/* Break `t` down into UTC. Returns `out`, or NULL with errno = EOVERFLOW when the year does not fit tm_year. The
 * result has tm_isdst 0, tm_gmtoff 0 and tm_zone "GMT". */
struct tm *gmtime_r(const time_t *t, struct tm *out);
/* The same, into static storage that the next gmtime/localtime call overwrites (not thread-safe, as in glibc). */
struct tm *gmtime(const time_t *t);
/* The local zone is UTC. glibc reports tm_zone "UTC" here (not "GMT") with tm_gmtoff 0. */
struct tm *localtime_r(const time_t *t, struct tm *out);
struct tm *localtime(const time_t *t);

/* The inverse of gmtime_r. Out-of-range fields are normalised (month 12 is January of the next year, second -1 is the
 * previous minute) and written back together with tm_wday and tm_yday; tm_isdst becomes 0. Returns (time_t)-1 with
 * errno = EOVERFLOW when the result does not fit; timegm then clears tm_isdst and changes nothing else, mktime changes
 * nothing at all (both as in glibc). */
time_t timegm(struct tm *tm);
/* In the UTC zone this is timegm; tm_isdst is ignored. */
time_t mktime(struct tm *tm);

double difftime(time_t end, time_t begin);

/* strftime in the C locale with glibc's flags (- _ 0 ^ #), field widths and E/O modifiers. A result that does not fit
 * in `max` bytes including the terminating NUL is 0 (and the buffer contents are unspecified). Unknown conversions
 * are copied through as written. */
size_t strftime(char *buf, size_t max, const char *format, const struct tm *tm);

#endif /* MOQI_TIME_H */
