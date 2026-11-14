/* hello332: an mq_notify registration belongs to the process (Linux do_mq_notify keeps task_tgid, mqueue_flush_file, __do_notify).
 * Measured on the host (build with -DHOST):
 *   A. the owner closing another open of the same queue removes the registration (flush runs on every close by the owner);
 *   B. a forked child closing the inherited descriptor, or its own open, leaves it;
 *   C. a thread of the owner closing an open of the queue removes it;
 *   D. a registration made by a thread outlives that thread, and the message signals the process (the main thread runs it);
 *   E. the signal is process-directed: the registering thread blocks it, so the main thread takes it;
 *   F. a child that registered and exited leaves no registration behind. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long mq_open4(const char *n, long flags, long mode, void *attr) {
    mqd_t q = mq_open(n, (int)flags, (mode_t)mode, (struct mq_attr *)attr);
    return q < 0 ? -errno : q;
}
static long mq_send4(long q, const char *m) { return mq_send((mqd_t)q, m, 2, 0) < 0 ? -errno : 0; }
static long mq_recv4(long q) {
    char b[16];
    return mq_receive((mqd_t)q, b, sizeof b, (unsigned *)0) < 0 ? -errno : 0;
}
static long mq_notify2(long q, void *sev) { return syscall(SYS_mq_notify, q, sev) < 0 ? -errno : 0; }
static long mq_close1(long q) { return mq_close((mqd_t)q) < 0 ? -errno : 0; }
static long mq_unlink1(const char *n) { return mq_unlink(n) < 0 ? -errno : 0; }
static long my_tid(void) { return syscall(SYS_gettid); }
static void mask_usr1(int block) {
    sigset_t m;
    sigemptyset(&m);
    sigaddset(&m, SIGUSR1);
    pthread_sigmask(block ? SIG_BLOCK : SIG_UNBLOCK, &m, 0);
}
static void nap_us(long us) { struct timespec t = { us / 1000000L, (us % 1000000L) * 1000L }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/pthread.h"
#include "../lib/moqi_libc/include/time.h"
static long mq_open4(const char *n, long flags, long mode, void *attr) { return syscall4(186, (long)n, flags, mode, (long)attr); }
static long mq_send4(long q, const char *m) { return syscall5(188, q, (long)m, 2, 0, 0); }
static long mq_recv4(long q) {
    char b[16];
    return syscall5(189, q, (long)b, sizeof b, 0, 0) < 0 ? -1 : 0;
}
static long mq_notify2(long q, void *sev) { return syscall2(190, q, (long)sev); }
static long mq_close1(long q) { return close((int)q); }
static long mq_unlink1(const char *n) { return syscall1(187, (long)n); }
static long my_tid(void) { return syscall0(SYS_gettid); }
static void mask_usr1(int block) {
    unsigned long m = 1UL << (10 - 1);
    syscall4(SYS_sigprocmask, block ? 0 : 1, (long)&m, 0, 8);
}
static void nap_us(long us) { struct timespec t = { us / 1000000L, (us % 1000000L) * 1000L }; nanosleep(&t, 0); }
#endif

#define S_USR1 10
#define SIGEV_SIGNAL_K 0
#ifndef O_RDWR
#define O_RDWR 02
#endif
#ifndef O_CREAT
#define O_CREAT 0x40
#endif

/* x86_64 sigevent: sigev_value@0, sigev_signo@8, sigev_notify@12 (SIGEV_SIGNAL is 0), padded to 64 bytes. */
struct ksigev { long value; int signo, notify; char pad[48]; };
struct kattr { long flags, maxmsg, msgsize, curmsgs; };

