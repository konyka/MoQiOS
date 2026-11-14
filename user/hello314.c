/* hello314: the CPU-time clocks never go backwards. A reader thread spins reading CLOCK_PROCESS_CPUTIME_ID while sibling threads
 * sleep and wake over and over (each wake is a new claim of the thread by some CPU); every reading must be at least the one before.
 * The reader also checks its own CLOCK_THREAD_CPUTIME_ID, and the clock may not run faster than wall time times the thread count.
 * Measured on the host (build with -DHOST): no reading goes backwards in either clock. */
#ifdef HOST
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long clk_ns(long clk) { struct timespec t; clock_gettime((clockid_t)clk, &t); return t.tv_sec * 1000000000L + t.tv_nsec; }
static void nap_us(long us) { struct timespec t = { 0, us * 1000L }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/pthread.h"
static long clk_ns(long clk) {
    long ts[2] = { 0, 0 };
    long r = syscall2(SYS_clock_gettime, clk, (long)ts);
    return r < 0 ? r : ts[0] * 1000000000L + ts[1];
}
static void nap_us(long us) { struct timespec t = { 0, us * 1000L }; nanosleep(&t, 0); }
#endif

#define MONO 1
#define PROC_CLK 2
#define THREAD_CLK 3
#define SLEEPERS 3

static volatile int stop;
static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello314:   ok   " : "hello314:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static void *sleeper(void *arg) {
    (void)arg;
    while (!stop) nap_us(500);
    return 0;
}

int main(void) {
    print("hello314: CPU-time clocks are monotonic while sibling threads sleep and wake\n");
    pthread_t th[SLEEPERS];
    for (int i = 0; i < SLEEPERS; i++) pthread_create(&th[i], 0, sleeper, 0);

    long w0 = clk_ns(MONO), p0 = clk_ns(PROC_CLK);
    long prev_p = p0, prev_t = clk_ns(THREAD_CLK);
    long back_p = 0, back_t = 0, worst_p = 0, worst_t = 0, reads = 0;
    while (clk_ns(MONO) - w0 < 1500000000L) {
        long p = clk_ns(PROC_CLK), t = clk_ns(THREAD_CLK);
        if (p < prev_p) { back_p++; if (prev_p - p > worst_p) worst_p = prev_p - p; }
        if (t < prev_t) { back_t++; if (prev_t - t > worst_t) worst_t = prev_t - t; }
        if (p > prev_p) prev_p = p;
        if (t > prev_t) prev_t = t;
        reads++;
    }
    long w1 = clk_ns(MONO), p1 = clk_ns(PROC_CLK);
    stop = 1;
    for (int i = 0; i < SLEEPERS; i++) pthread_join(th[i], 0);

    snprintf(msg, sizeof msg, "A: the process CPU clock never goes backwards (%ld of %ld readings, worst %ld us)", back_p, reads, worst_p / 1000);
    check(back_p == 0, msg);
    snprintf(msg, sizeof msg, "B: the reader's thread CPU clock never goes backwards (%ld readings back, worst %ld us)", back_t, worst_t / 1000);
    check(back_t == 0, msg);
    snprintf(msg, sizeof msg, "C: the process clock advanced no faster than wall time times the threads (%ld ms CPU in %ld ms)",
             (p1 - p0) / 1000000, (w1 - w0) / 1000000);
    check(p1 >= p0 && p1 - p0 <= (w1 - w0) * (SLEEPERS + 1) + 20000000L, msg);
    print(failures == 0 ? "hello314: PASS\n" : "hello314: FAIL\n");
    return failures;
}
