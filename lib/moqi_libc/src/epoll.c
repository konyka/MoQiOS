/* epoll.c -- epoll_create1, epoll_ctl, epoll_wait and epoll_pwait (see include/epoll.h). One system call each; the kernel does the work. */
#include "../include/epoll.h"
#include "hostsys.h"

static int epoll_ret(long r) {
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    return (int)r;
}

int epoll_create1(int flags) {
    return epoll_ret(MSYS1(SYS_epoll_create1, flags));
}

int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event) {
    return epoll_ret(MSYS4(SYS_epoll_ctl, epfd, op, fd, event));
}

int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout) {
    return epoll_ret(MSYS4(SYS_epoll_wait, epfd, events, maxevents, timeout));
}

int epoll_pwait(int epfd, struct epoll_event *events, int maxevents, int timeout, const void *sigmask) {
    return epoll_ret(MSYS6(SYS_epoll_pwait, epfd, events, maxevents, timeout, sigmask, sigmask ? 8 : 0));
}
