/* signal.h — signals for moqi_libc, over the MoQiOS signal system calls.
 *
 * Numbers, constants and behavior follow glibc on x86-64 as measured (host_tests/test_signal_abi.c), so SIGUSR1 is 10,
 * SIGUSR2 12, SIGALRM 14, SIGCHLD 17 and the real-time signals start at 34. Signals 32 and 33 are reserved, as in glibc: the
 * set functions, signal() and raise() refuse them with EINVAL (the kernel itself would accept them).
 *
 * signal(sig, handler) installs the handler with BSD semantics, like glibc: the handler stays installed after it runs, the
 * signal is blocked while it runs, and SA_RESTART is requested (the kernel then re-runs an interrupted read, write, waitpid,
 * wait4, readv, writev, accept, socket send/receive or splice after the handler returns; connect, sleeps, pause, sigsuspend and the
 * poll/epoll waits still fail with EINTR). It returns the previous handler, or SIG_ERR with errno EINVAL for a signal number
 * outside 1..64 or the reserved 32 and 33, or for SIGKILL and SIGSTOP, which cannot be caught or ignored.
 *
 * raise(sig) sends the signal to the calling thread (not the process) and, when it is not blocked, its handler has run
 * before raise returns; raise(0) only checks. abort() ends the process with SIGABRT: it unblocks the signal, raises it (a
 * handler may run), and if the process is still alive (the handler returned, or SIGABRT was ignored) resets the action to
 * the default and raises it again, so it never returns. It does not run atexit functions and does not flush FILE streams.
 *
 * sigset_t is glibc's 128 bytes, but only the first 64 bits (signals 1..64, signal n is bit n-1) reach the kernel.
 * sigemptyset and sigfillset (every signal but the reserved 32 and 33) write only the first 8 bytes. sigaddset and sigdelset
 * return 0, or -1 with EINVAL for a signal number outside 1..64 or the reserved 32 and 33; sigismember returns 1 or 0 for 1..64
 * (the reserved ones read as 0 unless their bit was set by hand) and -1 with EINVAL otherwise. A NULL set is EINVAL (glibc crashes). sigprocmask(how, set, old) returns 0 or -1 with errno: EINVAL for a bad how when a set is given,
 * EFAULT for an unreadable pointer; the signals SIGKILL and SIGSTOP are never blocked. With a NULL set it only reads the mask.
 * sigpending(set) stores the signals that are blocked and waiting (EFAULT for a NULL or bad pointer). sigsuspend(mask) installs the
 * mask, sleeps until a signal that it does not block has run its handler, restores the old mask and returns -1 with EINTR; it
 * never returns 0.
 */
#ifndef MOQI_SIGNAL_H
#define MOQI_SIGNAL_H

#define SIGHUP    1
#define SIGINT    2
#define SIGQUIT   3
#define SIGILL    4
#define SIGTRAP   5
#define SIGABRT   6
#define SIGIOT    6
#define SIGBUS    7
#define SIGFPE    8
#define SIGKILL   9
#define SIGUSR1   10
#define SIGSEGV   11
#define SIGUSR2   12
#define SIGPIPE   13
#define SIGALRM   14
#define SIGTERM   15
#define SIGSTKFLT 16
#define SIGCHLD   17
#define SIGCONT   18
#define SIGSTOP   19
#define SIGTSTP   20
#define SIGTTIN   21
#define SIGTTOU   22
#define SIGURG    23
#define SIGXCPU   24
#define SIGXFSZ   25
#define SIGVTALRM 26
#define SIGPROF   27
#define SIGWINCH  28
#define SIGIO     29
#define SIGPOLL   29
#define SIGPWR    30
#define SIGSYS    31
#define SIGRTMIN  34
#define SIGRTMAX  64
#define NSIG      65

typedef int sig_atomic_t;
typedef void (*sighandler_t)(int);

#define SIG_DFL ((void (*)(int))0)
#define SIG_IGN ((void (*)(int))1)
#define SIG_ERR ((void (*)(int))-1)

#define SIG_BLOCK   0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2

typedef struct { unsigned long sig[16]; } sigset_t;

/* Linux struct sigaction layout: the kernel reads the handler at offset 0
 * and, when the full struct is addressable, applies the u64 sa_mask from
 * offset 24 (see kernel/proc/signal_syscall.zig). The mask must therefore
 * stay the fourth field; earlier field orders made every sigaction() write
 * the restorer into the kernel's mask slot and silently clear the task's
 * signal mask. */
struct ksigaction {
    void (*handler)(int);
    unsigned long flags;
    void *restorer;
    unsigned long mask;
};

_Static_assert(__builtin_offsetof(struct ksigaction, mask) == 24,
               "kernel reads sa_mask at offset 24");
_Static_assert(__builtin_offsetof(struct ksigaction, handler) == 0,
               "kernel reads the handler at offset 0");

long sigaction(int sig, const struct ksigaction *act, struct ksigaction *oldact);

void (*signal(int sig, void (*handler)(int)))(int);
int raise(int sig);
void abort(void) __attribute__((noreturn));

int sigemptyset(sigset_t *set);
int sigfillset(sigset_t *set);
int sigaddset(sigset_t *set, int sig);
int sigdelset(sigset_t *set, int sig);
int sigismember(const sigset_t *set, int sig);
int sigprocmask(int how, const sigset_t *set, sigset_t *oldset);
int sigpending(sigset_t *set);
int sigsuspend(const sigset_t *mask);

#endif /* MOQI_SIGNAL_H */