static int failures;
static char msg[240];
static void check(int ok, const char *w) {
    print(ok ? "hello332:   ok   " : "hello332:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static long q;
static long reg(long d) {
    struct ksigev s;
    memset(&s, 0, sizeof s);
    s.notify = SIGEV_SIGNAL_K;
    s.signo = S_USR1;
    return mq_notify2(d, &s);
}
/* Is a registration standing? Probe with a registration of our own and take it back when it went through. */
static int registered(void) {
    long r = reg(q);
    if (r == 0) mq_notify2(q, 0);
    return r == -16;
}

static volatile long hits, got_tid, stop, thread_ready;
static void on_usr1(int s) { (void)s; got_tid = my_tid(); hits++; }
static int wait_hit(void) {
    for (int i = 0; i < 1000 && hits == 0; i++) nap_us(1000);
    return hits != 0;
}

static void *close_open(void *a) {
    (void)a;
    long o = mq_open4("/mq332", O_RDWR, 0, 0);
    mq_close1(o);
    return 0;
}
static void *reg_and_exit(void *a) { *(long *)a = reg(q); return 0; }
static void *reg_and_block(void *a) {
    mask_usr1(1);
    *(long *)a = reg(q);
    thread_ready = 1;
    while (!stop) nap_us(1000);
    return 0;
}

int main(void) {
    print("hello332: an mq_notify registration belongs to the process\n");
#ifdef HOST
    signal(SIGUSR1, on_usr1);
#else
    struct ksigaction sa = { on_usr1, 0, (void *)0, 0 };
    sigaction(S_USR1, &sa, (struct ksigaction *)0);
#endif
    struct kattr attr = { 0, 4, 16, 0 };
    mq_unlink1("/mq332");
    q = mq_open4("/mq332", O_RDWR | O_CREAT, 0600, &attr);
    check(q >= 0, "mq_open succeeds");

    /* A: closing any open of the queue, by the owner, removes the registration. */
    long r = reg(q);
    long o = mq_open4("/mq332", O_RDWR, 0, 0);
    long c = mq_close1(o);
    snprintf(msg, sizeof msg, "A: the owner closing another open of the queue removes the registration (reg %ld, close %ld, still %d)", r, c, registered());
    check(r == 0 && c == 0 && !registered(), msg);

    /* B: a child is another process, so its closes are not the owner's. */
    reg(q);
    long child = fork();
    if (child == 0) {
        mq_close1(q);
        long o2 = mq_open4("/mq332", O_RDWR, 0, 0);
        mq_close1(o2);
        _exit(0);
    }
    waitpid(child, 0, 0);
    snprintf(msg, sizeof msg, "B: a child closing the inherited descriptor and its own open leaves it (still %d)", registered());
    check(registered(), msg);
    mq_notify2(q, 0);

    /* C: a thread of the owner closing an open of the queue removes it. */
    reg(q);
    pthread_t th;
    pthread_create(&th, 0, close_open, 0);
    pthread_join(th, 0);
    snprintf(msg, sizeof msg, "C: a thread of the owner closing an open of the queue removes it (still %d)", registered());
    check(!registered(), msg);

    /* D: a thread registers and exits; the registration stands, and the message signals the process. */
    long tr = -99;
    pthread_create(&th, 0, reg_and_exit, &tr);
    pthread_join(th, 0);
    nap_us(20000);
    int still = registered();
    hits = 0;
    got_tid = 0;
    mq_send4(q, "d1");
    int hit = wait_hit();
    snprintf(msg, sizeof msg, "D: a thread's registration outlives it and the main thread takes the signal (reg %ld, still %d, hit %d, main %d)",
             tr, still, hit, got_tid == my_tid());
    check(tr == 0 && still && hit && got_tid == my_tid(), msg);
    mq_recv4(q);

    /* E: the registering thread blocks the signal, so another thread of the process takes it. */
    tr = -99;
    stop = 0;
    thread_ready = 0;
    pthread_create(&th, 0, reg_and_block, &tr);
    for (int i = 0; i < 1000 && !thread_ready; i++) nap_us(1000);
    hits = 0;
    got_tid = 0;
    mq_send4(q, "e1");
    hit = wait_hit();
    stop = 1;
    pthread_join(th, 0);
    snprintf(msg, sizeof msg, "E: the signal is process-directed: with the registrant blocking it the main thread takes it (reg %ld, hit %d, main %d)",
             tr, hit, got_tid == my_tid());
    check(tr == 0 && hit && got_tid == my_tid(), msg);
    mq_recv4(q);

    /* F: a child that registered and exited leaves nothing behind. */
    child = fork();
    if (child == 0) _exit(reg(q) == 0 ? 0 : 1);
    int st = 0;
    waitpid(child, &st, 0);
    snprintf(msg, sizeof msg, "F: a child that registered and exited leaves no registration (status 0x%x, still %d)", st, registered());
    check(st == 0 && !registered(), msg);

    mq_close1(q);
    mq_unlink1("/mq332");
    print(failures ? "hello332: FAIL\n" : "hello332: PASS\n");
    return failures ? 1 : 0;
}
