/* test_signal_abi.c — signal.h: signal, raise, abort, the sigset_t functions and sigprocmask (include/signal.h, src/signal.c).
 *
 * signal.c is compiled under other names (see run_tests.sh) so it cannot collide with the host's, and the system calls are a
 * recording stub (moqi_test_syscall6). The expectations are what glibc does for the same calls, measured on glibc 2.43.
 */
#include <errno.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"
#include "../include/signal.h"

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

/* ---- the system call stub: every call logged, the replies scripted ------------------------------------------------------ */

#define MAXCALLS 16
static int ncalls;
static long c_nr[MAXCALLS], c_a1[MAXCALLS], c_a2[MAXCALLS], c_a3[MAXCALLS], c_a4[MAXCALLS];
static unsigned long c_mask[MAXCALLS];      /* the 8 bytes at a2 for sigprocmask */
static unsigned long c_act_handler[MAXCALLS], c_act_flags[MAXCALLS], c_act_restorer[MAXCALLS], c_act_mask[MAXCALLS];

static long tid_reply = 4242;
static long tkill_reply;
static long sigaction_reply;
static unsigned long old_handler_reply;     /* what sigaction writes as the old handler */
static long sigprocmask_reply;
static long susp_reply;
static unsigned long mask_reply = 0x5555;   /* what a read of the mask returns */

static jmp_buf out;
static int exit_status = -1;
static int die_at_tkill;                    /* >0: the Nth tkill ends the "process" (as the default action of SIGABRT does) */
static int tkill_count;

void moqi__exit(int code) {
    exit_status = code;
    longjmp(out, 1);
}

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a5; (void)a6;
    int i = ncalls < MAXCALLS ? ncalls : MAXCALLS - 1;
    ncalls++;
    c_nr[i] = nr; c_a1[i] = a1; c_a2[i] = a2; c_a3[i] = a3; c_a4[i] = a4;
    if (nr == SYS_sigprocmask) {
        if (a2 > 4096) c_mask[i] = *(unsigned long *)a2;
        if (a3 > 4096 && sigprocmask_reply == 0) *(unsigned long *)a3 = mask_reply;
        return sigprocmask_reply;
    }
    if (nr == SYS_sigaction) {
        if (a2) {
            const unsigned long *w = (const unsigned long *)a2;
            c_act_handler[i] = w[0]; c_act_flags[i] = w[1]; c_act_restorer[i] = w[2]; c_act_mask[i] = w[3];
        }
        if (a3 && sigaction_reply == 0) {
            unsigned long *o = (unsigned long *)a3;
            o[0] = old_handler_reply; o[1] = 0; o[2] = 0; o[3] = 0;
        }
        return sigaction_reply;
    }
    if (nr == SYS_sigpending || nr == SYS_sigsuspend) return susp_reply;
    if (nr == SYS_gettid) return tid_reply;
    if (nr == SYS_tkill) {
        tkill_count++;
        if (die_at_tkill && tkill_count == die_at_tkill) longjmp(out, 2);
        return tkill_reply;
    }
    return -38;
}

static void reset(void) {
    ncalls = 0;
    tkill_reply = 0; sigaction_reply = 0; old_handler_reply = 0; sigprocmask_reply = 0; susp_reply = 0; mask_reply = 0x5555;
    die_at_tkill = 0; tkill_count = 0; exit_status = -1; errno_slot = 0;
}

static void handler_a(int s) { (void)s; }

