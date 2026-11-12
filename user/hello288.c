/* hello288: rt_tgsigqueueinfo(tgid, tid, sig, info) queues the signal for the thread `tid` of process `tgid`.
 * Measured on the host (build with -DHOST): the handler runs in the named thread with the caller's si_value and si_code; a tid
 * that is not a thread of tgid (or a tgid that is not its process) is ESRCH; tid or tgid <= 0 and a signal above 64 are EINVAL;
 * signal 0 only probes; an unreadable info pointer is EFAULT.
 * rt_sigqueueinfo(pid, sig, info) (F): a forged code (SI_USER) is allowed only towards the caller's own tid, so a non-main thread gets
 * EPERM for getpid(); a missing pid is ESRCH ahead of signal 65 (EINVAL). G/H: SIGSTOP and SIGCONT queued with either call for the
 * second thread of a child stop and continue the whole child (waitpid reports 0x137f and 0xffff). */
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
#include <fcntl.h>
#include <sys/wait.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long tgsq(long tgid, long tid, long sig, void *info) {
    long r = syscall(SYS_rt_tgsigqueueinfo, tgid, tid, sig, info);
    return r < 0 ? -errno : r;
}
static long sq(long pid, long sig, void *info) {
    long r = syscall(SYS_rt_sigqueueinfo, pid, sig, info);
    return r < 0 ? -errno : r;
}
static long my_tid(void) { return syscall(SYS_gettid); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/pthread.h"
#include "../lib/moqi_libc/include/fcntl.h"
static long tgsq(long tgid, long tid, long sig, void *info) { return syscall4(226, tgid, tid, sig, (long)info); }
static long sq(long pid, long sig, void *info) { return syscall3(222, pid, sig, (long)info); }
static long my_tid(void) { return syscall0(SYS_gettid); }
#endif

#define SIGUSR1_N 10
#define SIGSTOP_N 19
#define SIGCONT_N 18
#define SI_QUEUE_N (-1)
#ifndef WNOHANG
#define WNOHANG 1
#endif
#ifndef WUNTRACED
#define WUNTRACED 2
#endif
#ifndef WCONTINUED
#define WCONTINUED 8
#endif

static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello288:   ok   " : "hello288:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

/* The kernel's 128-byte siginfo: signo, errno, code, then the kill/queue union (pid, uid, value). */
struct qinfo {
    int signo, err, code, pad;
    int pid;
    unsigned uid;
    long value;
    char rest[128 - 32];
};

static volatile long ran_tid, ran_value, ran_code, runs;
static void on_usr1(int sig, void *info, void *uc) {
    (void)sig;
    (void)uc;
    struct qinfo *i = (struct qinfo *)info;
    ran_tid = my_tid();
    ran_value = (int)i->value;
    ran_code = i->code;
    runs++;
}
static volatile long other_tid;
static void *idle(void *a) {
    (void)a;
    other_tid = my_tid();
    for (;;) pause();
    return (void *)0;
}
static void fill(struct qinfo *q, int code, int value) {
    memset(q, 0, sizeof *q);
    q->signo = SIGUSR1_N;
    q->code = code;
    q->value = value;
}
static int wait_runs(long want) {
    for (int i = 0; i < 100 && runs < want; i++) nap(10);
    return runs >= want;
}

static long f_r1, f_r2;
static void *f_thread(void *a) {
    (void)a;
    struct qinfo fq;
    fill(&fq, 0, 3); /* SI_USER */
    f_r1 = sq(getpid(), SIGUSR1_N, &fq);
    f_r2 = sq(my_tid(), SIGUSR1_N, &fq);
    return (void *)0;
}

static int bp[2], tp[2];
static void *spin(void *a) {
    (void)a;
    long tid = my_tid();
    write(tp[1], &tid, sizeof tid);
    volatile unsigned long s = 0;
    for (;;) {
        s++;
        if ((s & 0xFFFFF) == 0) write(bp[1], "t", 1);
    }
    return (void *)0;
}
static int drain(void) {
    char b[256];
    int any = 0;
    while (read(bp[0], b, sizeof b) > 0) any = 1;
    return any;
}
static int wait_writes(void) {
    for (int i = 0; i < 300; i++) {
        if (drain()) return 1;
        nap(10);
    }
    return 0;
}
/* waitpid with a 3 s limit, so a stop that never covers the whole process fails instead of hanging the sequence. */
static long wait_for(long c, int *st, int opt) {
    for (int i = 0; i < 300; i++) {
        long r = waitpid(c, st, opt | WNOHANG);
        if (r != 0) return r;
        nap(10);
    }
    return 0;
}
static long send_via(int tg, long c, long tid, int sig) {
    struct qinfo sq_info;
    fill(&sq_info, SI_QUEUE_N, 0);
    sq_info.signo = sig;
    return tg ? tgsq(c, tid, sig, &sq_info) : sq(tid, sig, &sq_info);
}
/* A child whose second thread spins: SIGSTOP and SIGCONT queued for that thread stop and continue the whole child. */
static void group_stop_via(int tg, const char *label) {
    pipe2(bp, O_NONBLOCK);
    pipe2(tp, 0);
    long c = fork();
    if (c == 0) {
        pthread_t t;
        pthread_create(&t, (void *)0, spin, (void *)0);
        for (;;) pause();
    }
    long tid = 0;
    read(tp[0], &tid, sizeof tid);
    int started = wait_writes();
    int st = 0;
    long r = send_via(tg, c, tid, SIGSTOP_N);
    long w = wait_for(c, &st, WUNTRACED);
    drain();
    nap(200);
    int quiet = !drain();
    snprintf(msg, sizeof msg, "%s: SIGSTOP for the child's second thread stops the child, reported as 0x137f, nothing written (%ld, %ld, 0x%x, %d, %d)",
             label, r, w == c ? 1L : w, st, started, quiet);
    check(started && r == 0 && w == c && st == 0x137f && quiet, msg);
    st = 0;
    r = send_via(tg, c, tid, SIGCONT_N);
    w = wait_for(c, &st, WCONTINUED);
    int resumed = wait_writes();
    snprintf(msg, sizeof msg, "%s: SIGCONT for that thread is reported as 0xffff and the thread runs again (%ld, %ld, 0x%x, %d)",
             label, r, w == c ? 1L : w, st, resumed);
    check(r == 0 && w == c && st == 0xffff && resumed, msg);
    kill(c, 9);
    waitpid(c, &st, 0);
    close(bp[0]);
    close(bp[1]);
    close(tp[0]);
    close(tp[1]);
}

int main(void) {
#ifdef HOST
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = (void (*)(int, siginfo_t *, void *))on_usr1;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGUSR1_N, &sa, (struct sigaction *)0);
#else
    struct ksigaction sa = { (void (*)(int))on_usr1, 0x4, (void *)0, 0 };
    sigaction(SIGUSR1_N, &sa, (struct ksigaction *)0);
#endif
    pthread_t th;
    pthread_create(&th, (void *)0, idle, (void *)0);
    while (!other_tid) nap(1);
    long pid = getpid(), me = my_tid();
    struct qinfo q;
    long r;

    fill(&q, SI_QUEUE_N, 42);
    r = tgsq(pid, other_tid, SIGUSR1_N, &q);
    int ok = wait_runs(1);
    snprintf(msg, sizeof msg, "A: queued to the other thread, the handler runs there with value 42 and SI_QUEUE (%ld, %d, %s, %ld, %ld)",
             r, ok, ran_tid == other_tid ? "target" : "elsewhere", ran_value, ran_code);
    check(r == 0 && ok && ran_tid == other_tid && ran_value == 42 && ran_code == SI_QUEUE_N, msg);

    fill(&q, SI_QUEUE_N, 7);
    r = tgsq(pid, me, SIGUSR1_N, &q);
    ok = wait_runs(2);
    snprintf(msg, sizeof msg, "B: queued to the caller itself, it runs in the caller with value 7 (%ld, %d, %s, %ld)",
             r, ok, ran_tid == me ? "caller" : "elsewhere", ran_value);
    check(r == 0 && ok && ran_tid == me && ran_value == 7, msg);

    fill(&q, SI_QUEUE_N, 1);
    r = tgsq(pid + 100000, other_tid, SIGUSR1_N, &q);
    snprintf(msg, sizeof msg, "C: a tgid that is not the thread's process is ESRCH (%ld)", r);
    check(r == -3, msg);
    r = tgsq(pid, 1, SIGUSR1_N, &q);
    snprintf(msg, sizeof msg, "C: a tid that is not a thread of tgid is ESRCH (%ld)", r);
    check(r == -3, msg);

    r = tgsq(pid, 0, SIGUSR1_N, &q);
    long r2 = tgsq(0, other_tid, SIGUSR1_N, &q);
    long r3 = tgsq(pid, -1, SIGUSR1_N, &q);
    snprintf(msg, sizeof msg, "D: tid 0, tgid 0 and tid -1 are EINVAL (%ld, %ld, %ld)", r, r2, r3);
    check(r == -22 && r2 == -22 && r3 == -22, msg);
    r = tgsq(pid, other_tid, 65, &q);
    snprintf(msg, sizeof msg, "D: a signal above 64 is EINVAL (%ld)", r);
    check(r == -22, msg);

    long before = runs;
    r = tgsq(pid, other_tid, 0, &q);
    nap(100);
    snprintf(msg, sizeof msg, "E: signal 0 only probes (%ld, %ld runs)", r, runs - before);
    check(r == 0 && runs == before, msg);
    r = tgsq(pid, other_tid, SIGUSR1_N, (void *)8);
    snprintf(msg, sizeof msg, "E: an unreadable info pointer is EFAULT (%ld)", r);
    check(r == -14, msg);

    /* F: rt_sigqueueinfo's "to yourself" is the caller's tid, not its process: a non-main thread may forge SI_USER to its own tid
     * but not to getpid(); a missing pid is ESRCH ahead of a bad signal number. */
    pthread_t ft;
    pthread_create(&ft, (void *)0, f_thread, (void *)0);
    pthread_join(ft, (void **)0);
    ok = wait_runs(3);
    snprintf(msg, sizeof msg, "F: a thread's SI_USER to getpid() is EPERM, to its own tid it is queued (%ld, %ld, %d)", f_r1, f_r2, ok);
    check(f_r1 == -1 && f_r2 == 0 && ok, msg);
    fill(&q, 0, 1);
    r = sq(other_tid, SIGUSR1_N, &q);
    fill(&q, SI_QUEUE_N, 1);
    r2 = sq(999999, 65, &q);
    r3 = sq(pid, 65, &q);
    snprintf(msg, sizeof msg, "F: SI_USER to another thread is EPERM, a missing pid beats signal 65 (ESRCH), signal 65 is EINVAL (%ld, %ld, %ld)", r, r2, r3);
    check(r == -1 && r2 == -3 && r3 == -22, msg);

    /* G/H: a stop and a continue queued for one thread of another process act on the whole process. */
    group_stop_via(0, "G: rt_sigqueueinfo");
    group_stop_via(1, "H: rt_tgsigqueueinfo");

    print(failures == 0 ? "hello288: PASS\n" : "hello288: FAIL\n");
    return failures;
}
