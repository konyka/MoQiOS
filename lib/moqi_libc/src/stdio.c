/* stdio.c — fd output and asprintf built on the formatting engine in format.c (freestanding only). */
#include "../include/errno.h"
#include "../include/stdio.h"
#include "../include/string.h"
#include "../include/unistd.h"

void *malloc(size_t size);

void print(const char *s) {
    write(STDOUT_FILENO, s, strlen(s));
}

/* Writes the whole chunk, continuing after a short write and retrying when interrupted. */
static int fd_sink(void *ctx, const char *data, size_t n) {
    int fd = *(int *)ctx;
    while (n) {
        long r = write(fd, data, n);
        if (r == -EINTR) continue;
        if (r < 0) return (int)-r;
        if (r == 0) return EIO;
        data += r;
        n -= (size_t)r;
    }
    return 0;
}

int vdprintf(int fd, const char *fmt, va_list ap) {
    char chunk[512];
    return __moqi_vformat(chunk, sizeof chunk, fd_sink, &fd, fmt, ap);
}

int dprintf(int fd, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vdprintf(fd, fmt, ap);
    va_end(ap);
    return n;
}

int vprintf(const char *fmt, va_list ap) {
    return vdprintf(STDOUT_FILENO, fmt, ap);
}

int printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vdprintf(STDOUT_FILENO, fmt, ap);
    va_end(ap);
    return n;
}

int putchar(int c) {
    unsigned char ch = (unsigned char)c;
    int rc = fd_sink(&(int){STDOUT_FILENO}, (const char *)&ch, 1);
    if (rc) {
        errno = rc;
        return -1;
    }
    return ch;
}

int puts(const char *s) {
    return dprintf(STDOUT_FILENO, "%s\n", s);
}

int vasprintf(char **strp, const char *fmt, va_list ap) {
    va_list again;
    va_copy(again, ap);
    int n = vsnprintf((char *)0, 0, fmt, ap);
    if (n < 0) {
        va_end(again);
        *strp = (char *)0;
        return -1;
    }
    char *p = (char *)malloc((size_t)n + 1);
    if (!p) {
        va_end(again);
        errno = ENOMEM;
        *strp = (char *)0;
        return -1;
    }
    vsnprintf(p, (size_t)n + 1, fmt, again);
    va_end(again);
    *strp = p;
    return n;
}

int asprintf(char **strp, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vasprintf(strp, fmt, ap);
    va_end(ap);
    return n;
}
