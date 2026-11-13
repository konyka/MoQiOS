/* hello299: splice and sendfile read a file as read() does, including what another descriptor wrote a moment ago.
 * Measured on the host (build with -DHOST; both labels use /tmp there): a descriptor opened on an empty file, then grown through a
 * second descriptor, splices the new bytes (A) and sendfile sends them (B); bytes overwritten in the middle through the second
 * descriptor are what splice reads (C); splice from past the new end returns 0 (D). Run on the target for ext2 and FAT32, whose
 * writes stay staged in the writeback cache for a while. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long spl(long in, long long *oin, long out, long len) {
    long r = syscall(SYS_splice, in, oin, out, 0, len, 0);
    return r < 0 ? -errno : r;
}
static long sfile(long out, long in, long long *off, long n) {
    long r = syscall(SYS_sendfile, out, in, off, n);
    return r < 0 ? -errno : r;
}
#define EXT2_PATH "/tmp/h299e"
#define FAT_PATH "/tmp/h299f"
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
static long spl(long in, long long *oin, long out, long len) { return syscall6(145, in, (long)oin, out, 0, len, 0); }
static long sfile(long out, long in, long long *off, long n) { return syscall4(144, out, in, (long)off, n); }
#define EXT2_PATH "testdir/h299e"
#define FAT_PATH "h299f"
#endif

static int failures;
static char what[200];
static void check(int ok, const char *w) {
    print(ok ? "hello299:   ok   " : "hello299:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rd(int fd, char *b, long n) {
    memset(b, 0, (unsigned long)n);
    return read(fd, b, (unsigned long)n - 1);
}

static void one(const char *label, const char *path, int p[2]) {
    char b[64];
    unlink(path);
    int w = (int)open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    int r = (int)open(path, O_RDONLY, 0);
    write(w, "hello world", 11);

    long long off = 0;
    long n = spl(r, &off, p[1], 32);
    long got = rd(p[0], b, sizeof b);
    snprintf(what, sizeof what, "%s A: splice from a descriptor opened before the write sees the 11 new bytes (%ld, \"%s\", off %lld)", label, n, b, off);
    check(n == 11 && got == 11 && memcmp(b, "hello world", 11) == 0 && off == 11, what);

    off = 6;
    n = sfile(p[1], r, &off, 32);
    got = rd(p[0], b, sizeof b);
    snprintf(what, sizeof what, "%s B: sendfile from offset 6 sends \"world\" (%ld, \"%s\")", label, n, b);
    check(n == 5 && got == 5 && memcmp(b, "world", 5) == 0, what);

    pwrite(w, "WORLD", 5, 6);
    off = 0;
    n = spl(r, &off, p[1], 32);
    got = rd(p[0], b, sizeof b);
    snprintf(what, sizeof what, "%s C: bytes overwritten through the other descriptor are what splice reads (%ld, \"%s\")", label, n, b);
    check(n == 11 && got == 11 && memcmp(b, "hello WORLD", 11) == 0, what);

    off = 11;
    n = spl(r, &off, p[1], 32);
    snprintf(what, sizeof what, "%s D: splice at the new end returns 0 (%ld)", label, n);
    check(n == 0, what);

    close(r);
    close(w);
    unlink(path);
}

int main(void) {
    print("hello299: splice and sendfile see staged writes\n");
    int p[2];
    if (pipe(p) != 0) {
        print("hello299: FAIL (pipe)\n");
        return 1;
    }
    fcntl(p[0], F_SETFL, O_NONBLOCK);
    one("ext2", EXT2_PATH, p);
    one("FAT32", FAT_PATH, p);
    close(p[0]);
    close(p[1]);
    print(failures == 0 ? "hello299: PASS\n" : "hello299: FAIL\n");
    return failures;
}
