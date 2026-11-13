/* hello298: a tmpfs file is a valid file end for splice and sendfile.
 * Measured on the host (build with -DHOST, /tmp is tmpfs there as here): A splice from a /tmp file into a pipe moves the bytes and
 * advances the file offset; B with an explicit offset it reads there, updates the offset variable and leaves the file offset alone;
 * C splice from a pipe into a /tmp file writes the bytes at the file offset; D with an explicit offset it writes there and only the
 * variable moves; E sendfile from a /tmp file into a pipe moves the bytes; F a file grown through a second descriptor is read to its
 * new end by splice from the first one; G splice at or past the end returns 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long spl(long in, long long *oin, long out, long long *oout, long len) {
    long r = syscall(SYS_splice, in, oin, out, oout, len, 0);
    return r < 0 ? -errno : r;
}
static long sfile(long out, long in, long long *off, long n) {
    long r = syscall(SYS_sendfile, out, in, off, n);
    return r < 0 ? -errno : r;
}
static long pos(int fd) { return (long)lseek(fd, 0, SEEK_CUR); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
static long spl(long in, long long *oin, long out, long long *oout, long len) {
    return syscall6(145, in, (long)oin, out, (long)oout, len, 0);
}
static long sfile(long out, long in, long long *off, long n) { return syscall4(144, out, in, (long)off, n); }
static long pos(int fd) { return lseek(fd, 0, 1); }
#endif

#define PATH "/tmp/h298"

static int failures;
static char what[200];
static void check(int ok, const char *w) {
    print(ok ? "hello298:   ok   " : "hello298:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rd(int fd, char *b, long n) {
    memset(b, 0, (unsigned long)n);
    return read(fd, b, (unsigned long)n - 1);
}

int main(void) {
    print("hello298: splice and sendfile with a tmpfs file\n");
    int p[2];
    char b[64];
    if (pipe(p) != 0) {
        print("hello298: FAIL (pipe)\n");
        return 1;
    }
    /* A failed transfer must not leave the checks waiting on an empty pipe. */
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    unlink(PATH);
    int f = (int)open(PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
    write(f, "0123456789", 10);
    lseek(f, 0, 0);

    /* A */
    long r = spl(f, 0, p[1], 0, 4);
    long n = rd(p[0], b, sizeof b);
    snprintf(what, sizeof what, "A: splice from a tmpfs file into a pipe moves 4 bytes (%ld, read %ld \"%s\", offset %ld)", r, n, b, pos(f));
    check(r == 4 && n == 4 && memcmp(b, "0123", 4) == 0 && pos(f) == 4, what);

    /* B */
    long long off = 6;
    r = spl(f, &off, p[1], 0, 3);
    n = rd(p[0], b, sizeof b);
    snprintf(what, sizeof what, "B: an explicit offset reads there and moves only the variable (%ld, \"%s\", off %lld, offset %ld)", r, b, off, pos(f));
    check(r == 3 && n == 3 && memcmp(b, "678", 3) == 0 && off == 9 && pos(f) == 4, what);

    /* C */
    write(p[1], "ab", 2);
    r = spl(p[0], 0, f, 0, 2);
    long after = pos(f);
    char c[16] = { 0 };
    pread(f, c, 10, 0);
    snprintf(what, sizeof what, "C: splice from a pipe into a tmpfs file writes at the offset (%ld, offset %ld, file \"%s\")", r, after, c);
    check(r == 2 && after == 6 && memcmp(c, "0123ab6789", 10) == 0, what);

    /* D */
    write(p[1], "XY", 2);
    off = 1;
    r = spl(p[0], 0, f, &off, 2);
    memset(c, 0, sizeof c);
    pread(f, c, 10, 0);
    snprintf(what, sizeof what, "D: an explicit output offset writes there (%ld, off %lld, offset %ld, file \"%s\")", r, off, pos(f), c);
    check(r == 2 && off == 3 && pos(f) == 6 && memcmp(c, "0XY3ab6789", 10) == 0, what);

    /* E */
    lseek(f, 0, 0);
    r = sfile(p[1], f, 0, 5);
    n = rd(p[0], b, sizeof b);
    snprintf(what, sizeof what, "E: sendfile from a tmpfs file into a pipe (%ld, \"%s\", offset %ld)", r, b, pos(f));
    check(r == 5 && n == 5 && memcmp(b, "0XY3a", 5) == 0 && pos(f) == 5, what);

    /* F */
    int g = (int)open(PATH, O_WRONLY | O_APPEND, 0);
    write(g, "QRS", 3);
    close(g);
    lseek(f, 10, 0);
    r = spl(f, 0, p[1], 0, 16);
    n = rd(p[0], b, sizeof b);
    snprintf(what, sizeof what, "F: bytes appended through another descriptor are spliced (%ld, \"%s\")", r, b);
    check(r == 3 && n == 3 && memcmp(b, "QRS", 3) == 0, what);

    /* G */
    r = spl(f, 0, p[1], 0, 16);
    off = 100;
    long r2 = spl(f, &off, p[1], 0, 16);
    snprintf(what, sizeof what, "G: splice at the end and past it returns 0 (%ld, %ld)", r, r2);
    check(r == 0 && r2 == 0, what);

    close(f);
    close(p[0]);
    close(p[1]);
    unlink(PATH);
    print(failures == 0 ? "hello298: PASS\n" : "hello298: FAIL\n");
    return failures;
}
