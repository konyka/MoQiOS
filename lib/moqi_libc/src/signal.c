/* signal.c — signals: sigaction, signal, raise, abort, sigset_t and sigprocmask (see include/signal.h). */
#include "../include/signal.h"
#include "../include/unistd.h"
#include "hostsys.h"

long sigaction(int sig, const struct ksigaction *act, struct ksigaction *oldact) {
    return MSYS3(SYS_sigaction, sig, act, oldact);
}

/* Signal numbers the library accepts: 1..64 without glibc's two reserved real-time signals (32 and 33). */
static int sig_valid(int sig) {
    return sig >= 1 && sig <= 64 && sig != 32 && sig != 33;
}

#define SA_RESTART_FLAG 0x10000000UL

void (*signal(int sig, void (*handler)(int)))(int) {
    if (!sig_valid(sig) || sig == SIGKILL || sig == SIGSTOP) {
        errno = EINVAL;
        return SIG_ERR;
    }
    struct ksigaction act = { handler, SA_RESTART_FLAG, (void *)0, 1UL << (sig - 1) };
    struct ksigaction old = { SIG_DFL, 0, (void *)0, 0 };
    long r = sigaction(sig, &act, &old);
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return SIG_ERR;
    }
    return old.handler;
}

int raise(int sig) {
    if (sig != 0 && !sig_valid(sig)) {
        errno = EINVAL;
        return -1;
    }
    return __moqi_ret(MSYS2(SYS_tkill, MSYS0(SYS_gettid), sig));
}

void abort(void) {
    /* The signal must be able to arrive whatever the caller blocked. */
    unsigned long bit = 1UL << (SIGABRT - 1);
    MSYS4(SYS_sigprocmask, SIG_UNBLOCK, &bit, 0, 8);
    raise(SIGABRT);
    /* Still here: a handler returned, or the signal was ignored. Take the handler away and try again. */
    struct ksigaction dfl = { SIG_DFL, 0, (void *)0, 0 };
    sigaction(SIGABRT, &dfl, (struct ksigaction *)0);
    MSYS4(SYS_sigprocmask, SIG_UNBLOCK, &bit, 0, 8);
    raise(SIGABRT);
    for (;;) _exit(128 + SIGABRT);
}

/* Only the first word of a set is written and read, as in glibc 2.4x; it is all the kernel looks at. */
int sigemptyset(sigset_t *set) {
    if (set == (sigset_t *)0) {
        errno = EINVAL;
        return -1;
    }
    set->sig[0] = 0;
    return 0;
}

int sigfillset(sigset_t *set) {
    if (set == (sigset_t *)0) {
        errno = EINVAL;
        return -1;
    }
    set->sig[0] = ~(1UL << 31) & ~(1UL << 32);
    return 0;
}

int sigaddset(sigset_t *set, int sig) {
    if (set == (sigset_t *)0 || !sig_valid(sig)) {
        errno = EINVAL;
        return -1;
    }
    set->sig[0] |= 1UL << (sig - 1);
    return 0;
}

int sigdelset(sigset_t *set, int sig) {
    if (set == (sigset_t *)0 || !sig_valid(sig)) {
        errno = EINVAL;
        return -1;
    }
    set->sig[0] &= ~(1UL << (sig - 1));
    return 0;
}

int sigismember(const sigset_t *set, int sig) {
    if (set == (const sigset_t *)0 || sig < 1 || sig > 64) {
        errno = EINVAL;
        return -1;
    }
    return (int)((set->sig[0] >> (sig - 1)) & 1UL);
}

int sigprocmask(int how, const sigset_t *set, sigset_t *oldset) {
    return __moqi_ret(MSYS4(SYS_sigprocmask, how, set, oldset, 8));
}

int sigpending(sigset_t *set) {
    return __moqi_ret(MSYS2(SYS_sigpending, set, 8));
}

int sigsuspend(const sigset_t *mask) {
    return __moqi_ret(MSYS2(SYS_sigsuspend, mask, 8));
}
