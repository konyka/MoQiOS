/* hello433: a signal sent to a task asleep in rt_sigtimedwait for it wakes the task at once (Linux: during the wait the task's
 * blocked set leaves out the waited signals, so signal_wake_up wakes it; do_sigtimedwait then dequeues). The kernel used to leave the
 * waiter asleep until its next 10 ms poll, so every hand-off cost up to a tick.
 * Two processes block SIGUSR1 and SIGUSR2 and pass the turn 50 times: the parent sends SIGUSR1 and waits for SIGUSR2, the child waits
 * for SIGUSR1 and answers with SIGUSR2. Each wait has a 2 s timeout so a lost wake cannot hang the test.
 * Measured on the host (build with -DHOST):
 *   A. 50 round trips: every wait returns the signal it waited for, with si_pid of the other process; all of them take about 1 ms
 *      (limit 300 ms; with one 10 ms tick per wait they took over 1000 ms);
 *   B. the child exits 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sys4(long n, long a, long b, long c, long d) { long r = syscall(n, a, b, c, d); return r < 0 ? -errno : r; }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static long fork_(void) { return fork(); }
static long wait_(long pid, int *st) { return waitpid((pid_t)pid, st, 0); }
#define NR_TIMEDWAIT 128
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sys4(long n, long a, long b, long c, long d) { return syscall4(n, a, b, c, d); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static long fork_(void) { return fork(); }
static long wait_(long pid, int *st) { return waitpid(pid, st, 0); }
#define NR_TIMEDWAIT 221
#endif
#define ROUNDS 50
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello433:   ok   " : "hello433:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* Wait up to 2 s for `sig`: the signal number taken (or -errno); the sender's pid in *from. */
static long take(int sig, long *from) {
    unsigned long set = 1UL << (sig - 1);
    long ts[2] = { 2, 0 };
    int info[32];
    memset(info, 0, sizeof info);
    long r = sys4(NR_TIMEDWAIT, (long)&set, (long)info, (long)ts, 8);
    *from = info[4];
    return r;
}
int main(void) {
    print("hello433: a signal wakes its rt_sigtimedwait waiter at once\n");
    unsigned long both = (1UL << 9) | (1UL << 11);
    sys4(14, 0, (long)&both, 0, 8);
    long parent = getpid();
    long child = fork_();
    if (child == 0) {
        int bad = 0;
        for (int i = 0; i < ROUNDS; i++) {
            long from = 0;
            if (take(10, &from) != 10 || from != parent) bad++;
            kill(parent, 12);
        }
        _exit(bad == 0 ? 0 : 1);
    }
    int good = 0, wrong_pid = 0;
    long t0 = now_ms();
    for (int i = 0; i < ROUNDS; i++) {
        kill(child, 10);
        long from = 0;
        long r = take(12, &from);
        if (r == 12) good++;
        if (r == 12 && from != child) wrong_pid++;
        if (r != 12) break;
    }
    long el = now_ms() - t0;
    snprintf(msg, sizeof msg, "A: fork %ld; %d of %d round trips took SIGUSR2, %d with a wrong si_pid, in %ld ms (%d, 0, <300)", child, good, ROUNDS, wrong_pid,
             el, ROUNDS);
    check(child > 0 && good == ROUNDS && wrong_pid == 0 && el < 300, msg);
    int st = -1;
    long w = wait_(child, &st);
    snprintf(msg, sizeof msg, "B: waitpid %ld, child status 0x%x (child pid, 0)", w, st);
    check(w == child && st == 0, msg);
    print(failures == 0 ? "hello433: PASS\n" : "hello433: FAIL\n");
    return failures == 0 ? 0 : 1;
}
