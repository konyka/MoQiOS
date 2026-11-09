/* fdops.c -- descriptor and file operations: dup, dup3, fcntl, pread, pwrite, preadv2, pwritev2, truncate, ftruncate, fsync, fdatasync, access,
 * umask, pipe2 and fchdir (see include/unistd.h and include/fcntl.h).
 *
 * These follow the POSIX/glibc convention: the kernel's value on success, -1 with errno on failure (umask cannot fail and returns
 * the old mask). Each one is a single system call; the kernel validates the arguments.
 */
#include <stdarg.h>

#include "../include/fcntl.h"
#include "../include/unistd.h"
#include "hostsys.h"

static int fd_ret(long r) {
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    return (int)r;
}

static long fd_lret(long r) {
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    return r;
}

int dup(int oldfd) { return fd_ret(MSYS1(SYS_dup, oldfd)); }
int dup3(int oldfd, int newfd, int flags) { return fd_ret(MSYS3(SYS_dup3, oldfd, newfd, flags)); }

/* The third argument is always read as a long, as glibc does; for a command that takes none it is whatever the register held, and
 * the kernel ignores it for those commands. */
int fcntl(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    long arg = va_arg(ap, long);
    va_end(ap);
    return fd_ret(MSYS3(SYS_fcntl, fd, cmd, arg));
}

long pread(int fd, void *buf, size_t count, long offset) { return fd_lret(MSYS4(SYS_pread64, fd, buf, count, offset)); }
long pwrite(int fd, const void *buf, size_t count, long offset) { return fd_lret(MSYS4(SYS_pwrite64, fd, buf, count, offset)); }

/* glibc's x86-64 layout: the whole offset in pos_l, 0 in pos_h, the flags sixth. */
long preadv2(int fd, const struct iovec *iov, int iovcnt, long offset, int flags) {
    return fd_lret(MSYS6(SYS_preadv2, fd, iov, iovcnt, offset, 0, flags));
}
long pwritev2(int fd, const struct iovec *iov, int iovcnt, long offset, int flags) {
    return fd_lret(MSYS6(SYS_pwritev2, fd, iov, iovcnt, offset, 0, flags));
}

int truncate(const char *path, long length) { return fd_ret(MSYS2(SYS_truncate, path, length)); }
int ftruncate(int fd, long length) { return fd_ret(MSYS2(SYS_ftruncate, fd, length)); }
int fsync(int fd) { return fd_ret(MSYS1(SYS_fsync, fd)); }
int fdatasync(int fd) { return fd_ret(MSYS1(SYS_fdatasync, fd)); }
int access(const char *path, int mode) { return fd_ret(MSYS2(SYS_access, path, mode)); }
unsigned int umask(unsigned int mask) { return (unsigned int)MSYS1(SYS_umask, mask); }
int pipe2(int fds[2], int flags) { return fd_ret(MSYS2(SYS_pipe2, fds, flags)); }
int fchdir(int fd) { return fd_ret(MSYS1(SYS_fchdir, fd)); }
