/* hello225: pause(), alarm() and gettid() on the real kernel. pause() must sleep until a signal is delivered and return -EINTR
 * after the handler ran (it used to return at once), alarm() must report the seconds left, and gettid() must name the calling
 * thread (getpid() names the thread group). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/pthread.h"

#define SIGALRM 14
#define SYS_pause_  34
#define SYS_alarm_  37
#define SYS_gettid_ 497

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello225:   ok   " : "hello225:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile int alarms;
static void on_alrm(int s) { (void)s; alarms++; }

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static volatile long worker_tid;
static void *worker(void *arg) {
    (void)arg;
    worker_tid = syscall0(SYS_gettid_);
    return (void *)0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello225: pause, alarm and gettid\n");

    /* A: gettid */
    long me = syscall0(SYS_gettid_);
    check(me > 0 && me == getpid(), "A: in the main thread gettid() equals getpid()");
    pthread_t t;
    check(pthread_create(&t, (void *)0, worker, (void *)0) == 0, "A: a thread is created");
    pthread_join(t, (void **)0);
    check(worker_tid > 0 && worker_tid != me, "A: and sees its own thread id, not the process id");

    /* B: pause blocks until the signal arrives */
    struct ksigaction a = { on_alrm, 0, 0, 0 };
    check(sigaction(SIGALRM, &a, (struct ksigaction *)0) == 0, "B: SIGALRM handler installed");
    long t0 = now_ms();
    check(syscall1(SYS_alarm_, 1) == 0, "B: alarm(1) with nothing pending returns 0");
    long r = syscall0(SYS_pause_);
    long dt = now_ms() - t0;
    check(r == -EINTR, "B: pause() returns -EINTR");
    check(alarms == 1, "B: and the handler ran before it returned");
    check(dt >= 900 && dt < 3000, "B: after about a second (it must have waited for the signal, not returned at once)");

    /* C: alarm reports what is left, and 0 cancels */
    check(syscall1(SYS_alarm_, 5) == 0, "C: alarm(5)");
    long left = syscall1(SYS_alarm_, 0);
    check(left == 5 || left == 4, "C: alarm(0) returns the seconds left (5 or 4)");
    check(syscall1(SYS_alarm_, 0) == 0, "C: and the alarm is then cancelled");

    print(failures == 0 ? "hello225: PASS\n" : "hello225: FAIL\n");
    return failures;
}
