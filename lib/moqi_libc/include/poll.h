/* poll.h -- wait for readiness on a set of descriptors, over the MoQiOS poll and ppoll system calls.
 *
 * Layout and constants are glibc's on x86-64 (measured): struct pollfd is 8 bytes (fd at 0, events at 4, revents at 6) and the
 * event bits are POLLIN 1, POLLPRI 2, POLLOUT 4, POLLERR 8, POLLHUP 0x10, POLLNVAL 0x20, POLLRDNORM 0x40, POLLRDBAND 0x80,
 * POLLWRNORM 0x100, POLLWRBAND 0x200 and POLLRDHUP 0x2000.
 *
 * poll returns the number of descriptors whose revents is non-zero, 0 when the timeout (milliseconds, negative = forever) ran
 * out first, and -1 with errno on failure (EINTR when a signal handler ran, EINVAL for a bad nfds, EFAULT for a bad array).
 * ppoll takes a struct timespec (NULL = forever) and an optional signal mask installed for the duration of the wait; the mask
 * size passed to the kernel is 8 (0 when there is no mask). select() is in select.h.
 */
#ifndef MOQI_POLL_H
#define MOQI_POLL_H

#include "time.h"

#define POLLIN     0x001
#define POLLPRI    0x002
#define POLLOUT    0x004
#define POLLERR    0x008
#define POLLHUP    0x010
#define POLLNVAL   0x020
#define POLLRDNORM 0x040
#define POLLRDBAND 0x080
#define POLLWRNORM 0x100
#define POLLWRBAND 0x200
#define POLLRDHUP  0x2000

struct pollfd {
    int   fd;
    short events;
    short revents;
};

typedef unsigned long nfds_t;

int poll(struct pollfd *fds, nfds_t nfds, int timeout);
int ppoll(struct pollfd *fds, nfds_t nfds, const struct timespec *timeout, const unsigned long *sigmask);

#endif
