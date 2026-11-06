/* fcntl.h -- file control and open flags for moqi_libc, over the MoQiOS fcntl system call.
 *
 * Constants are Linux x86-64's (the same values glibc uses): O_NONBLOCK 0x800, O_EXCL 0x80, O_DIRECTORY 0x10000, O_NOFOLLOW
 * 0x20000, O_CLOEXEC 0x80000; F_DUPFD 0, F_GETFD 1, F_SETFD 2, F_GETFL 3, F_SETFL 4, F_DUPFD_CLOEXEC 1030; FD_CLOEXEC 1. The
 * access-mode and create flags (O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, O_APPEND) are in unistd.h next to open().
 *
 * fcntl(fd, cmd, ...) returns the kernel's value on success and -1 with errno on failure (EBADF, EINVAL for an unknown command).
 * The optional third argument is read as a long; for a command that takes none the kernel is handed whatever the register held
 * and ignores it.
 */
#ifndef MOQI_FCNTL_H
#define MOQI_FCNTL_H

#include "unistd.h"

#define O_ACCMODE   0x3
#define O_EXCL      0x80
#define O_NOCTTY    0x100
#define O_NONBLOCK  0x800
#define O_DIRECTORY 0x10000
#define O_NOFOLLOW  0x20000
#define O_CLOEXEC   0x80000

#define F_DUPFD         0
#define F_GETFD         1
#define F_SETFD         2
#define F_GETFL         3
#define F_SETFL         4
#define F_DUPFD_CLOEXEC 1030

#define FD_CLOEXEC 1

int fcntl(int fd, int cmd, ...);

#endif
