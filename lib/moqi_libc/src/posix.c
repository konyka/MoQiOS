/* posix.c — process identity, alarm/pause, isatty, remove/rename/rmdir and perror (see include/unistd.h, include/stdio.h).
 *
 * These follow the POSIX convention: 0 or a value on success, -1 with errno on failure. The identity calls cannot fail.
 */
#include "../include/stdio.h"
#include "../include/string.h"
#include "../include/unistd.h"
#include "hostsys.h"

unsigned int getuid(void) { return (unsigned int)MSYS0(SYS_getuid); }
unsigned int geteuid(void) { return (unsigned int)MSYS0(SYS_geteuid); }
unsigned int getgid(void) { return (unsigned int)MSYS0(SYS_getgid); }
unsigned int getegid(void) { return (unsigned int)MSYS0(SYS_getegid); }
int getppid(void) { return (int)MSYS0(SYS_getppid); }

unsigned int alarm(unsigned int seconds) {
    return (unsigned int)MSYS1(SYS_alarm, seconds);
}

int pause(void) {
    return __moqi_ret(MSYS0(SYS_pause));
}

#define TCGETS 0x5401

int isatty(int fd) {
    /* The kernel answers a terminal request on a descriptor that is not a terminal with ENOTTY; the termios it fills in is 36
     * bytes (the buffer is larger for headroom). */
    unsigned char termios[64];
    long r = MSYS3(SYS_ioctl, fd, TCGETS, termios);
    if (!__moqi_is_error(r)) return 1;
    errno = (int)-r;
    return 0;
}

long rmdir(const char *path) {
    return MSYS1(SYS_rmdir, path);
}

int rename(const char *oldpath, const char *newpath) {
    return __moqi_ret(MSYS2(SYS_rename, oldpath, newpath));
}

/* A file is unlinked, a directory is removed: unlink says EISDIR for a directory, and then the directory is removed instead. */
int remove(const char *path) {
    long r = MSYS1(SYS_unlink, path);
    if (r == -EISDIR) r = MSYS1(SYS_rmdir, path);
    return __moqi_ret(r);
}

/* One write of "<s>: <message>\n" (or just "<message>\n"), so the line cannot be torn by another thread's output; errno is the
 * same afterwards when the write succeeds. stderr is unbuffered, so nothing queued in it can be passed over. */
void perror(const char *s) {
    int saved = errno;
    const char *msg = strerror(saved);
    char buf[512];
    size_t n = 0;
    if (s != (const char *)0 && *s != '\0') {
        for (; *s && n < sizeof buf - 3; s++) buf[n++] = *s;
        buf[n++] = ':';
        buf[n++] = ' ';
    }
    for (; *msg && n < sizeof buf - 1; msg++) buf[n++] = *msg;
    buf[n++] = '\n';
    long r = MSYS3(SYS_write, STDERR_FILENO, buf, n);
    errno = __moqi_is_error(r) ? (int)-r : saved;
}
