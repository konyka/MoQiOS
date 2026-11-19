/* hello450: the exit signal of a clone() child (Linux copy_process exit_signal = flags & CSIGNAL, do_notify_parent, eligible_child
 * and __WCLONE / __WALL, de_thread resetting exit_signal on exec). Measured on the host (build with -DHOST):
 *   A. clone(SIGUSR1): the parent gets SIGUSR1 when the child exits (si_code CLD_EXITED, si_pid the child, si_status 3); a plain
 *      waitpid of it, or of any child, is ECHILD; waitpid(__WCLONE) reaps it with status 0x300;
 *   B. clone(0): no signal at all; plain waitpid ECHILD, waitpid(__WALL) reaps it;
 *   C. clone(SIGCHLD): SIGCHLD as for fork; waitpid(__WCLONE) ECHILD, plain waitpid reaps it;
 *   D. clone(65) is EINVAL; clone(64) is a valid exit signal;
 *   E. waitid(P_PID) without __WCLONE is ECHILD for a SIGUSR1 child; with __WCLONE it reports CLD_EXITED, status 7;
 *   F. with a SIGCHLD child and a SIGUSR1 child both dead, waitpid(-1, __WCLONE) takes the SIGUSR1 one and a plain waitpid(-1) the
 *      other;
 *   G. a stopped SIGUSR1 child: WUNTRACED alone is ECHILD, WUNTRACED|__WCLONE reports the stop (0x137f); killed, __WCLONE reaps it;
 *   H. with SIGCHLD ignored a SIGUSR1 child is not reaped automatically: it still sends SIGUSR1 and __WCLONE gets its status;
 *   I. a SIGUSR1 child that execs becomes an ordinary child (exit signal SIGCHLD): a plain waitpid reaps it. */
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
static long rc(long r) { return r < 0 ? -errno : r; }
static long clone_(long fl) { return rc(syscall(SYS_clone, fl, 0, 0, 0, 0)); }
static long wait_(long pid, int *st, int opt) { return rc(waitpid((pid_t)pid, st, opt)); }
static long waitid_(int type, long id, void *info, int opt) { return rc(syscall(SYS_waitid, type, id, info, opt, 0)); }
static void exit_(int c) { _exit(c); }
static long kill_(long p, int s) { return rc(kill((pid_t)p, s)); }
static void nap(int ms) { struct timespec t = { 0, ms * 1000000L }; nanosleep(&t, 0); }
static long sigact(int sig, void *h, unsigned long flags) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = (void (*)(int))h;
    sa.sa_flags = (int)flags;
    return rc(sigaction(sig, &sa, 0));
}
static long exec_true(void) {
    char *argv[] = { "true", 0 };
    execv("/bin/true", argv);
    return -errno;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
static long clone_(long fl) { return syscall5(243, fl, 0, 0, 0, 0); }
static long wait_(long pid, int *st, int opt) { return syscall3(SYS_waitpid, pid, (long)st, opt); }
static long waitid_(int type, long id, void *info, int opt) { return syscall5(SYS_waitid, type, id, (long)info, opt, 0); }
static void exit_(int c) { syscall1(SYS_exit, c); for (;;) {} }
static long kill_(long p, int s) { return syscall2(SYS_kill, p, s); }
static void nap(int ms) { long t[2] = { 0, ms * 1000000L }; syscall2(35, (long)t, 0); }
static long sigact(int sig, void *h, unsigned long flags) {
    struct ksigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.handler = (void (*)(int))h;
    sa.flags = flags;
    return sigaction(sig, &sa, 0);
}
static long exec_true(void) {
    const char *argv[2] = { "hello116", 0 };
    return syscall3(SYS_execve, (long)"hello116", (long)argv, 0);
}
#define SA_SIGINFO 4
#endif
#define WCLONE_ 0x80000000
#define WALL_ 0x40000000
#define WUNTRACED_ 2
#define WNOHANG_ 1
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello450:   ok   " : "hello450:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static volatile int last_sig, last_code, last_pid, last_status, n_usr1, n_chld;
static void on_sig(int s, void *si, void *u) {
    (void)u;
    const int *w = (const int *)si;
    last_sig = s;
    last_code = w[2];
    last_pid = w[4];
    last_status = w[6];
    if (s == 10) n_usr1++;
    if (s == 17) n_chld++;
}
static void settle(void) { nap(60); }
int main(void) {
    print("hello450: the exit signal of a clone() child, __WCLONE and __WALL\n");
    sigact(10, (void *)on_sig, SA_SIGINFO);
    sigact(17, (void *)on_sig, SA_SIGINFO);
    sigact(64, (void *)on_sig, SA_SIGINFO);
    int st = 0;

    long p = clone_(10);
    if (p == 0) exit_(3);
    settle();
    long a1 = wait_(p, &st, WNOHANG_), a2 = wait_(-1, &st, WNOHANG_);
    st = 0;
    long a3 = wait_(p, &st, WCLONE_);
    snprintf(msg, sizeof msg, "A: clone(SIGUSR1) %d; signal %d code %d pid %d status %d; waitpid %ld, any %ld; __WCLONE %d status 0x%x (10 1 1 3; -10 -10; 1 0x300)",
             p > 0, last_sig, last_code, last_pid == p, last_status, a1, a2, a3 == p, st);
    check(p > 0 && last_sig == 10 && last_code == 1 && last_pid == p && last_status == 3 && a1 == -10 && a2 == -10 && a3 == p && st == 0x300, msg);

    last_sig = 0;
    p = clone_(0);
    if (p == 0) exit_(4);
    settle();
    long b1 = wait_(p, &st, 0);
    st = 0;
    long b2 = wait_(p, &st, WALL_);
    snprintf(msg, sizeof msg, "B: clone(0) %d; signal %d; waitpid %ld; __WALL %d status 0x%x (1 0; -10; 1 0x400)", p > 0, last_sig, b1, b2 == p, st);
    check(p > 0 && last_sig == 0 && b1 == -10 && b2 == p && st == 0x400, msg);

    p = clone_(17);
    if (p == 0) exit_(5);
    settle();
    long c1 = wait_(p, &st, WCLONE_);
    st = 0;
    long c2 = wait_(p, &st, 0);
    snprintf(msg, sizeof msg, "C: clone(SIGCHLD) %d; signal %d; __WCLONE %ld; waitpid %d status 0x%x (1 17; -10; 1 0x500)", p > 0, last_sig, c1, c2 == p, st);
    check(p > 0 && last_sig == 17 && c1 == -10 && c2 == p && st == 0x500, msg);

    long d1 = clone_(65);
    if (d1 == 0) exit_(6);
    last_sig = 0;
    long d2 = clone_(64);
    if (d2 == 0) exit_(6);
    settle();
    long d3 = d2 > 0 ? wait_(d2, &st, WALL_) : -1;
    snprintf(msg, sizeof msg, "D: clone(65) %ld; clone(64) %d, signal %d, reaped %d (-22; 1 64 1)", d1, d2 > 0, last_sig, d3 == d2);
    check(d1 == -22 && d2 > 0 && last_sig == 64 && d3 == d2, msg);

    p = clone_(10);
    if (p == 0) exit_(7);
    settle();
    int info[32];
    memset(info, 0, sizeof info);
    long e1 = waitid_(1, p, info, 4 | WNOHANG_);
    memset(info, 0, sizeof info);
    long e2 = waitid_(1, p, info, 4 | WCLONE_);
    snprintf(msg, sizeof msg, "E: waitid %ld; with __WCLONE %ld pid %d code %d status %d (-10; 0 1 1 7)", e1, e2, info[4] == p, info[2], info[6]);
    check(e1 == -10 && e2 == 0 && info[4] == p && info[2] == 1 && info[6] == 7, msg);

    long fa = clone_(17);
    if (fa == 0) exit_(8);
    long fb = clone_(10);
    if (fb == 0) exit_(9);
    settle();
    int s1 = 0;
    long f1 = wait_(-1, &s1, WCLONE_);
    st = 0;
    long f2 = wait_(-1, &st, 0);
    snprintf(msg, sizeof msg, "F: any child with __WCLONE takes the SIGUSR1 one %d (0x%x), a plain wait the other %d (0x%x) (1 0x900 1 0x800)", f1 == fb, s1, f2 == fa, st);
    check(f1 == fb && s1 == 0x900 && f2 == fa && st == 0x800, msg);

    p = clone_(10);
    if (p == 0) {
        for (;;) nap(1000);
    }
    settle();
    kill_(p, 19);
    settle();
    long g1 = wait_(p, &st, WUNTRACED_ | WNOHANG_);
    st = 0;
    long g2 = wait_(p, &st, WUNTRACED_ | WCLONE_);
    int gs = st;
    kill_(p, 9);
    st = 0;
    long g3 = wait_(p, &st, WCLONE_);
    snprintf(msg, sizeof msg, "G: stopped: WUNTRACED %ld; with __WCLONE %d status 0x%x; killed, __WCLONE %d status 0x%x (-10; 1 0x137f; 1 0x9)", g1, g2 == p, gs, g3 == p, st);
    check(g1 == -10 && g2 == p && gs == 0x137f && g3 == p && st == 0x9, msg);

    sigact(17, (void *)1, 0);
    n_usr1 = 0;
    p = clone_(10);
    if (p == 0) exit_(3);
    settle();
    st = 0;
    long h1 = wait_(p, &st, WCLONE_);
    snprintf(msg, sizeof msg, "H: SIGCHLD ignored: SIGUSR1 %d, __WCLONE %d status 0x%x (1 1 0x300)", n_usr1, h1 == p, st);
    check(n_usr1 == 1 && h1 == p && st == 0x300, msg);
    sigact(17, (void *)on_sig, SA_SIGINFO);

    n_usr1 = 0;
    p = clone_(10);
    if (p == 0) {
        exec_true();
        exit_(99);
    }
    for (int i = 0; i < 20; i++) settle();
    st = 0;
    long i1 = wait_(p, &st, 0);
    snprintf(msg, sizeof msg, "I: a SIGUSR1 child that execs: waitpid %d, exited %d, SIGUSR1 %d (1 1 0)", i1 == p, (st & 0x7f) == 0, n_usr1);
    check(i1 == p && (st & 0x7f) == 0 && n_usr1 == 0, msg);

    print(failures ? "hello450: FAIL\n" : "hello450: PASS\n");
    return failures ? 1 : 0;
}
