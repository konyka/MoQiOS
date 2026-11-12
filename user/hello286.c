/* hello286: a process-directed SIGSTOP stops every thread, and the parent is told only once the whole group has stopped.
 * Measured on the host (build with -DHOST): kill(pid, SIGSTOP) stops the child's spinning thread too, waitpid reports the stop
 * once, and the thread writes nothing while the group is stopped; SIGCONT restarts it and is reported once. A child that is
 * almost always inside write() when the stop arrives also runs no more user code once the stop has been reported, and a child
 * that stops itself with kill(getpid(), SIGSTOP) runs nothing after the call until SIGCONT. A spinning thread pinned to CPU 0
 * with sched_setaffinity is stopped the same way. */
#ifdef HOST
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/pthread.h"
#endif
#ifndef WNOHANG
#define WNOHANG 1
#endif
#ifndef WUNTRACED
#define WUNTRACED 2
#endif
#ifndef WCONTINUED
#define WCONTINUED 8
#endif
#ifndef SIGSTOP
#define SIGSTOP 19
#endif
#ifndef SIGTSTP
#define SIGTSTP 20
#endif
#ifndef SIGCONT
#define SIGCONT 18
#endif

static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello286:   ok   " : "hello286:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

static int bp[2];
static volatile long ready;
static void *spin(void *a) {
    (void)a;
    ready = 1;
    volatile unsigned long s = 0;
    for (;;) {
        s++;
        if ((s & 0xFFFFF) == 0) write(bp[1], "t", 1);
    }
    return (void *)0;
}
static volatile long pinned;
static void *spin_cpu0(void *a) {
    (void)a;
    unsigned long mask = 1;
#ifdef HOST
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(0, &set);
    sched_setaffinity(0, sizeof set, &set);
    (void)mask;
#else
    syscall3(273, 0, sizeof mask, (long)&mask);
#endif
    pinned = 1;
    volatile unsigned long s = 0;
    for (;;) {
        s++;
        if ((s & 0xFFFFF) == 0) write(bp[1], "g", 1);
    }
    return (void *)0;
}
static int tp[2];
static void *spin_tid(void *a) {
    (void)a;
#ifdef HOST
    long me = syscall(SYS_gettid);
#else
    long me = syscall0(SYS_gettid);
#endif
    write(tp[1], &me, sizeof me);
    volatile unsigned long s = 0;
    for (;;) {
        s++;
        if ((s & 0xFFFFF) == 0) write(bp[1], "h", 1);
    }
    return (void *)0;
}
static long tkill_call(long tid, int sig) {
#ifdef HOST
    return syscall(SYS_tkill, tid, sig);
#else
    return syscall2(SYS_tkill, tid, sig);
#endif
}
static void *short_lived(void *a) { return a; }
static void *churn(void *a) {
    (void)a;
    for (;;) {
        pthread_t t;
        if (pthread_create(&t, (void *)0, short_lived, (void *)0) == 0) pthread_join(t, (void **)0);
        write(bp[1], "c", 1);
    }
    return (void *)0;
}
static long wait_report(long c, int *st, int opt) {
    long r = 0;
    for (int i = 0; i < 300 && r == 0; i++) {
        r = waitpid(c, st, opt | WNOHANG);
        if (r == 0) nap(10);
    }
    return r;
}
static int drain(void) {
    char b[256];
    int any = 0;
    while (read(bp[0], b, sizeof b) > 0) any = 1;
    return any;
}

