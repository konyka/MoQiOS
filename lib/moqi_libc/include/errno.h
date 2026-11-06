/* errno.h — Linux errno values and the per-thread errno of moqi_libc.
 *
 * Every name here has the number glibc gives it on Linux x86-64 (host_tests/test_errno_abi.c checks each one, and that strerror has a text for it).
 * The kernel returns -errno from system calls; wrappers that follow the POSIX convention (mman.h) store the value
 * here and return -1. errno is per thread, kept in the thread control block (pthread.c).
 */
#ifndef MOQI_ERRNO_H
#define MOQI_ERRNO_H

#define EPERM            1
#define ENOENT           2
#define ESRCH            3
#define EINTR            4
#define EIO              5
#define ENXIO            6
#define E2BIG            7
#define ENOEXEC          8
#define EBADF            9
#define ECHILD           10
#define EAGAIN           11
#define ENOMEM           12
#define EACCES           13
#define EFAULT           14
#define ENOTBLK          15
#define EBUSY            16
#define EEXIST           17
#define EXDEV            18
#define ENODEV           19
#define ENOTDIR          20
#define EISDIR           21
#define EINVAL           22
#define ENFILE           23
#define EMFILE           24
#define ENOTTY           25
#define ETXTBSY          26
#define EFBIG            27
#define ENOSPC           28
#define ESPIPE           29
#define EROFS            30
#define EMLINK           31
#define EPIPE            32
#define EDOM             33
#define ERANGE           34
#define EDEADLK          35
#define ENAMETOOLONG     36
#define ENOLCK           37
#define ENOSYS           38
#define ENOTEMPTY        39
#define ELOOP            40
#define ENOMSG           42
#define EIDRM            43
#define ENOSTR           60
#define ENODATA          61
#define ETIME            62
#define ENOSR            63
#define ENOLINK          67
#define EPROTO           71
#define EBADMSG          74
#define EOVERFLOW        75
#define EILSEQ           84
#define EUSERS           87
#define ENOTSOCK         88
#define EDESTADDRREQ     89
#define EMSGSIZE         90
#define EPROTOTYPE       91
#define ENOPROTOOPT      92
#define EPROTONOSUPPORT  93
#define ESOCKTNOSUPPORT  94
#define EOPNOTSUPP       95
#define EPFNOSUPPORT     96
#define EAFNOSUPPORT     97
#define EADDRINUSE       98
#define EADDRNOTAVAIL    99
#define ENETDOWN         100
#define ENETUNREACH      101
#define ENETRESET        102
#define ECONNABORTED     103
#define ECONNRESET       104
#define ENOBUFS          105
#define EISCONN          106
#define ENOTCONN         107
#define ESHUTDOWN        108
#define ETOOMANYREFS     109
#define ETIMEDOUT        110
#define ECONNREFUSED     111
#define EHOSTDOWN        112
#define EHOSTUNREACH     113
#define EALREADY         114
#define EINPROGRESS      115
#define ESTALE           116
#define EDQUOT           122
#define ECANCELED        125
#define EOWNERDEAD       130
#define ENOTRECOVERABLE  131
#define EWOULDBLOCK      EAGAIN
#define ENOTSUP          EOPNOTSUPP
#define EDEADLOCK        EDEADLK

int *__errno_location(void);

/* The name the program was started with (argv[0]) and the part after its last '/'; empty when there was no argv[0]. Set by
 * crt0 before main. */
extern char *program_invocation_name;
extern char *program_invocation_short_name;
#ifndef errno
#define errno (*__errno_location())
#endif

#endif /* MOQI_ERRNO_H */
