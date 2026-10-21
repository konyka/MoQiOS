/* signal.h — minimal signal interface matching the kernel's sigaction ABI. */
#ifndef MOQI_SIGNAL_H
#define MOQI_SIGNAL_H

#define SIGINT  2
#define SIGKILL 9
#define SIGSEGV 11
#define SIGTERM 15
#define SIGXFSZ 25

#define SIG_DFL ((void (*)(int))0)
#define SIG_IGN ((void (*)(int))1)

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

#endif /* MOQI_SIGNAL_H */
