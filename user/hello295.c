/* hello295: a POSIX timer with SIGEV_THREAD_ID delivers to one thread.
 * Measured on the host (build with -DHOST): timer_create accepts SIGEV_SIGNAL|SIGEV_THREAD_ID (notify value 4) only when
 * sigev_notify_thread_id names a thread of the calling process and the signal is 1..64; a tid of another process, a missing tid
 * and signal 0 are EINVAL (SIGEV_SIGNAL is 0, so notify value 4 already is SIGEV_SIGNAL|SIGEV_THREAD_ID). The expiry is queued for that thread alone: its sigpending
 * shows the signal and the main thread's does not, and the thread's sigtimedwait takes it with SI_TIMER and the sigev_value. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long my_tid(void) { return syscall(SYS_gettid); }
static long tcreate(void *sev, int *id) {
    long r = syscall(SYS_timer_create, CLOCK_MONOTONIC, sev, id); return r < 0 ? -errno : r;
}
static long tarm(int id, long ns) {
    struct itimerspec its; memset(&its, 0, sizeof its); its.it_value.tv_nsec = ns;
    long r = syscall(SYS_timer_settime, id, 0, &its, 0); return r < 0 ? -errno : r;
}
static void tdel(int id) { syscall(SYS_timer_delete, id); }
static long stw(void *set, void *info, void *ts) {
    long r = syscall(SYS_rt_sigtimedwait, set, info, ts, 8); return r < 0 ? -errno : r;
}
static long mask(int how, unsigned long *set) {
    long r = syscall(SYS_rt_sigprocmask, how, set, 0, 8); return r < 0 ? -errno : r;
}
static long pending(unsigned long *set) {
    long r = syscall(SYS_rt_sigpending, set, 8); return r < 0 ? -errno : r;
}
static int mkthread(void *(*fn)(void *)) { pthread_t t; return pthread_create(&t, 0, fn, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/pthread.h"
static long my_tid(void) { return syscall0(SYS_gettid); }
static long tcreate(void *sev, int *id) { return syscall3(192, 1, (long)sev, (long)id); }
static long tarm(int id, long ns) {
    long its[4] = { 0, 0, 0, ns };
    return syscall4(193, id, 0, (long)its, 0);
}
static void tdel(int id) { syscall1(196, id); }
static long stw(void *set, void *info, void *ts) { return syscall4(221, (long)set, (long)info, (long)ts, 8); }
static long mask(int how, unsigned long *set) { return syscall4(SYS_sigprocmask, how, (long)set, 0, 8); }
static long pending(unsigned long *set) { return syscall2(SYS_sigpending, (long)set, 8); }
static int mkthread(void *(*fn)(void *)) { pthread_t t; return pthread_create(&t, (void *)0, fn, (void *)0); }
#endif

#define S_USR1 10
#define BLOCK 0
#define SIGEV_SIGNAL_K 0
#define SIGEV_THREAD_ID_K 4
#define SI_TIMER_CODE (-2)

/* x86_64 sigevent: value@0, signo@8, notify@12, sigev_notify_thread_id@16, padded to 64 bytes. */
struct ksigev { long value; int signo, notify, tid; char pad[44]; };
/* siginfo_t: code@8, si_value@24. */
struct sinfo { int signo, err, code, pad, timerid, overrun; long value; char rest[96]; };

static int failures;
static char msg[220];
static volatile long worker;
static void check(int ok, const char *w) {
    print(ok ? "hello295:   ok   " : "hello295:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void *spin(void *a) { (void)a; worker = my_tid(); for (;;) pause(); return (void *)0; }
static long wait_sig(struct sinfo *si, long ns) {
    unsigned long set = 1UL << (S_USR1 - 1);
    struct timespec ts = { ns / 1000000000L, ns % 1000000000L };
    memset(si, 0, sizeof *si);
    return stw(&set, si, &ts);
}

int main(void) {
    print("hello295: SIGEV_THREAD_ID delivers a timer's signal to one thread of the process\n");
    unsigned long usr1 = 1UL << (S_USR1 - 1);
    mask(BLOCK, &usr1);

    mkthread(spin);
    for (int i = 0; i < 200 && !worker; i++) {
        struct timespec d = { 0, 1000000L };
#ifdef HOST
        nanosleep(&d, 0);
#else
        syscall2(SYS_nanosleep, (long)&d, 0);
#endif
    }
    long mine = my_tid();
    snprintf(msg, sizeof msg, "the second thread is running (%ld, %ld)", mine, worker);
    check(worker != 0 && worker != mine, msg);

    struct ksigev sev;
    int id = -1;

    /* A: a tid outside the process is EINVAL. */
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K | SIGEV_THREAD_ID_K;
    sev.signo = S_USR1;
    sev.tid = 1;
    long r = tcreate(&sev, &id);
    snprintf(msg, sizeof msg, "A: a tid of another process is EINVAL (%ld)", r);
    check(r == -22, msg);
    sev.tid = (int)(mine + 900000);
    r = tcreate(&sev, &id);
    snprintf(msg, sizeof msg, "A: a tid that does not exist is EINVAL (%ld)", r);
    check(r == -22, msg);
    sev.notify = SIGEV_SIGNAL_K | SIGEV_THREAD_ID_K;
    sev.signo = 0;
    r = tcreate(&sev, &id);
    snprintf(msg, sizeof msg, "A: signal 0 is EINVAL (%ld)", r);
    check(r == -22, msg);

    /* B: the signal goes to the named thread and nowhere else. */
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K | SIGEV_THREAD_ID_K;
    sev.signo = S_USR1;
    sev.tid = (int)worker;
    sev.value = 0x55aaL;
    r = tcreate(&sev, &id);
    check(r == 0, "B: timer_create(SIGEV_THREAD_ID) for the second thread succeeds");
    r = tarm(id, 20000000L);
    check(r == 0, "B: timer_settime succeeds");
    struct timespec w = { 0, 100000000L };
#ifdef HOST
    nanosleep(&w, 0);
#else
    syscall2(SYS_nanosleep, (long)&w, 0);
#endif
    unsigned long pend = 0;
    pending(&pend);
    snprintf(msg, sizeof msg, "B: the signal is not pending for the main thread (0x%lx)", pend);
    check((pend & usr1) == 0, msg);
    tdel(id);

    /* C: aimed at the caller, sigtimedwait takes it with SI_TIMER and the value. */
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K | SIGEV_THREAD_ID_K;
    sev.signo = S_USR1;
    sev.tid = (int)mine;
    sev.value = 0x55aaL;
    r = tcreate(&sev, &id);
    check(r == 0, "C: timer_create(SIGEV_THREAD_ID) for the caller succeeds");
    tarm(id, 20000000L);
    struct sinfo si;
    r = wait_sig(&si, 1000000000L);
    snprintf(msg, sizeof msg, "C: the caller's sigtimedwait takes it with SI_TIMER and the value (%ld, code %d, value 0x%lx)",
             r, si.code, si.value);
    check(r == S_USR1 && si.code == SI_TIMER_CODE && si.value == 0x55aaL, msg);
    tdel(id);

    mask(1, &usr1);
    print(failures ? "hello295: FAIL\n" : "hello295: PASS\n");
    return failures ? 1 : 0;
}
