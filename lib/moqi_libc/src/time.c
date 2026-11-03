/* time.c — clock and sleep wrappers (see include/time.h). */
#include "../include/moqi_syscalls.h"
#include "../include/time.h"

/* The host unit test links this file against a recording stub instead of the real `syscall` instruction. */
#ifdef MOQI_HOST_TEST_SYSCALL
extern long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6);
#define TM_SYSCALL4(nr, a1, a2, a3, a4) moqi_test_syscall6((nr), (a1), (a2), (a3), (a4), 0, 0)
#else
#define TM_SYSCALL4(nr, a1, a2, a3, a4) syscall4((nr), (a1), (a2), (a3), (a4))
#endif

/* A kernel return value in [-4095, -1] is an error, as in glibc. */
static int tm_is_error(long ret) {
    return (unsigned long)ret > (unsigned long)-4095L - 1;
}

static int tm_int(long ret) {
    if (tm_is_error(ret)) {
        errno = (int)-ret;
        return -1;
    }
    return 0;
}

int clock_gettime(int clock_id, struct timespec *tp) {
    return tm_int(TM_SYSCALL4(SYS_clock_gettime, clock_id, (long)tp, 0, 0));
}

int clock_getres(int clock_id, struct timespec *res) {
    return tm_int(TM_SYSCALL4(SYS_clock_getres, clock_id, (long)res, 0, 0));
}

int gettimeofday(struct timeval *tv, void *tz) {
    return tm_int(TM_SYSCALL4(SYS_gettimeofday, (long)tv, (long)tz, 0, 0));
}

time_t time(time_t *t) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return (time_t)-1;
    if (t) *t = ts.tv_sec;
    return ts.tv_sec;
}

int nanosleep(const struct timespec *req, struct timespec *rem) {
    return tm_int(TM_SYSCALL4(SYS_nanosleep, (long)req, (long)rem, 0, 0));
}

int clock_nanosleep(int clock_id, int flags, const struct timespec *req, struct timespec *rem) {
    long ret = TM_SYSCALL4(SYS_clock_nanosleep, clock_id, flags, (long)req, (long)rem);
    return tm_is_error(ret) ? (int)-ret : 0;
}

unsigned int sleep(unsigned int seconds) {
    if (seconds == 0) return 0;
    struct timespec req = { (long)seconds, 0 };
    struct timespec rem = { 0, 0 };
    if (nanosleep(&req, &rem) == 0) return 0;
    if (errno != EINTR) return seconds;
    unsigned int left = (unsigned int)rem.tv_sec + (rem.tv_nsec > 0 ? 1u : 0u);
    return left;
}

int usleep(unsigned long usec) {
    struct timespec req = { (long)(usec / 1000000UL), (long)(usec % 1000000UL) * 1000L };
    return nanosleep(&req, (struct timespec *)0);
}
