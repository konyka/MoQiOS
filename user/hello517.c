/* hello517: writev(), pwritev() and pwritev2() whose source runs into unreadable memory (Linux: the readable part is written and the
 * call is a short write; nothing readable at the start is EFAULT, never 0). A file takes the readable prefix byte by byte: {good 8,
 * bad 8} writes 8, {bad 8, good 8} is EFAULT, one iovec that straddles a hole writes the bytes before it. A pipe takes a write in
 * whole pages of the source only: {good 8, bad 8} is EFAULT, {good page, bad 8} takes the page. readv() and preadv() into a bad
 * buffer after a good one read into the good one; a bad first buffer is EFAULT. Measured with -DHOST. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rv(int fd, const struct iovec *v, int n) { long r = readv(fd, v, n); return r < 0 ? -errno : r; }
static long wv(int fd, const struct iovec *v, int n) { long r = writev(fd, v, n); return r < 0 ? -errno : r; }
static long prv(int fd, const struct iovec *v, int n, long off) { long r = preadv(fd, v, n, off); return r < 0 ? -errno : r; }
static long pwv(int fd, const struct iovec *v, int n, long off) { long r = pwritev(fd, v, n, off); return r < 0 ? -errno : r; }
static long pwv2(int fd, const struct iovec *v, int n, long off) { long r = pwritev2(fd, v, n, off, 0); return r < 0 ? -errno : r; }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static void *anon(long n, int prot) { void *p = mmap(0, (size_t)n, prot, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); return p == MAP_FAILED ? 0 : p; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/mman.h"
static long rv(int fd, const struct iovec *v, int n) { return syscall3(138, fd, (long)v, n); }
static long wv(int fd, const struct iovec *v, int n) { return syscall3(139, fd, (long)v, n); }
static long prv(int fd, const struct iovec *v, int n, long off) { return syscall4(140, fd, (long)v, n, off); }
static long pwv(int fd, const struct iovec *v, int n, long off) { return syscall4(141, fd, (long)v, n, off); }
static long pwv2(int fd, const struct iovec *v, int n, long off) { long r = pwritev2(fd, v, n, off, 0); return r < 0 ? -errno : r; }
static long rd(int fd, void *b, long n) { return syscall3(SYS_read, fd, (long)b, n); }
static void *anon(long n, int prot) { void *p = mmap(0, (size_t)n, prot, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); return p == MAP_FAILED ? 0 : p; }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello517:   ok   " : "hello517:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
#define BAD ((void *)0x7f0000000000UL)
#define PATH "/tmp/hello517.tmp"
static char good[17] = "0123456789abcdef";
static char *hole_page; /* a readable page followed by an unmapped one */

/* `f` on a fresh empty file, then the file's contents in `out` (up to 32 bytes); returns f's result. */
static long on_file(long (*f)(int), char *out) {
    int fd = (int)open(PATH, 0x42 /* O_RDWR|O_CREAT */ | 0x200 /* O_TRUNC */, 0600);
    if (fd < 0) return -1000;
    long r = f(fd);
    memset(out, 0, 33);
    lseek(fd, 0, 0);
    rd(fd, out, 32);
    close(fd);
    unlink(PATH);
    return r;
}
static long w_good_bad(int fd) { struct iovec v[2] = {{good, 8}, {BAD, 8}}; return wv(fd, v, 2); }
static long w_bad_good(int fd) { struct iovec v[2] = {{BAD, 8}, {good, 8}}; return wv(fd, v, 2); }
static long w_straddle(int fd) { struct iovec v[2] = {{good + 8, 2}, {hole_page + 4096 - 4, 8}}; return wv(fd, v, 2); }
static long p_good_bad(int fd) { struct iovec v[2] = {{good, 8}, {BAD, 8}}; return pwv(fd, v, 2, 0); }
static long p_bad_good(int fd) { struct iovec v[2] = {{BAD, 8}, {good, 8}}; return pwv(fd, v, 2, 0); }
static long p_straddle(int fd) { struct iovec v[1] = {{hole_page + 4096 - 4, 8}}; return pwv(fd, v, 1, 0); }
static long p2_good_bad(int fd) { struct iovec v[2] = {{good, 8}, {BAD, 8}}; return pwv2(fd, v, 2, 0); }
static long p2_bad_good(int fd) { struct iovec v[2] = {{BAD, 8}, {good, 8}}; return pwv2(fd, v, 2, -1); }

/* writev `v` into a fresh empty pipe; the result, and how many bytes the pipe then holds in *held. */
static long on_pipe(const struct iovec *v, int n, long *held) {
    int p[2];
    if (pipe(p) != 0) return -1000;
    long r = wv(p[1], v, n);
    static char sink[16384];
    *held = 0;
    if (r > 0) *held = rd(p[0], sink, sizeof sink);
    close(p[0]);
    close(p[1]);
    return r;
}

