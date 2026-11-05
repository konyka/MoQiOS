/* hostsys.h — the system-call entry used by the libc files that have a host test.
 *
 * In the freestanding build these are the inline `syscall` wrappers of moqi_syscalls.h. A host test defines
 * MOQI_HOST_TEST_SYSCALL and supplies moqi_test_syscall6, a recording stub, so the file's logic runs without a kernel.
 * A kernel return value in [-4095, -1] is an error, as in glibc; __moqi_ret turns it into the POSIX convention (errno set,
 * -1 returned).
 */
#ifndef MOQI_HOSTSYS_H
#define MOQI_HOSTSYS_H

#include "../include/errno.h"
#include "../include/moqi_syscalls.h"

#ifdef MOQI_HOST_TEST_SYSCALL
extern long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6);
#define MSYS0(nr) moqi_test_syscall6((nr), 0, 0, 0, 0, 0, 0)
#define MSYS1(nr, a) moqi_test_syscall6((nr), (long)(a), 0, 0, 0, 0, 0)
#define MSYS2(nr, a, b) moqi_test_syscall6((nr), (long)(a), (long)(b), 0, 0, 0, 0)
#define MSYS3(nr, a, b, c) moqi_test_syscall6((nr), (long)(a), (long)(b), (long)(c), 0, 0, 0)
#define MSYS4(nr, a, b, c, d) moqi_test_syscall6((nr), (long)(a), (long)(b), (long)(c), (long)(d), 0, 0)
#define MSYS5(nr, a, b, c, d, e) moqi_test_syscall6((nr), (long)(a), (long)(b), (long)(c), (long)(d), (long)(e), 0)
#else
#define MSYS0(nr) syscall0(nr)
#define MSYS1(nr, a) syscall1((nr), (long)(a))
#define MSYS2(nr, a, b) syscall2((nr), (long)(a), (long)(b))
#define MSYS3(nr, a, b, c) syscall3((nr), (long)(a), (long)(b), (long)(c))
#define MSYS4(nr, a, b, c, d) syscall4((nr), (long)(a), (long)(b), (long)(c), (long)(d))
#define MSYS5(nr, a, b, c, d, e) syscall5((nr), (long)(a), (long)(b), (long)(c), (long)(d), (long)(e))
#endif

static inline int __moqi_is_error(long ret) {
    return (unsigned long)ret > (unsigned long)-4095L - 1;
}

/* 0 on success; on failure errno = the error and -1. */
static inline int __moqi_ret(long ret) {
    if (__moqi_is_error(ret)) {
        errno = (int)-ret;
        return -1;
    }
    return 0;
}

#endif /* MOQI_HOSTSYS_H */
