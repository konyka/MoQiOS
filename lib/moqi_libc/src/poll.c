/* poll.c -- poll and ppoll (see include/poll.h). One system call each; the kernel does the work. */
#include "../include/poll.h"
#include "hostsys.h"

static int poll_ret(long r) {
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    return (int)r;
}

int poll(struct pollfd *fds, nfds_t nfds, int timeout) {
    return poll_ret(MSYS3(SYS_poll, fds, nfds, timeout));
}

int ppoll(struct pollfd *fds, nfds_t nfds, const struct timespec *timeout, const unsigned long *sigmask) {
    return poll_ret(MSYS5(SYS_ppoll, fds, nfds, timeout, sigmask, sigmask ? 8 : 0));
}
