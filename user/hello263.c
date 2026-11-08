/* hello263: kill(0, sig) and kill(-1, sig). Measured on Linux (gcc probes inside a private pid namespace): kill(0, sig) signals every process of the
 * caller's own process group INCLUDING the caller, and none outside it; kill(0, 0) is 0; an out-of-range number is EINVAL; kill(-1, sig) signals
 * every process the caller may signal EXCEPT the caller itself (and init); a group or pid that does not exist is ESRCH. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"

#define SIGUSR1_ 10
#define SIGUSR2_ 12
#define WNOHANG_ 1

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello263:   ok   " : "hello263:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void pause_ms(int ms) {
    struct timespec ts = { 0, (long)ms * 1000000L };
    nanosleep(&ts, (struct timespec *)0);
}

static volatile int got_signal;
static void on_signal(int s) { got_signal = s; }

/* A child in process group `pgid` (0 = its own group) with default dispositions, blocked in read on a pipe nobody writes. */
static long member(long pgid) {
    int p[2];
    pipe(p);
    long k = fork();
    if (k == 0) {
        setpgid(0, pgid);
        signal(SIGUSR1_, SIG_DFL);
        signal(SIGUSR2_, SIG_DFL);
        char c;
        read(p[0], &c, 1);
        _exit(0);
    }
    setpgid(k, pgid ? pgid : k);
    return k;
}

/* The signal that ended `pid` within about 0.6 s, 0 for a normal exit, -1 when it is still there. */
static int ended_by(long pid) {
    int st = 0;
    for (int i = 0; i < 60; i++) {
        long w = waitpid(pid, &st, WNOHANG_);
        if (w == pid) return st & 0x7f;
        pause_ms(10);
    }
    return -1;
}

static void settle(long pid) {
    kill(pid, SIGKILL);
    int st;
    waitpid(pid, &st, 0);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello263: kill(0, sig) and kill(-1, sig)\n");
    char what[240];

    struct ksigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.handler = on_signal;
    sigaction(SIGUSR1_, &sa, (struct ksigaction *)0);
    sigaction(SIGUSR2_, &sa, (struct ksigaction *)0);
    setpgid(0, 0);

    long other = member(0);
    long same = member(getpgid(0));
    pause_ms(100);
    got_signal = 0;
    long r = kill(0, SIGUSR1_);
    pause_ms(100);
    snprintf(what, sizeof what, "A: kill(0, sig) returns 0 and signals the caller too (rc %ld, handler saw %d)", r, (int)got_signal);
    check(r == 0 && got_signal == SIGUSR1_, what);
    int es = ended_by(same);
    snprintf(what, sizeof what, "A: and a member of the caller's group (ended by %d)", es);
    check(es == SIGUSR1_, what);
    int eo = ended_by(other);
    snprintf(what, sizeof what, "A: but not a process in another group (ended by %d, -1 = still there)", eo);
    check(eo == -1, what);

    check(kill(0, 0) == 0, "B: kill(0, 0) is 0");
    r = kill(0, 130);
    snprintf(what, sizeof what, "B: kill(0, 130) is EINVAL (rc %ld)", r);
    check(r == -EINVAL, what);
    r = kill(-999999, SIGTERM);
    snprintf(what, sizeof what, "B: a group that does not exist is ESRCH (rc %ld)", r);
    check(r == -ESRCH, what);
    r = kill(999999, SIGTERM);
    snprintf(what, sizeof what, "B: a pid that does not exist is ESRCH (rc %ld)", r);
    check(r == -ESRCH, what);

    long d = member(0), e = member(0);
    pause_ms(100);
    got_signal = 0;
    r = kill(-1, SIGUSR2_);
    pause_ms(100);
    snprintf(what, sizeof what, "C: kill(-1, sig) returns 0 (rc %ld)", r);
    check(r == 0, what);
    int ed = ended_by(d), ee = ended_by(e);
    snprintf(what, sizeof what, "C: it signals every other process the caller may signal (ended by %d and %d)", ed, ee);
    check(ed == SIGUSR2_ && ee == SIGUSR2_, what);
    snprintf(what, sizeof what, "C: but not the caller itself (handler saw %d)", (int)got_signal);
    check(got_signal == 0, what);

    settle(other);

    print(failures == 0 ? "hello263: PASS\n" : "hello263: FAIL\n");
    return failures;
}