int main(void) {
    int st = 0;
    pipe2(bp, O_NONBLOCK);
    long c = fork();
    if (c == 0) {
        pthread_t th;
        pthread_create(&th, (void *)0, spin, (void *)0);
        while (!ready) nap(1);
        for (;;) pause();
    }
    int started = 0;
    for (int i = 0; i < 300 && !started; i++) {
        started = drain();
        if (!started) nap(10);
    }
    kill(c, SIGSTOP);
    long r = waitpid(c, &st, WUNTRACED);
    snprintf(msg, sizeof msg, "A: the group stop is reported as 0x137f (%ld, 0x%x)", r, st);
    check(started && r == c && st == 0x137f, msg);
    drain();
    nap(200);
    snprintf(msg, sizeof msg, "A: the spinning thread writes nothing while the group is stopped");
    check(!drain(), msg);
    r = waitpid(c, &st, WUNTRACED | WNOHANG);
    snprintf(msg, sizeof msg, "A: the stop is reported only once (%ld)", r);
    check(r == 0, msg);
    kill(c, SIGCONT);
    st = 0;
    r = waitpid(c, &st, WCONTINUED);
    snprintf(msg, sizeof msg, "B: SIGCONT is reported once as 0xffff (%ld, 0x%x)", r, st);
    check(r == c && st == 0xffff, msg);
    int resumed = 0;
    for (int i = 0; i < 300 && !resumed; i++) {
        resumed = drain();
        if (!resumed) nap(10);
    }
    check(resumed, "B: the spinning thread runs again after SIGCONT");
    r = waitpid(c, &st, WCONTINUED | WNOHANG);
    snprintf(msg, sizeof msg, "B: the continue is reported only once (%ld)", r);
    check(r == 0, msg);
    kill(c, 9);
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "C: SIGKILL of the stopped group is reported as signal 9 (%ld, 0x%x)", r, st);
    check(r == c && st == 9, msg);
    drain();
    nap(200);
    check(!drain(), "C: and no thread of the killed child is left running (nothing written afterwards)");

    /* D: a child that is almost always inside write() takes the stop on its way out of the call, not from the reschedule IPI; it must
     * still run no more user code once the stop has been reported. */
    drain();
    c = fork();
    if (c == 0) {
        for (;;) write(bp[1], "d", 1);
    }
    started = 0;
    for (int i = 0; i < 300 && !started; i++) {
        started = drain();
        if (!started) nap(10);
    }
    kill(c, SIGSTOP);
    st = 0;
    r = waitpid(c, &st, WUNTRACED);
    snprintf(msg, sizeof msg, "D: a child stopped while in write() is reported as 0x137f (%ld, 0x%x)", r, st);
    check(started && r == c && st == 0x137f, msg);
    drain();
    nap(200);
    check(!drain(), "D: and it writes nothing more while stopped");
    kill(c, 9);
    waitpid(c, &st, 0);

    /* E: a child that stops itself takes the stop on its way out of kill(); the write after it must wait for SIGCONT. */
    drain();
    c = fork();
    if (c == 0) {
        kill(getpid(), SIGSTOP);
        for (;;) write(bp[1], "e", 1);
    }
    st = 0;
    r = waitpid(c, &st, WUNTRACED);
    snprintf(msg, sizeof msg, "E: a self-stopped child is reported as 0x137f (%ld, 0x%x)", r, st);
    check(r == c && st == 0x137f, msg);
    nap(200);
    check(!drain(), "E: and runs no code after kill(getpid(), SIGSTOP) until SIGCONT");
    kill(c, SIGCONT);
    resumed = 0;
    for (int i = 0; i < 300 && !resumed; i++) {
        resumed = drain();
        if (!resumed) nap(10);
    }
    check(resumed, "E: SIGCONT lets it run on");
    kill(c, 9);
    waitpid(c, &st, 0);

    /* F: the same self-stop while the parent sleeps instead of waiting: no parent wake-up takes the child off its CPU, so the
     * stop alone must keep it out of user mode. */
    drain();
    c = fork();
    if (c == 0) {
        kill(getpid(), SIGSTOP);
        for (;;) write(bp[1], "f", 1);
    }
    nap(300);
    check(!drain(), "F: a child that stopped itself while its parent slept runs no code after kill()");
    st = 0;
    r = waitpid(c, &st, WUNTRACED | WNOHANG);
    snprintf(msg, sizeof msg, "F: and its stop is reported as 0x137f (%ld, 0x%x)", r, st);
    check(r == c && st == 0x137f, msg);
    kill(c, 9);
    waitpid(c, &st, 0);

    /* G: the spinning thread is pinned to CPU 0, the CPU whose idle thread another CPU may have taken; the stop must still keep
     * it out of user mode. Repeated because the window is a timer tick wide. */
    for (int round = 0; round < 4; round++) {
        drain();
        pinned = 0;
        c = fork();
        if (c == 0) {
            pthread_t th;
            pthread_create(&th, (void *)0, spin_cpu0, (void *)0);
            while (!pinned) nap(1);
            for (;;) pause();
        }
        started = 0;
        for (int i = 0; i < 300 && !started; i++) {
            started = drain();
            if (!started) nap(10);
        }
        kill(c, SIGSTOP);
        st = 0;
        r = waitpid(c, &st, WUNTRACED);
        snprintf(msg, sizeof msg, "G%d: a group whose spinning thread is pinned to CPU 0 is reported stopped (%ld, 0x%x)", round, r, st);
        check(started && r == c && st == 0x137f, msg);
        drain();
        nap(200);
        snprintf(msg, sizeof msg, "G%d: and the pinned thread writes nothing while stopped", round);
        check(!drain(), msg);
        kill(c, 9);
        waitpid(c, &st, 0);
    }

    /* H: tkill on one thread with SIGSTOP, SIGCONT or SIGKILL acts on the whole process, as kill(pid) does. */
    drain();
    pipe(tp);
    c = fork();
    if (c == 0) {
        pthread_t th;
        pthread_create(&th, (void *)0, spin_tid, (void *)0);
        for (;;) pause();
    }
    long ttid = 0;
    read(tp[0], &ttid, sizeof ttid);
    started = 0;
    for (int i = 0; i < 300 && !started; i++) {
        started = drain();
        if (!started) nap(10);
    }
    tkill_call(ttid, SIGSTOP);
    st = 0;
    r = waitpid(c, &st, WUNTRACED);
    snprintf(msg, sizeof msg, "H: tkill(thread, SIGSTOP) stops the group and is reported as 0x137f (%ld, 0x%x)", r, st);
    check(started && r == c && st == 0x137f, msg);
    drain();
    nap(200);
    check(!drain(), "H: and the thread writes nothing while stopped");
    tkill_call(ttid, SIGCONT);
    st = 0;
    r = waitpid(c, &st, WCONTINUED);
    snprintf(msg, sizeof msg, "H: tkill(thread, SIGCONT) is reported once as 0xffff (%ld, 0x%x)", r, st);
    check(r == c && st == 0xffff, msg);
    resumed = 0;
    for (int i = 0; i < 300 && !resumed; i++) {
        resumed = drain();
        if (!resumed) nap(10);
    }
    check(resumed, "H: and the thread runs again");
    r = waitpid(c, &st, WCONTINUED | WNOHANG);
    snprintf(msg, sizeof msg, "H: the continue is reported only once (%ld)", r);
    check(r == 0, msg);
    kill(c, SIGSTOP);
    waitpid(c, &st, WUNTRACED);
    drain();
    tkill_call(c, SIGCONT);
    st = 0;
    r = waitpid(c, &st, WCONTINUED);
    snprintf(msg, sizeof msg, "H: tkill(leader, SIGCONT) after kill(pid, SIGSTOP) is reported as 0xffff (%ld, 0x%x)", r, st);
    check(r == c && st == 0xffff, msg);
    resumed = 0;
    for (int i = 0; i < 300 && !resumed; i++) {
        resumed = drain();
        if (!resumed) nap(10);
    }
    check(resumed, "H: and the other thread runs again too");
    tkill_call(ttid, 9);
    st = 0;
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "H: tkill(thread, SIGKILL) ends the process, reported as signal 9 (%ld, 0x%x)", r, st);
    check(r == c && st == 9, msg);

    /* I: a default stop that is already pending when the task goes to sleep in sigsuspend (it was blocked, sigsuspend unblocks it)
     * stops the task; after SIGCONT it keeps waiting in sigsuspend. */
    c = fork();
    if (c == 0) {
        setpgid(0, 0);
        sigset_t b, e;
        sigemptyset(&b);
        sigaddset(&b, SIGTSTP);
        sigprocmask(SIG_BLOCK, &b, (sigset_t *)0);
        raise(SIGTSTP);
        sigemptyset(&e);
        sigsuspend(&e);
        _exit(3);
    }
    setpgid(c, c);
    st = 0;
    r = 0;
    for (int i = 0; i < 300 && r == 0; i++) {
        r = waitpid(c, &st, WUNTRACED | WNOHANG);
        if (r == 0) nap(10);
    }
    snprintf(msg, sizeof msg, "I: sigsuspend unblocking a pending SIGTSTP stops the task, reported as 0x147f (%ld, 0x%x)", r, st);
    check(r == c && st == 0x147f, msg);
    kill(c, SIGCONT);
    nap(200);
    r = waitpid(c, &st, WNOHANG);
    snprintf(msg, sizeof msg, "I: after SIGCONT it keeps waiting in sigsuspend (%ld)", r);
    check(r == 0, msg);
    kill(c, 9);
    st = 0;
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "I: and SIGKILL ends it (%ld, 0x%x)", r, st);
    check(r == c && st == 9, msg);

    /* J: threads keep being created and exiting while the process is stopped and continued. A member that exits instead of stopping
     * still completes the group stop, and a thread created while the stop is in progress stops too. */
    drain();
    c = fork();
    if (c == 0) {
        pthread_t th;
        pthread_create(&th, (void *)0, churn, (void *)0);
        for (;;) pause();
    }
    started = 0;
    for (int i = 0; i < 300 && !started; i++) {
        started = drain();
        if (!started) nap(10);
    }
    int stops = 0, quiet = 0, conts = 0;
    for (int round = 0; round < 60; round++) {
        kill(c, SIGSTOP);
        st = 0;
        if (wait_report(c, &st, WUNTRACED) == c && st == 0x137f) stops++;
        else break;
        drain();
        nap(30);
        if (!drain()) quiet++;
        kill(c, SIGCONT);
        st = 0;
        if (wait_report(c, &st, WCONTINUED) == c && st == 0xffff) conts++;
        else break;
        nap(5);
    }
    snprintf(msg, sizeof msg, "J: 60 group stops while threads come and go are all reported (%d/60)", stops);
    check(started && stops == 60, msg);
    snprintf(msg, sizeof msg, "J: and nothing runs while the group is stopped (%d/%d)", quiet, stops);
    check(quiet == stops && stops > 0, msg);
    snprintf(msg, sizeof msg, "J: and every continue is reported (%d/60)", conts);
    check(conts == 60, msg);
    kill(c, 9);
    waitpid(c, &st, 0);

    print(failures == 0 ? "hello286: PASS\n" : "hello286: FAIL\n");
    return failures;
}
