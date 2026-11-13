/* hello294: mq_notify registration rules.
 * Measured on the host (build with -DHOST): SIGEV_NONE registers, sends nothing, and is consumed by the first message;
 * SIGEV_SIGNAL with signal 0 also registers, sends nothing, and is consumed; a NULL notification removes the registration only for the process that made it
 * (another process's attempt returns 0 and leaves it in place, and that process may not replace it either, EBUSY); the same
 * process may remove it through a different descriptor; closing the descriptor the registration was made on removes it. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
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
static long mq_notify2(long q, void *sev) { return mq_notify((mqd_t)q, (const struct sigevent *)sev) < 0 ? -errno : 0; }
static long mq_unlink1(const char *n) { return mq_unlink(n) < 0 ? -errno : 0; }
static long stw(void *set, void *info, void *ts) {
    long r = syscall(SYS_rt_sigtimedwait, set, info, ts, 8);
    return r < 0 ? -errno : r;
}
static long mask(int how, unsigned long *set) {
    long r = syscall(SYS_rt_sigprocmask, how, set, 0, 8);
    return r < 0 ? -errno : r;
}
static long do_fork(void) { return fork(); }
static long do_wait(long pid) { int st = 0; return waitpid(pid, &st, 0) < 0 ? -errno : 0; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
static long mq_open4(const char *n, long flags, long mode, void *attr) { return syscall4(186, (long)n, flags, mode, (long)attr); }
static long mq_send4(long q, const char *m) { return syscall5(188, q, (long)m, 2, 0, 0); }
static long mq_recv4(long q) {
    char b[16];
    return syscall5(189, q, (long)b, sizeof b, 0, 0) < 0 ? -1 : 0;
}
static long mq_notify2(long q, void *sev) { return syscall2(190, q, (long)sev); }
static long mq_unlink1(const char *n) { return syscall1(187, (long)n); }
static long stw(void *set, void *info, void *ts) { return syscall4(221, (long)set, (long)info, (long)ts, 8); }
static long mask(int how, unsigned long *set) { return syscall4(SYS_sigprocmask, how, (long)set, 0, 8); }
static long do_fork(void) { return fork(); }
static long do_wait(long pid) { return waitpid(pid, 0, 0) < 0 ? -1 : 0; }
#endif

#define S_USR1 10
#define S_USR2 12
#define BLOCK 0
#define UNBLOCK 1
#define SIGEV_SIGNAL_K 0
#define SIGEV_NONE_K 1
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
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello294:   ok   " : "hello294:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long wait_sig(long ns) {
    unsigned long set = 1UL << (S_USR1 - 1);
    struct timespec ts = { ns / 1000000000L, ns % 1000000000L };
    int info[32];
    return stw(&set, info, &ts);
}

int main(void) {
    print("hello294: mq_notify accepts SIGEV_NONE and signal 0, and only the owner removes a registration\n");
    unsigned long usr1 = 1UL << (S_USR1 - 1);
    mask(BLOCK, &usr1);

    struct kattr attr = { 0, 4, 16, 0 };
    long q = mq_open4("/mq294", O_RDWR | O_CREAT, 0600, &attr);
    check(q >= 0, "mq_open succeeds");

    /* A: SIGEV_NONE is a real registration that sends nothing, and it is one-shot like any other. */
    struct ksigev sev;
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_NONE_K;
    long r = mq_notify2(q, &sev);
    check(r == 0, "A: mq_notify(SIGEV_NONE) succeeds");
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K;
    sev.signo = S_USR1;
    r = mq_notify2(q, &sev);
    snprintf(msg, sizeof msg, "A: while it stands, another mq_notify is EBUSY (%ld)", r);
    check(r == -16, msg);
    mq_send4(q, "a1");
    r = wait_sig(0);
    snprintf(msg, sizeof msg, "A: a message arriving under SIGEV_NONE delivers no signal (%ld)", r);
    check(r == -11, msg);
    mq_recv4(q);
    /* The arrival consumes the registration even though nothing was sent. */
    r = mq_notify2(q, &sev);
    snprintf(msg, sizeof msg, "A: and the arrival consumes the registration (%ld)", r);
    check(r == 0, msg);
    mq_notify2(q, 0);

    /* B: signal 0 registers, delivers nothing, and is consumed like any other. */
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K;
    sev.signo = 0;
    r = mq_notify2(q, &sev);
    snprintf(msg, sizeof msg, "B: SIGEV_SIGNAL with signal 0 registers (%ld)", r);
    check(r == 0, msg);
    mq_send4(q, "b1");
    r = wait_sig(0);
    snprintf(msg, sizeof msg, "B: but the arrival delivers no signal (%ld)", r);
    check(r == -11, msg);
    mq_recv4(q);
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K;
    sev.signo = S_USR1;
    r = mq_notify2(q, &sev);
    snprintf(msg, sizeof msg, "B: and the arrival consumes the registration (%ld)", r);
    check(r == 0, msg);
    mq_notify2(q, 0);

    /* C: another process can neither remove nor replace the registration. */
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K;
    sev.signo = S_USR1;
    mq_notify2(q, &sev);
    long child = do_fork();
    if (child == 0) {
        long q2 = mq_open4("/mq294", O_RDWR, 0, 0);
        long u = mq_notify2(q2, 0);
        memset(&sev, 0, sizeof sev);
        sev.notify = SIGEV_SIGNAL_K;
        sev.signo = S_USR2;
        long v = mq_notify2(q2, &sev);
        /* Report through the exit status: low byte is the unregister result's sign, next the replace result. */
        _exit((u == 0 ? 0 : 1) | ((v == -16 ? 0 : 2)));
    }
    int st = 0;
    waitpid(child, &st, 0);
    int code = (st >> 8) & 0xff;
    snprintf(msg, sizeof msg, "C: another process's mq_notify(NULL) returns 0 and its replacement is EBUSY (status 0x%x)", st);
    check(code == 0, msg);
    mq_send4(q, "c1");
    r = wait_sig(1000000000L);
    snprintf(msg, sizeof msg, "C: and the original registration still delivers (%ld)", r);
    check(r == S_USR1, msg);
    mq_recv4(q);

    /* D: the same process removes the registration through a different descriptor. */
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K;
    sev.signo = S_USR1;
    mq_notify2(q, &sev);
    long q3 = mq_open4("/mq294", O_RDWR, 0, 0);
    r = mq_notify2(q3, 0);
    check(r == 0, "D: the same process removes the registration through another descriptor");
    mq_send4(q, "d1");
    r = wait_sig(0);
    snprintf(msg, sizeof msg, "D: so the next message delivers nothing (%ld)", r);
    check(r == -11, msg);
    mq_recv4(q);

    /* E: closing the descriptor the registration was made on removes it. */
    memset(&sev, 0, sizeof sev);
    sev.notify = SIGEV_SIGNAL_K;
    sev.signo = S_USR1;
    mq_notify2(q3, &sev);
    close((int)q3);
    mq_send4(q, "e1");
    r = wait_sig(0);
    snprintf(msg, sizeof msg, "E: closing the registering descriptor removes the registration (%ld)", r);
    check(r == -11, msg);
    mq_recv4(q);

    close((int)q);
    mq_unlink1("/mq294");
    mask(UNBLOCK, &usr1);
    print(failures ? "hello294: FAIL\n" : "hello294: PASS\n");
    return failures ? 1 : 0;
}
