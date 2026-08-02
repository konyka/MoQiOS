/* signal.c — sigaction wrapper (freestanding only). */
#include "../include/signal.h"
#include "../include/moqi_syscalls.h"

long sigaction(int sig, const struct ksigaction *act, struct ksigaction *oldact) {
    return syscall3(SYS_sigaction, sig, (long)act, (long)oldact);
}
