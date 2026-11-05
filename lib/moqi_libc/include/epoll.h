/* epoll.h -- scalable readiness notification, over the MoQiOS epoll system calls.
 *
 * Layout and constants are glibc's on x86-64 (measured): struct epoll_event is PACKED to 12 bytes (events at 0, the 8-byte data
 * union at 4), EPOLLIN 1, EPOLLPRI 2, EPOLLOUT 4, EPOLLERR 8, EPOLLHUP 0x10, EPOLLRDHUP 0x2000, EPOLLEXCLUSIVE 0x10000000,
 * EPOLLONESHOT 0x40000000, EPOLLET 0x80000000; EPOLL_CTL_ADD 1, EPOLL_CTL_DEL 2, EPOLL_CTL_MOD 3; EPOLL_CLOEXEC 0x80000.
 *
 * Every function returns the kernel's value on success (epoll_create1: the new descriptor, epoll_ctl: 0, epoll_wait: the number of
 * events written, 0 on timeout) and -1 with errno on failure (EINTR when a signal handler ran during epoll_wait, EBADF, EEXIST,
 * ENOENT, EINVAL, ...). epoll_wait's timeout is in milliseconds, negative = forever. There is no epoll_create, epoll_pwait or
 * epoll_pwait2 wrapper.
 */
#ifndef MOQI_EPOLL_H
#define MOQI_EPOLL_H

#include <stdint.h>

#define EPOLL_CLOEXEC 0x80000

#define EPOLL_CTL_ADD 1
#define EPOLL_CTL_DEL 2
#define EPOLL_CTL_MOD 3

#define EPOLLIN        0x001
#define EPOLLPRI       0x002
#define EPOLLOUT       0x004
#define EPOLLERR       0x008
#define EPOLLHUP       0x010
#define EPOLLRDHUP     0x2000
#define EPOLLEXCLUSIVE 0x10000000u
#define EPOLLWAKEUP    0x20000000u
#define EPOLLONESHOT   0x40000000u
#define EPOLLET        0x80000000u

typedef union epoll_data {
    void    *ptr;
    int      fd;
    uint32_t u32;
    uint64_t u64;
} epoll_data_t;

struct epoll_event {
    uint32_t     events;
    epoll_data_t data;
} __attribute__((packed));

int epoll_create1(int flags);
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);

#endif
