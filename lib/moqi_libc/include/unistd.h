/* unistd.h — thin wrappers over the MoQiOS syscall ABI (freestanding only).
 *
 * All wrappers return the raw kernel value: non-negative on success,
 * negative -errno on failure. No errno translation is performed.
 */
#ifndef MOQI_UNISTD_H
#define MOQI_UNISTD_H

#include <stddef.h>

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

/* open() flags — Linux-style values, matching what the kernel accepts. */
#define O_RDONLY 0x000
#define O_WRONLY 0x001
#define O_RDWR   0x002
#define O_CREAT  0x040
#define O_TRUNC  0x200
#define O_APPEND 0x400

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

struct timespec {
    long tv_sec;
    long tv_nsec;
};

long read(int fd, void *buf, size_t count);
long write(int fd, const void *buf, size_t count);
long open(const char *path, long flags, long mode);
long close(int fd);
long lseek(int fd, long offset, int whence);
long unlink(const char *path);
long mkdir(const char *path);

long fork(void);
long execve(const char *path, char *const argv[], char *const envp[]);
long waitpid(long pid, int *status, long options);
long getpid(void);
long kill(long pid, long sig);
void _exit(int code) __attribute__((noreturn));

long pipe(int fds[2]);
long dup2(int oldfd, int newfd);

long yield(void);
long nanosleep(const struct timespec *req, struct timespec *rem);

void *brk(void *addr);
void *sbrk(long increment);

long chdir(const char *path);
long getcwd(char *buf, size_t size);

/* MoQiOS-specific environment/directory calls (non-POSIX signatures).
 * moqi_setenv takes a "KEY=VALUE" string; moqi_getenv copies the value
 * into caller storage and returns its length (negative on miss). */
long moqi_setenv(const char *kvp);
long moqi_getenv(const char *key, char *val, long max);
long moqi_listdir(char *buf, size_t size);

#endif /* MOQI_UNISTD_H */
