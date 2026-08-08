/* unistd.c — thin syscall wrappers (freestanding only, not host-testable).
 * Every wrapper is a 1:1 mapping to the kernel ABI; see moqi_syscalls.h.
 */
#include "../include/unistd.h"
#include "../include/moqi_syscalls.h"

long read(int fd, void *buf, size_t count) {
    return syscall3(SYS_read, fd, (long)buf, (long)count);
}

long write(int fd, const void *buf, size_t count) {
    return syscall3(SYS_write, fd, (long)buf, (long)count);
}

long open(const char *path, long flags, long mode) {
    return syscall3(SYS_open, (long)path, flags, mode);
}

long close(int fd) {
    return syscall1(SYS_close, fd);
}

long lseek(int fd, long offset, int whence) {
    return syscall3(SYS_lseek, fd, offset, whence);
}

long unlink(const char *path) {
    return syscall1(SYS_unlink, (long)path);
}

long mkdir(const char *path) {
    return syscall1(SYS_mkdir, (long)path);
}

long fork(void) {
    return syscall0(SYS_fork);
}

long execve(const char *path, char *const argv[], char *const envp[]) {
    return syscall3(SYS_execve, (long)path, (long)argv, (long)envp);
}

long waitpid(long pid, int *status, long options) {
    return syscall3(SYS_waitpid, pid, (long)status, options);
}

long getpid(void) {
    return syscall0(SYS_getpid);
}

long kill(long pid, long sig) {
    return syscall2(SYS_kill, pid, sig);
}

long setsid(void) {
    return syscall0(206);
}

long setpgid(long pid, long pgid) {
    return syscall2(207, pid, pgid);
}

long getpgid(long pid) {
    return syscall1(208, pid);
}

long getsid(long pid) {
    return syscall1(209, pid);
}

void _exit(int code) {
    syscall1(SYS_exit, code);
    for (;;) {}
}

long pipe(int fds[2]) {
    return syscall3(SYS_pipe, (long)fds, 0, 0);
}

long dup2(int oldfd, int newfd) {
    return syscall3(SYS_dup2, oldfd, newfd, 0);
}

long yield(void) {
    return syscall0(SYS_yield);
}

long nanosleep(const struct timespec *req, struct timespec *rem) {
    return syscall2(SYS_nanosleep, (long)req, (long)rem);
}

void *brk(void *addr) {
    return (void *)syscall1(SYS_brk, (long)addr);
}

void *sbrk(long increment) {
    long cur = syscall1(SYS_brk, 0);
    if (cur == 0) return (void *)-1;
    if (increment == 0) return (void *)cur;
    /* brk returns the unchanged break on failure. */
    long next = syscall1(SYS_brk, cur + increment);
    if (next != cur + increment) return (void *)-1;
    return (void *)cur;
}

long chdir(const char *path) {
    return syscall1(SYS_chdir, (long)path);
}

long getcwd(char *buf, size_t size) {
    return syscall2(SYS_getcwd, (long)buf, (long)size);
}

long moqi_setenv(const char *kvp) {
    return syscall2(SYS_setenv, (long)kvp, 0);
}

long moqi_getenv(const char *key, char *val, long max) {
    return syscall3(SYS_getenv, (long)key, (long)val, max);
}

long moqi_listdir(char *buf, size_t size) {
    return syscall2(SYS_listdir, (long)buf, (long)size);
}
