/* hello315: clock_nanosleep on CLOCK_PROCESS_CPUTIME_ID (2) sleeps until the process has used that much CPU (Linux
 * posix_cpu_nsleep); CLOCK_THREAD_CPUTIME_ID (3) stays EOPNOTSUPP.
 * Measured on the host (build with -DHOST):
 *   A. a relative 50 ms sleep returns 0 once a sibling thread has burned 50 ms of CPU for the process;
 *   B. an absolute deadline 30 ms of process CPU ahead returns 0 the same way;
 *   C. an absolute deadline already passed returns 0 at once;
 *   D. with no thread burning, a 10 s sleep does not end by itself; SIGALRM after 1 s interrupts it with EINTR and rem
 *      reports nearly the whole 10 s (the sleeping process used next to no CPU);
 *   E. the raw system call on the thread clock is EOPNOTSUPP (glibc's wrapper turns that into EINVAL, so it is called directly). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long clk_ns(long clk) { struct timespec t; clock_gettime((clockid_t)clk, &t); return t.tv_sec * 1000000000L + t.tv_nsec; }
#include <sys/syscall.h>
static long raw_cns(long clk, long flags, void *req) { long r = syscall(SYS_clock_nanosleep, clk, flags, req, 0); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/pthread.h"
#define EINTR 4
#define EINVAL 22
#define EOPNOTSUPP 95
static long clk_ns(long clk) {
    long ts[2] = { 0, 0 };
    long r = syscall2(SYS_clock_gettime, clk, (long)ts);
    return r < 0 ? r : ts[0] * 1000000000L + ts[1];
}
static long raw_cns(long clk, long flags, void *req) { return syscall4(SYS_clock_nanosleep, clk, flags, (long)req, 0); }
#endif

#define MONO 1
#define PROC_CLK 2
#define THREAD_CLK 3
#define ABSTIME 1
#define NS 1000000000L

static volatile int burn, quit;
static volatile int alarmed;
static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello315:   ok   " : "hello315:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void *burner(void *arg) {
    (void)arg;
    while (!quit) {
        if (!burn) { struct timespec t = { 0, 1000000L }; nanosleep(&t, 0); continue; }
        volatile double x = 0;
        for (int i = 0; i < 20000; i++) x += i;
        (void)x;
    }
    return 0;
}
static void on_alarm(int s) { (void)s; alarmed = 1; }
static int cns(long clk, int flags, long ns, struct timespec *rem) {
    struct timespec req = { ns / NS, ns % NS };
    return clock_nanosleep((int)clk, flags, &req, rem);
}

int main(void) {
    print("hello315: clock_nanosleep on CLOCK_PROCESS_CPUTIME_ID\n");
    pthread_t th;
    pthread_create(&th, 0, burner, 0);

    burn = 1;
    long c0 = clk_ns(PROC_CLK), w0 = clk_ns(MONO);
    int r = cns(PROC_CLK, 0, 50000000L, 0);
    long used = clk_ns(PROC_CLK) - c0, wall = clk_ns(MONO) - w0;
    snprintf(msg, sizeof msg, "A: a relative 50 ms sleep ends once the process used 50 ms of CPU (%d, CPU %ld ms, wall %ld ms)", r,
             used / 1000000, wall / 1000000);
    check(r == 0 && used >= 50000000L && wall < 5 * NS, msg);

    long due = clk_ns(PROC_CLK) + 30000000L;
    r = cns(PROC_CLK, ABSTIME, due, 0);
    long now = clk_ns(PROC_CLK);
    snprintf(msg, sizeof msg, "B: an absolute deadline 30 ms of CPU ahead is reached (%d, %ld ms past)", r, (now - due) / 1000000);
    check(r == 0 && now >= due, msg);
    burn = 0;

    w0 = clk_ns(MONO);
    r = cns(PROC_CLK, ABSTIME, clk_ns(PROC_CLK) - 1000000L, 0);
    wall = clk_ns(MONO) - w0;
    snprintf(msg, sizeof msg, "C: a deadline already passed returns at once (%d, wall %ld ms)", r, wall / 1000000);
    check(r == 0 && wall < 100000000L, msg);

    signal(SIGALRM, on_alarm);
    struct timespec rem = { -1, -1 };
    w0 = clk_ns(MONO);
    alarm(1);
    r = cns(PROC_CLK, 0, 10 * NS, &rem);
    wall = clk_ns(MONO) - w0;
    long left = rem.tv_sec * NS + rem.tv_nsec;
    snprintf(msg, sizeof msg, "D: with nothing burning, SIGALRM ends a 10 s CPU sleep with EINTR (%d after %ld ms, handler %d, rem %ld ms)", r,
             wall / 1000000, alarmed, left / 1000000);
    check(r == EINTR && alarmed && wall >= 900000000L && left > 9 * NS && left <= 10 * NS, msg);

    struct timespec one = { 0, 1000000L };
    long e1 = raw_cns(THREAD_CLK, 0, &one);
    snprintf(msg, sizeof msg, "E: clock_nanosleep on the thread clock is EOPNOTSUPP (%ld)", e1);
    check(e1 == -EOPNOTSUPP, msg);

    quit = 1;
    pthread_join(th, 0);
    print(failures == 0 ? "hello315: PASS\n" : "hello315: FAIL\n");
    return failures;
}
