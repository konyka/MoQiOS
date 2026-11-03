/* errno.h — Linux errno values and the per-thread errno of moqi_libc.
 *
 * The kernel returns -errno from system calls; wrappers that follow the POSIX convention (mman.h) store the value
 * here and return -1. errno is per thread, kept in the thread control block (pthread.c).
 */
#ifndef MOQI_ERRNO_H
#define MOQI_ERRNO_H

#define EPERM        1
#define ENOENT       2
#define EINTR        4
#define EIO          5
#define EBADF        9
#define EAGAIN       11
#define ENOMEM       12
#define EACCES       13
#define EFAULT       14
#define EEXIST       17
#define ENODEV       19
#define EINVAL       22
#define ENFILE       23
#define EMFILE       24
#define ERANGE       34
#define ENAMETOOLONG 36
#define ENOSYS       38
#define EOVERFLOW    75
#define EOPNOTSUPP   95

int *__errno_location(void);
#ifndef errno
#define errno (*__errno_location())
#endif

#endif /* MOQI_ERRNO_H */
