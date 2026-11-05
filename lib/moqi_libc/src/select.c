/* select.c -- select (see include/select.h). One system call; the kernel does the work. */
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
