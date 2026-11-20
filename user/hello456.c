/* hello456: a child's exit signal after its parent execs (Linux do_notify_parent: when tsk->parent_exec_id differs from the parent's
 * self_exec_id the signal becomes SIGCHLD; copy_process sets parent_exec_id from the parent's self_exec_id, begin_new_exec bumps it).
 * Measured on the host (build with -DHOST):
 *   A. a clone(SIGUSR1) child that outlives its parent's execve: the exec'd parent gets SIGCHLD, not SIGUSR1, when it exits; the
 *      child is still a __WCLONE child (its exit_signal is unchanged), so waitpid(__WCLONE) reaps it with status 0x500 and a plain
 *      waitpid is ECHILD;
 *   B. the exec'd parent's own new clone(SIGUSR1) child still sends SIGUSR1. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long clone_(long fl) { return rc(syscall(SYS_clone, fl, 0, 0, 0, 0)); }
static long wait_(long pid, int *st, int opt) { return rc(waitpid((pid_t)pid, st, opt)); }
static void exit_(int c) { _exit(c); }
static void nap(int ms) { struct timespec t = { 0, ms * 1000000L }; nanosleep(&t, 0); }
static long sigact(int sig, void *h) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = (void (*)(int))h;
    return rc(sigaction(sig, &sa, 0));
}
static long reexec(const char *self, const char *arg) {
    char *argv[3] = { (char *)self, (char *)arg, 0 };
    char *envp[1] = { 0 };
    execve(self, argv, envp);
    return -errno;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
static long clone_(long fl) { return syscall5(243, fl, 0, 0, 0, 0); }
static long wait_(long pid, int *st, int opt) { return syscall3(SYS_waitpid, pid, (long)st, opt); }
static void exit_(int c) { syscall1(SYS_exit, c); for (;;) {} }
static void nap(int ms) { long t[2] = { 0, ms * 1000000L }; syscall2(35, (long)t, 0); }
static long sigact(int sig, void *h) {
    struct ksigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.handler = (void (*)(int))h;
    return sigaction(sig, &sa, 0);
}
static long reexec(const char *self, const char *arg) {
    const char *argv[3] = { self, arg, 0 };
    const char *envp[1] = { 0 };
    return syscall3(SYS_execve, (long)self, (long)argv, (long)envp);
}
#endif
#define SIGUSR1_ 10
#define SIGCHLD_ 17
#define WCLONE_ 0x80000000
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello456:   ok   " : "hello456:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static volatile int n_usr1, n_chld;
static void on_usr1(int s) { (void)s; n_usr1++; }
static void on_chld(int s) { (void)s; n_chld++; }
/* Wait up to 2 s for one of the counters to move. */
static void wait_signal(void) {
    for (int i = 0; i < 100 && n_usr1 == 0 && n_chld == 0; i++) nap(20);
}
static int parse(const char *s) {
    int v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return v;
}
int main(int argc, char **argv) {
    if (argc > 1 && argv[1][0] >= '0' && argv[1][0] <= '9') {
        /* The parent after its execve: argv[1] is the pid of the SIGUSR1 child it made before. */
        int child = parse(argv[1]);
        sigact(SIGUSR1_, (void *)on_usr1);
        sigact(SIGCHLD_, (void *)on_chld);
        wait_signal();
        nap(50);
        int st = 0;
        long plain = wait_(child, &st, 1);
        long r = wait_(child, &st, (int)WCLONE_);
        snprintf(msg, sizeof msg, "A: after the parent's exec: SIGCHLD %d SIGUSR1 %d; plain waitpid %ld; __WCLONE reaps %d status 0x%x (1 0 -10 1 0x500)", n_chld, n_usr1,
                 plain, r == child, st);
        check(n_chld == 1 && n_usr1 == 0 && plain == -10 && r == child && st == 0x500, msg);

        n_usr1 = n_chld = 0;
        long p = clone_(SIGUSR1_);
        if (p == 0) exit_(6);
        wait_signal();
        nap(50);
        st = 0;
        long r2 = wait_(p, &st, (int)WCLONE_);
        snprintf(msg, sizeof msg, "B: a child made after the exec: SIGUSR1 %d SIGCHLD %d; __WCLONE reaps %d status 0x%x (1 0 1 0x600)", n_usr1, n_chld, r2 == p, st);
        check(n_usr1 == 1 && n_chld == 0 && r2 == p && st == 0x600, msg);
        print(failures ? "hello456: FAIL\n" : "hello456: PASS\n");
        return failures ? 1 : 0;
    }
    print("hello456: a clone child's exit signal after its parent execs\n");
    long c = clone_(SIGUSR1_);
    if (c == 0) {
        nap(400);
        exit_(5);
    }
    if (c < 0) {
        snprintf(msg, sizeof msg, "A: clone(SIGUSR1) %ld", c);
        check(0, msg);
        print("hello456: FAIL\n");
        return 1;
    }
    char num[24];
    snprintf(num, sizeof num, "%ld", c);
    long e = reexec(argv[0], num);
    snprintf(msg, sizeof msg, "A: execve itself %ld", e);
    check(0, msg);
    print("hello456: FAIL\n");
    return 1;
}
