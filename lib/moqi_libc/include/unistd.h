/* unistd.h — thin wrappers over the MoQiOS syscall ABI (freestanding only).
 *
 * All wrappers return the raw kernel value: non-negative on success,
 * negative -errno on failure. No errno translation is performed.
 */
#ifndef MOQI_UNISTD_H
#define MOQI_UNISTD_H

#include <stddef.h>

#include "time.h"

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

/* Process environment, initialised by crt0 from the kernel's initial
 * stack (System V layout: envp array follows the NULL-terminated argv
 * array). NULL/empty when the kernel passed no environment. */
extern char **environ;

long read(int fd, void *buf, size_t count);
long write(int fd, const void *buf, size_t count);
long open(const char *path, long flags, long mode);
long close(int fd);
long lseek(int fd, long offset, int whence);
long unlink(const char *path);
long mkdir(const char *path, long mode);

long fork(void);
long execve(const char *path, char *const argv[], char *const envp[]);
long waitpid(long pid, int *status, long options);
long getpid(void);
long kill(long pid, long sig);
void _exit(int code) __attribute__((noreturn));

long setsid(void);
long setpgid(long pid, long pgid);
long getpgid(long pid);
long getsid(long pid);

/* Process identity, alarm clocks and terminals, with the POSIX convention (a failure is -1 with errno; the identity calls
 * cannot fail). alarm(n) arranges SIGALRM in n seconds, 0 cancels, and returns the whole seconds that were left on the
 * previous alarm (rounded down, 0 if none). pause() sleeps until a signal handler has run and then fails with EINTR; it never
 * returns 0. isatty(fd) is 1 for a terminal; otherwise 0 with errno ENOTTY (a descriptor that is not a terminal) or EBADF. */
unsigned int getuid(void);
unsigned int geteuid(void);
unsigned int getgid(void);
unsigned int getegid(void);
int getppid(void);
unsigned int alarm(unsigned int seconds);
int pause(void);
int isatty(int fd);

/* Removes an empty directory; the raw kernel value like unlink and mkdir above (0 or -errno, ENOTEMPTY if not empty). */
long rmdir(const char *path);

long pipe(int fds[2]);
long dup2(int oldfd, int newfd);

long yield(void);

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