int main(void) {
    /* The numbers and layouts are Linux x86-64's, as glibc has them. */
    CHECK(SIGHUP == 1 && SIGINT == 2 && SIGQUIT == 3 && SIGILL == 4 && SIGTRAP == 5 && SIGABRT == 6 && SIGBUS == 7);
    CHECK(SIGFPE == 8 && SIGKILL == 9 && SIGUSR1 == 10 && SIGSEGV == 11 && SIGUSR2 == 12 && SIGPIPE == 13 && SIGALRM == 14);
    CHECK(SIGTERM == 15 && SIGSTKFLT == 16 && SIGCHLD == 17 && SIGCONT == 18 && SIGSTOP == 19 && SIGTSTP == 20);
    CHECK(SIGTTIN == 21 && SIGTTOU == 22 && SIGURG == 23 && SIGXCPU == 24 && SIGXFSZ == 25 && SIGVTALRM == 26);
    CHECK(SIGPROF == 27 && SIGWINCH == 28 && SIGIO == 29 && SIGPWR == 30 && SIGSYS == 31 && SIGRTMIN == 34 && SIGRTMAX == 64);
    CHECK(NSIG == 65 && SIGIOT == SIGABRT && SIGPOLL == SIGIO);
    CHECK(SIG_DFL == (sighandler_t)0 && SIG_IGN == (sighandler_t)1 && SIG_ERR == (sighandler_t)-1);
    CHECK(SIG_BLOCK == 0 && SIG_UNBLOCK == 1 && SIG_SETMASK == 2);
    CHECK(sizeof(sigset_t) == 128 && sizeof(sig_atomic_t) == 4);
    CHECK(SYS_tkill == 223 && SYS_gettid == 497 && SYS_sigprocmask == 14 && SYS_sigaction == 13);

    /* ---- the set functions, no system calls ---- */
    sigset_t s;
    memset(&s, 0xaa, sizeof s);
    CHECK(sigemptyset(&s) == 0 && s.sig[0] == 0);
    CHECK(s.sig[1] == 0xaaaaaaaaaaaaaaaaUL); /* only the first word is written, as glibc's */
    CHECK(sigfillset(&s) == 0 && s.sig[0] == 0xfffffffe7fffffffUL);
    CHECK(sigismember(&s, SIGKILL) == 1 && sigismember(&s, SIGSTOP) == 1 && sigismember(&s, 1) == 1 && sigismember(&s, 64) == 1);
    CHECK(sigismember(&s, 32) == 0 && sigismember(&s, 33) == 0 && sigismember(&s, 31) == 1 && sigismember(&s, 34) == 1);
    sigemptyset(&s);
    CHECK(sigismember(&s, SIGUSR1) == 0);
    CHECK(sigaddset(&s, SIGUSR1) == 0 && sigismember(&s, SIGUSR1) == 1 && sigismember(&s, SIGUSR2) == 0);
    CHECK(s.sig[0] == 1UL << 9);
    CHECK(sigdelset(&s, SIGUSR1) == 0 && sigismember(&s, SIGUSR1) == 0 && s.sig[0] == 0);
    sigaddset(&s, 1); sigaddset(&s, 64);
    CHECK(s.sig[0] == 0x8000000000000001UL);
    CHECK(sigaddset(&s, SIGKILL) == 0 && sigaddset(&s, SIGSTOP) == 0); /* sets may hold them */
    sigemptyset(&s);
    static const int badsigs[] = { 0, -1, 65, 100, -100000, 2147483647 };
    for (unsigned i = 0; i < sizeof badsigs / sizeof badsigs[0]; i++) {
        errno_slot = 0; CHECK(sigaddset(&s, badsigs[i]) == -1 && errno_slot == EINVAL);
        errno_slot = 0; CHECK(sigdelset(&s, badsigs[i]) == -1 && errno_slot == EINVAL);
        errno_slot = 0; CHECK(sigismember(&s, badsigs[i]) == -1 && errno_slot == EINVAL);
    }
    errno_slot = 0; CHECK(sigaddset(&s, 32) == -1 && errno_slot == EINVAL);
    errno_slot = 0; CHECK(sigaddset(&s, 33) == -1 && errno_slot == EINVAL);
    errno_slot = 0; CHECK(sigdelset(&s, 32) == -1 && errno_slot == EINVAL);
    errno_slot = 0; CHECK(sigismember(&s, 32) == 0 && errno_slot == 0);
    s.sig[0] = 1UL << 31; /* signal 32 set by hand: sigismember reads the bit */
    CHECK(sigismember(&s, 32) == 1);
    errno_slot = 0; CHECK(sigemptyset((sigset_t *)0) == -1 && errno_slot == EINVAL);
    errno_slot = 0; CHECK(sigfillset((sigset_t *)0) == -1 && errno_slot == EINVAL);
    errno_slot = 0; CHECK(sigaddset((sigset_t *)0, 2) == -1 && errno_slot == EINVAL);
    errno_slot = 0; CHECK(sigismember((const sigset_t *)0, 2) == -1 && errno_slot == EINVAL);
    CHECK(ncalls == 0);

    /* ---- sigprocmask ---- */
    reset();
    sigemptyset(&s); sigaddset(&s, SIGUSR1);
    sigset_t old; memset(&old, 0, sizeof old);
    CHECK(sigprocmask(SIG_BLOCK, &s, &old) == 0);
    CHECK(ncalls == 1 && c_nr[0] == SYS_sigprocmask && c_a1[0] == SIG_BLOCK && c_a2[0] == (long)&s && c_a3[0] == (long)&old && c_a4[0] == 8);
    CHECK(c_mask[0] == 1UL << 9 && old.sig[0] == 0x5555);
    reset();
    CHECK(sigprocmask(SIG_SETMASK, (const sigset_t *)0, &old) == 0 && c_a2[0] == 0 && c_a3[0] == (long)&old);
    reset(); sigprocmask_reply = -22; errno_slot = 0;
    CHECK(sigprocmask(99, &s, (sigset_t *)0) == -1 && errno_slot == EINVAL && c_a1[0] == 99);
    reset(); sigprocmask_reply = -14; errno_slot = 0;
    CHECK(sigprocmask(SIG_BLOCK, (const sigset_t *)1, (sigset_t *)0) == -1 && errno_slot == EFAULT);

    /* ---- sigpending and sigsuspend: the 8-byte kernel mask, the kernel's error ---- */
    reset();
    CHECK(sigpending(&s) == 0 && c_nr[0] == SYS_sigpending && c_a1[0] == (long)&s && c_a2[0] == 8);
    reset(); susp_reply = -14; errno_slot = 0;
    CHECK(sigpending((sigset_t *)0) == -1 && errno_slot == EFAULT);
    reset(); susp_reply = -4; errno_slot = 0;
    CHECK(sigsuspend(&s) == -1 && errno_slot == EINTR && c_nr[0] == SYS_sigsuspend && c_a1[0] == (long)&s && c_a2[0] == 8);
    reset(); susp_reply = -14; errno_slot = 0;
    CHECK(sigsuspend((const sigset_t *)0) == -1 && errno_slot == EFAULT);
    CHECK(SYS_sigpending == 219 && SYS_sigsuspend == 220);

    /* ---- signal ---- */
    reset();
    static const int refused[] = { 0, -1, 9, 19, 32, 33, 65, 100 };
    for (unsigned i = 0; i < sizeof refused / sizeof refused[0]; i++) {
        errno_slot = 0;
        CHECK(signal(refused[i], handler_a) == SIG_ERR && errno_slot == EINVAL);
    }
    CHECK(ncalls == 0); /* all refused before any system call */
    old_handler_reply = 1; /* SIG_IGN was installed */
    errno_slot = 0;
    CHECK(signal(SIGUSR1, handler_a) == SIG_IGN && errno_slot == 0);
    CHECK(ncalls == 1 && c_nr[0] == SYS_sigaction && c_a1[0] == SIGUSR1);
    CHECK(c_act_handler[0] == (unsigned long)handler_a);
    CHECK(c_act_flags[0] == 0x10000000UL);          /* SA_RESTART: BSD semantics, glibc's default */
    CHECK(c_act_mask[0] == 1UL << 9);               /* the signal is blocked while it runs */
    CHECK(c_act_restorer[0] == 0);                  /* the kernel supplies the return path */
    reset(); old_handler_reply = (unsigned long)handler_a;
    CHECK(signal(SIGTERM, SIG_DFL) == handler_a && c_act_handler[0] == 0 && c_act_mask[0] == 1UL << 14);
    reset(); old_handler_reply = 0;
    CHECK(signal(64, SIG_IGN) == SIG_DFL && c_act_handler[0] == 1 && c_act_mask[0] == 1UL << 63);
    CHECK(signal(34, SIG_IGN) == SIG_DFL);
    reset(); sigaction_reply = -22; errno_slot = 0;
    CHECK(signal(SIGUSR1, handler_a) == SIG_ERR && errno_slot == EINVAL);

    /* ---- raise: the calling thread, not the process ---- */
    reset();
    CHECK(raise(SIGUSR1) == 0);
    CHECK(ncalls == 2 && c_nr[0] == SYS_gettid && c_nr[1] == SYS_tkill && c_a1[1] == 4242 && c_a2[1] == SIGUSR1);
    reset();
    CHECK(raise(0) == 0 && c_nr[1] == SYS_tkill && c_a2[1] == 0);
    reset();
    static const int notraisable[] = { -1, 65, 32, 33, 100 };
    for (unsigned i = 0; i < sizeof notraisable / sizeof notraisable[0]; i++) {
        errno_slot = 0;
        CHECK(raise(notraisable[i]) == -1 && errno_slot == EINVAL);
    }
    CHECK(ncalls == 0);
    reset(); tkill_reply = -3; errno_slot = 0;
    CHECK(raise(SIGTERM) == -1 && errno_slot == ESRCH);
    CHECK(raise(34) == -1 && errno_slot == ESRCH && c_a2[3] == 34);

    /* ---- abort: SIGABRT must end the process however the program set it up ---- */
    reset(); die_at_tkill = 1;
    if (setjmp(out) == 0) abort();
    CHECK(tkill_count == 1);
    CHECK(ncalls == 3); /* unblock, gettid, tkill */
    CHECK(c_nr[0] == SYS_sigprocmask && c_a1[0] == SIG_UNBLOCK && c_a2[0] != 0 && c_mask[0] == 1UL << 5 && c_a4[0] == 8);
    CHECK(c_nr[1] == SYS_gettid && c_nr[2] == SYS_tkill && c_a1[2] == 4242 && c_a2[2] == SIGABRT);
    /* The handler returned (or the signal is ignored): the action goes back to the default and the signal is sent again. */
    reset();
    if (setjmp(out) == 0) abort();
    CHECK(exit_status == 134);
    CHECK(tkill_count == 2);
    {
        int sa = -1, k;
        for (k = 0; k < ncalls; k++) if (c_nr[k] == SYS_sigaction) sa = k;
        CHECK(sa > 0 && c_a1[sa] == SIGABRT && c_act_handler[sa] == 0);
        int tk1 = -1, tk2 = -1;
        for (k = 0; k < ncalls; k++) if (c_nr[k] == SYS_tkill) { if (tk1 < 0) tk1 = k; else tk2 = k; }
        CHECK(tk1 >= 0 && tk2 > sa && sa > tk1);           /* tkill, then sigaction(SIG_DFL), then tkill again */
        int unblocks = 0;
        for (k = 0; k < ncalls; k++) if (c_nr[k] == SYS_sigprocmask && c_a1[k] == SIG_UNBLOCK && c_mask[k] == 1UL << 5) unblocks++;
        CHECK(unblocks == 2);                               /* SIGABRT unblocked before each attempt */
    }

    if (bad) { fprintf(stderr, "test_signal_abi: %d failure(s)\n", bad); return 1; }
    printf("test_signal_abi: ok\n");
    return 0;
}
