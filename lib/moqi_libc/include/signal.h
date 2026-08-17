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

/* Matches the kernel's expected sigaction layout (kernel reads 28 bytes):
 * the handler pointer is the first 8 bytes of the struct. */
struct ksigaction {
    void (*handler)(int);
    unsigned long mask;
    unsigned long flags;
    void *restorer;
};

long sigaction(int sig, const struct ksigaction *act, struct ksigaction *oldact);

#endif /* MOQI_SIGNAL_H */
