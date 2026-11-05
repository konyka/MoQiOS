/* select.c -- select and pselect (see include/select.h). One system call; the kernel does the work. */
#include "../include/select.h"
#include "hostsys.h"

int select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout) {
    long r = MSYS5(SYS_select, nfds, readfds, writefds, exceptfds, timeout);
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    return (int)r;
}

int pselect(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, const struct timespec *timeout, const void *sigmask) {
    struct { const void *mask; unsigned long size; } sigdata = { sigmask, 8 };
    struct timespec left;
    struct timespec *tp = 0;
    if (timeout) {
        left = *timeout;
        tp = &left;
    }
    long r = MSYS6(SYS_pselect6, nfds, readfds, writefds, exceptfds, tp, sigmask ? &sigdata : 0);
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    return (int)r;
}
