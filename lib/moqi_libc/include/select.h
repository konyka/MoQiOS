/* select.h -- wait for readiness on descriptor sets, over the MoQiOS select system call.
 *
 * Layout and macros are glibc's on x86-64 (measured): fd_set is 128 bytes (1024 bits), FD_SETSIZE is 1024, and descriptor n is bit
 * n % 64 of the 64-bit word n / 64. struct timeval (16 bytes) comes from time.h.
 *
 * select returns the number of ready descriptors over the three sets, 0 when the timeout ran out first, and -1 with errno on
 * failure (EINTR when a signal handler ran, EINVAL for a bad nfds or timeout, EBADF for a closed descriptor in a set). A NULL
 * timeout waits forever; the kernel writes the time left back into a non-NULL one, as Linux does. The sets are rewritten to the
 * ready descriptors only. FD_SET, FD_CLR and FD_ISSET do not check that the descriptor is below FD_SETSIZE.
 */
#ifndef MOQI_SELECT_H
#define MOQI_SELECT_H

#include "time.h"

#define FD_SETSIZE 1024

typedef struct {
    unsigned long fds_bits[FD_SETSIZE / (8 * sizeof(unsigned long))];
} fd_set;

#define FD_ZERO(set) do { \
        for (unsigned moqi_i_ = 0; moqi_i_ < sizeof (set)->fds_bits / sizeof (set)->fds_bits[0]; moqi_i_++) \
            (set)->fds_bits[moqi_i_] = 0; \
    } while (0)
#define FD_SET(fd, set)   ((set)->fds_bits[(unsigned)(fd) / 64] |=  (1UL << ((unsigned)(fd) % 64)))
#define FD_CLR(fd, set)   ((set)->fds_bits[(unsigned)(fd) / 64] &= ~(1UL << ((unsigned)(fd) % 64)))
#define FD_ISSET(fd, set) (((set)->fds_bits[(unsigned)(fd) / 64] >> ((unsigned)(fd) % 64)) & 1UL)

int select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, struct timeval *timeout);

#endif
