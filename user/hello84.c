#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

#define SYS_EPOLL_CREATE1 146
#define SYS_FCNTL 72
#define F_GETFD 1
#define FD_CLOEXEC 1

static int close_created(long fd) {
    return fd >= 0 && close((int)fd) == 0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    int failures = 0;
    long fd;

    print("hello84: start\n");

    fd = syscall1(SYS_EPOLL_CREATE1, 0);
    if (fd < 0 || syscall3(SYS_FCNTL, fd, F_GETFD, 0) != 0 || !close_created(fd)) failures = 1;

    fd = syscall1(SYS_EPOLL_CREATE1, 0x80000);
    if (fd < 0 || (syscall3(SYS_FCNTL, fd, F_GETFD, 0) & FD_CLOEXEC) == 0 || !close_created(fd)) failures = 1;

    if (syscall1(SYS_EPOLL_CREATE1, 1) != -22) failures = 1;

    if (!failures) print("hello84: PASS\nhello84 done\n");
    else print("hello84: FAIL\nhello84 done\n");
    return failures;
}
