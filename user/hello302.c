/* hello302: a SIGSTOP that lands while a process sleeps in nanosleep stops it at once (waitpid reports 0x137f) instead of when the
 * sleep would end. The child sleeps 400 ms at a time; the parent measures how long the stop takes to be reported and requires less
 * than 200 ms, so a stop that waits for the deadline fails. Nothing runs while it is stopped, and SIGCONT (0xffff) makes the sleep go
 * on and finish. Measured on the host (build with -DHOST): 8/8 rounds and 40/40 rounds where the stop is sent a varying moment
 * after a sleep starts, also under taskset -c 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static long sleep_ms(long ms) {
    struct timespec t = { ms / 1000, (ms % 1000) * 1000000L };
    return nanosleep(&t, 0) < 0 ? -errno : 0;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
static long now_ms(void) {
    long t[2] = { 0, 0 };
    syscall2(SYS_clock_gettime, 1 /* CLOCK_MONOTONIC */, (long)t);
    return t[0] * 1000 + t[1] / 1000000;
}
static long sleep_ms(long ms) {
    long t[2] = { ms / 1000, (ms % 1000) * 1000000L };
    return syscall2(35, (long)t, 0);
}
#endif

#define S_KILL 9
#define S_STOP 19
#define S_CONT 18
#define O_WNOHANG 1
#define O_WUNTRACED 2
#define O_WCONTINUED 8
#define SLEEP_MS 400
#define LATE_MS 200
#define ROUNDS 8
#define RACE_ROUNDS 40

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello302:   ok   " : "hello302:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static int bp[2];
static int drain(void) {
    char b[64];
    int any = 0;
    while (read(bp[0], b, sizeof b) > 0) any = 1;
    return any;
}
/* Poll for the report every 2 ms for up to 3 s; *took is how long it took. */
static long wait_report(long c, int *st, int opt, long *took) {
    long t0 = now_ms(), r = 0;
    for (int i = 0; i < 1500 && r == 0; i++) {
        r = waitpid(c, st, opt | O_WNOHANG);
        if (r == 0) nap(2);
    }
    if (took) *took = now_ms() - t0;
    return r;
}
static int got_back(void) {
    for (int i = 0; i < 400; i++) {
        if (drain()) return 1;
        nap(5);
    }
    return 0;
}

int main(void) {
    print("hello302: a SIGSTOP in a long nanosleep is taken at once\n");
    if (pipe(bp) != 0) {
        print("hello302: FAIL (pipe)\n");
        return 1;
    }
    fcntl(bp[0], F_SETFL, O_NONBLOCK);
    int st = 0;
    long c = fork();
    if (c == 0) {
        for (;;) {
            if (sleep_ms(SLEEP_MS) == 0) write(bp[1], "r", 1);
        }
    }
    /* A first completed sleep shows the child is in its loop. */
    int started = got_back();
    int stops = 0, quiet = 0, conts = 0, back = 0;
    long worst = 0, took = 0;
    for (int round = 0; started && round < ROUNDS; round++) {
        nap(100); /* well inside the next 400 ms sleep */
        kill(c, S_STOP);
        st = 0;
        if (wait_report(c, &st, O_WUNTRACED, &took) == c && st == 0x137f) {
            if (took > worst) worst = took;
            if (took < LATE_MS) stops++;
        } else break;
        drain();
        nap(20);
        if (!drain()) quiet++;
        kill(c, S_CONT);
        st = 0;
        if (wait_report(c, &st, O_WCONTINUED, 0) == c && st == 0xffff) conts++;
        else break;
        if (got_back()) back++;
        else break;
    }
    /* Race: the stop is sent a varying moment after a sleep completes, so some land while the child is still running on its way into
     * the next sleep. */
    int rstops = 0;
    long rworst = 0;
    for (int round = 0; started && back == ROUNDS && round < RACE_ROUNDS; round++) {
        drain();
        while (!drain()) nap(1); /* a sleep has just completed */
        for (volatile int k = 0; k < (round % 20) * 1000; k++) {}
        kill(c, S_STOP);
        st = 0;
        if (wait_report(c, &st, O_WUNTRACED, &took) == c && st == 0x137f) {
            if (took > rworst) rworst = took;
            if (took < LATE_MS) rstops++;
        } else break;
        kill(c, S_CONT);
        st = 0;
        if (wait_report(c, &st, O_WCONTINUED, 0) != c) break;
    }
    kill(c, S_KILL);
    waitpid(c, &st, 0);
    snprintf(what, sizeof what, "a SIGSTOP stops a sleeping child within %d ms (%d/%d, slowest %ld ms), nothing runs while stopped (%d), SIGCONT (%d), the sleep finishes (%d)",
             LATE_MS, stops, ROUNDS, worst, quiet, conts, back);
    check(started && stops == ROUNDS && quiet == ROUNDS && conts == ROUNDS && back == ROUNDS, what);
    snprintf(what, sizeof what, "a SIGSTOP sent a varying moment after a sleep ends is taken within %d ms (%d/%d, slowest %ld ms)", LATE_MS, rstops, RACE_ROUNDS, rworst);
    check(rstops == RACE_ROUNDS, what);
    print(failures == 0 ? "hello302: PASS\n" : "hello302: FAIL\n");
    return failures;
}