int main(void) {
    print("hello517: writev/pwritev from unreadable memory\n");
    char *two = (char *)anon(8192, PROT_READ | PROT_WRITE);
    if (!two) {
        print("hello517: FAIL\n");
        return 1;
    }
    memset(two, 'h', 8192);
    munmap(two + 4096, 4096);
    hole_page = two;
    char c[33];

    long a1 = on_file(w_good_bad, c);
    int a1ok = a1 == 8 && strcmp(c, "01234567") == 0;
    long a2 = on_file(w_bad_good, c);
    int a2ok = a2 == -EFAULT && c[0] == 0;
    long a3 = on_file(w_straddle, c);
    int a3ok = a3 == 6 && strcmp(c, "89hhhh") == 0;
    snprintf(msg, sizeof msg, "A: file writev {good 8, bad 8} %ld, {bad, good} %ld, {good 2, straddling a hole} %ld '%s' (8 -14 6 89hhhh)", a1, a2, a3, c);
    check(a1ok && a2ok && a3ok, msg);

    long b1 = on_file(p_good_bad, c);
    int b1ok = b1 == 8 && strcmp(c, "01234567") == 0;
    long b2 = on_file(p_bad_good, c);
    long b3 = on_file(p_straddle, c);
    int b3ok = b3 == 4 && strcmp(c, "hhhh") == 0;
    snprintf(msg, sizeof msg, "B: file pwritev {good 8, bad 8} %ld, {bad, good} %ld, straddling a hole %ld (8 -14 4)", b1, b2, b3);
    check(b1ok && b2 == -EFAULT && b3ok, msg);

    long e1 = on_file(p2_good_bad, c);
    int e1ok = e1 == 8 && strcmp(c, "01234567") == 0;
    long e2 = on_file(p2_bad_good, c);
    snprintf(msg, sizeof msg, "E: file pwritev2 {good 8, bad 8} at 0 %ld, {bad, good} at -1 %ld (8 -14)", e1, e2);
    check(e1ok && e2 == -EFAULT, msg);

    long h1, h2, h3;
    struct iovec c1[2] = {{good, 8}, {BAD, 8}};
    struct iovec c2[2] = {{BAD, 8}, {good, 8}};
    struct iovec c3[2] = {{two, 4096}, {BAD, 8}};
    long r1 = on_pipe(c1, 2, &h1);
    long r2 = on_pipe(c2, 2, &h2);
    long r3 = on_pipe(c3, 2, &h3);
    snprintf(msg, sizeof msg, "C: pipe writev {good 8, bad 8} %ld, {bad, good} %ld, {good page, bad 8} %ld holding %ld (-14 -14 4096 4096)", r1, r2, r3, h3);
    check(r1 == -EFAULT && r2 == -EFAULT && r3 == 4096 && h3 == 4096, msg);

    int fd = (int)open(PATH, 0x42 | 0x200, 0600);
    long d1 = -1, d2 = -1, d3 = -1;
    char in[8];
    if (fd >= 0) {
        write(fd, "YYYYYYYYYYYYYYYY", 16);
        struct iovec gb[2] = {{in, 8}, {BAD, 8}};
        struct iovec bg[2] = {{BAD, 8}, {in, 8}};
        lseek(fd, 0, 0);
        d1 = rv(fd, gb, 2);
        lseek(fd, 0, 0);
        d2 = rv(fd, bg, 2);
        d3 = prv(fd, gb, 2, 0);
        close(fd);
        unlink(PATH);
    }
    snprintf(msg, sizeof msg, "D: file readv {good 8, bad 8} %ld, {bad, good} %ld, preadv {good, bad} %ld (8 -14 8)", d1, d2, d3);
    check(d1 == 8 && d2 == -EFAULT && d3 == 8, msg);

    /* F: the iovec array is checked whole before anything moves: a NULL base is not skipped (it faults when the copy reaches it), a
     * base outside user space is EFAULT for the call, a negative length EINVAL, and no iovecs at all is 0. */
    long f1 = -1, f2 = -1, f3 = -1, f4 = -1, f5 = -1, f6 = -1;
    fd = (int)open(PATH, 0x42 | 0x200, 0600);
    if (fd >= 0) {
        struct iovec ng[2] = {{0, 8}, {good, 8}};
        struct iovec gk[2] = {{good, 8}, {(void *)0xffff800000000000UL, 8}};
        struct iovec gneg[2] = {{good, 8}, {good, (size_t)1 << 63}};
        f1 = wv(fd, ng, 2);
        f2 = wv(fd, gk, 2);
        f3 = wv(fd, gneg, 2);
        f4 = wv(fd, gk, 0);
        lseek(fd, 0, 0);
        write(fd, "ZZZZZZZZZZZZZZZZ", 16);
        lseek(fd, 0, 0);
        struct iovec rng[2] = {{0, 8}, {in, 8}};
        struct iovec rgk[2] = {{in, 8}, {(void *)0xffff800000000000UL, 8}};
        f5 = rv(fd, rng, 2);
        f6 = rv(fd, rgk, 2);
        close(fd);
        unlink(PATH);
    }
    snprintf(msg, sizeof msg, "F: writev {NULL, good} %ld, {good, kernel} %ld, {good, len<0} %ld, 0 iovecs %ld; readv {NULL, good} %ld, {good, kernel} %ld (-14 -14 -22 0 -14 -14)", f1, f2, f3, f4, f5, f6);
    check(f1 == -EFAULT && f2 == -EFAULT && f3 == -EINVAL && f4 == 0 && f5 == -EFAULT && f6 == -EFAULT, msg);
    print(failures ? "hello517: FAIL\n" : "hello517: PASS\n");
    return failures ? 1 : 0;
}
