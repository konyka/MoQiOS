/* hello288: rt_tgsigqueueinfo(tgid, tid, sig, info) queues the signal for the thread `tid` of process `tgid`.
 * Measured on the host (build with -DHOST): the handler runs in the named thread with the caller's si_value and si_code; a tid
 * that is not a thread of tgid (or a tgid that is not its process) is ESRCH; tid or tgid <= 0 and a signal above 64 are EINVAL;
 * signal 0 only probes; an unreadable info pointer is EFAULT. */
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
static long tgsq(long tgid, long tid, long sig, void *info) {
    long r = syscall(SYS_rt_tgsigqueueinfo, tgid, tid, sig, info);
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
static long tgsq(long tgid, long tid, long sig, void *info) { return syscall4(226, tgid, tid, sig, (long)info); }
static long my_tid(void) { return syscall0(SYS_gettid); }
#endif

#define SIGUSR1_N 10
#define SI_QUEUE_N (-1)

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

    print(failures == 0 ? "hello288: PASS\n" : "hello288: FAIL\n");
    return failures;
}
