/* errno.h — Linux errno values and the per-thread errno of moqi_libc.
 *
 * The kernel returns -errno from system calls; wrappers that follow the POSIX convention (mman.h) store the value
 * here and return -1. errno is per thread, kept in the thread control block (pthread.c).
 */
#ifndef MOQI_ERRNO_H
#define MOQI_ERRNO_H

#define EPERM        1
#define ENOENT       2
#define ESRCH        3
#define EINTR        4
#define EIO          5
#define EBADF        9
#define EAGAIN       11
#define ENOMEM       12
#define EACCES       13
#define EFAULT       14
#define EEXIST       17
#define ENODEV       19
#define ENOTDIR      20
#define EISDIR       21
#define EINVAL       22
#define ENFILE       23
#define EMFILE       24
#define ENOTTY       25
#define ESPIPE       29
#define EDOM         33
#define ERANGE       34
#define ENAMETOOLONG 36
#define ENOSYS       38
#define ENOTEMPTY    39
#define EOVERFLOW    75
#define EILSEQ       84
#define EOPNOTSUPP   95

int *__errno_location(void);

/* The name the program was started with (argv[0]) and the part after its last '/'; empty when there was no argv[0]. Set by
 * crt0 before main. */
extern char *program_invocation_name;
extern char *program_invocation_short_name;
#ifndef errno
#define errno (*__errno_location())
#endif

#endif /* MOQI_ERRNO_H */
