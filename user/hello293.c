/* hello293: mq_notify's signal carries SI_MESGQ, the sender's pid and uid, and the registered sigev_value.
 * Measured on the host (build with -DHOST): a message arriving on an empty queue delivers one SIGUSR1 with si_code SI_MESGQ (-3),
 * si_pid and si_uid of the sender, and si_value the sigev_value registered with mq_notify. A second message without another
 * mq_notify delivers nothing. Re-arming while the queue still holds a message delivers nothing until the queue is drained and a
 * message arrives on it empty again. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long mq_open4(const char *n, long flags, long mode, void *attr) {
    mqd_t q = mq_open(n, (int)flags, (mode_t)mode, (struct mq_attr *)attr);
    return q < 0 ? -errno : q;
}
static long mq_send4(long q, const char *m, long len, long prio) {
    return mq_send((mqd_t)q, m, (size_t)len, (unsigned)prio) < 0 ? -errno : 0;
}
static long mq_recv4(long q, char *b, long len) {
    ssize_t r = mq_receive((mqd_t)q, b, (size_t)len, (unsigned *)0);
    return r < 0 ? -errno : r;
}
static long mq_notify2(long q, void *sev) {
    return mq_notify((mqd_t)q, (const struct sigevent *)sev) < 0 ? -errno : 0;
}
static long mq_unlink1(const char *n) { return mq_unlink(n) < 0 ? -errno : 0; }
static long stw(void *set, void *info, void *ts) {
    long r = syscall(SYS_rt_sigtimedwait, set, info, ts, 8);
    return r < 0 ? -errno : r;
}
static long mask(int how, unsigned long *set) {
    long r = syscall(SYS_rt_sigprocmask, how, set, 0, 8);
    return r < 0 ? -errno : r;
}
static long my_pid(void) { return getpid(); }
static long my_uid(void) { return getuid(); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"
static long mq_open4(const char *n, long flags, long mode, void *attr) { return syscall4(186, (long)n, flags, mode, (long)attr); }
static long mq_send4(long q, const char *m, long len, long prio) { return syscall5(188, q, (long)m, len, prio, 0); }
static long mq_recv4(long q, char *b, long len) { return syscall5(189, q, (long)b, len, 0, 0); }
static long mq_notify2(long q, void *sev) { return syscall2(190, q, (long)sev); }
static long mq_unlink1(const char *n) { return syscall1(187, (long)n); }
static long stw(void *set, void *info, void *ts) { return syscall4(221, (long)set, (long)info, (long)ts, 8); }
static long mask(int how, unsigned long *set) { return syscall4(SYS_sigprocmask, how, (long)set, 0, 8); }
static long my_pid(void) { return syscall0(SYS_getpid); }
static long my_uid(void) { return syscall0(SYS_getuid); }
#endif

#define S_USR1 10
#define BLOCK 0
#define UNBLOCK 1
#define SI_MESGQ_CODE (-3)
#ifndef O_RDWR
#define O_RDWR 02
#endif
#ifndef O_CREAT
#define O_CREAT 0x40
#endif

/* x86_64 sigevent: sigev_value@0, sigev_signo@8, sigev_notify@12 (SIGEV_SIGNAL is 0), padded to 64 bytes. */
struct ksigev { long value; int signo, notify; char pad[48]; };
/* Linux struct mq_attr: four 8-byte longs. */
struct kattr { long flags, maxmsg, msgsize, curmsgs; };
/* siginfo_t: signo@0 errno@4 code@8, 4 bytes of padding, then si_pid@16 si_uid@20 si_value@24. */
struct sinfo { int signo, err, code, pad; int pid, uid; long value; char rest[96]; };

static int failures;
static char msg[240];
static void check(int ok, const char *w) {
    print(ok ? "hello293:   ok   " : "hello293:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long wait_for(int sig, struct sinfo *si, long ns) {
    unsigned long set = 1UL << (sig - 1);
    struct timespec ts = { ns / 1000000000L, ns % 1000000000L };
    memset(si, 0, sizeof *si);
    return stw(&set, si, &ts);
}

int main(void) {
    print("hello293: mq_notify's signal carries SI_MESGQ, the sender's pid and uid, and the value\n");
    unsigned long usr1 = 1UL << (S_USR1 - 1);
    mask(BLOCK, &usr1);

    struct kattr attr = { 0, 4, 16, 0 };
    long q = mq_open4("/mq293", O_RDWR | O_CREAT, 0600, &attr);
    check(q >= 0, "mq_open succeeds");

    struct ksigev sev;
    memset(&sev, 0, sizeof sev);
    sev.signo = S_USR1;
    sev.value = 0x55aaL;
    long r = mq_notify2(q, &sev);
    check(r == 0, "mq_notify(SIGEV_SIGNAL SIGUSR1) succeeds");

    /* A: a message on an empty queue delivers one signal. */
    r = mq_send4(q, "hi", 2, 0);
    check(r == 0, "A: mq_send on the empty queue succeeds");
    struct sinfo si;
    r = wait_for(S_USR1, &si, 1000000000L);
    long pid = my_pid();
    long uid = my_uid();
    snprintf(msg, sizeof msg,
             "A: the signal has SI_MESGQ, the sender's pid and uid, and the sigev_value (%ld, code %d, pid %d/%ld, uid %d/%ld, value 0x%lx)",
             r, si.code, si.pid, pid, si.uid, uid, si.value);
    check(r == S_USR1 && si.code == SI_MESGQ_CODE && si.pid == pid && si.uid == uid && si.value == 0x55aaL, msg);

    /* B: one-shot. A second message without another mq_notify delivers nothing. */
    r = mq_send4(q, "ho", 2, 0);
    check(r == 0, "B: a second mq_send succeeds");
    r = wait_for(S_USR1, &si, 0);
    snprintf(msg, sizeof msg, "B: without another mq_notify no signal is delivered (%ld)", r);
    check(r == -11, msg);

    /* C: re-arming while the queue still holds messages delivers nothing until it drains and fills again. */
    r = mq_notify2(q, &sev);
    check(r == 0, "C: mq_notify while the queue is not empty succeeds");
    r = wait_for(S_USR1, &si, 0);
    snprintf(msg, sizeof msg, "C: re-arming a non-empty queue delivers nothing by itself (%ld)", r);
    check(r == -11, msg);
    char buf[16];
    r = mq_recv4(q, buf, sizeof buf);
    check(r == 2, "C: the first message is received");
    r = mq_recv4(q, buf, sizeof buf);
    check(r == 2, "C: the queue is drained");
    r = wait_for(S_USR1, &si, 0);
    snprintf(msg, sizeof msg, "C: draining delivers nothing (%ld)", r);
    check(r == -11, msg);
    r = mq_send4(q, "ha", 2, 0);
    check(r == 0, "C: a message arriving on the empty queue succeeds");
    r = wait_for(S_USR1, &si, 1000000000L);
    snprintf(msg, sizeof msg, "C: and that message delivers the signal again (%ld, code %d, value 0x%lx)", r, si.code, si.value);
    check(r == S_USR1 && si.code == SI_MESGQ_CODE && si.value == 0x55aaL, msg);

    close((int)q);
    mq_unlink1("/mq293");
    mask(UNBLOCK, &usr1);
    print(failures ? "hello293: FAIL\n" : "hello293: PASS\n");
    return failures ? 1 : 0;
}
