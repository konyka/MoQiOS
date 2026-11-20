/* hello457: /dev/random and /dev/urandom reads and writes (Linux random_read_iter / urandom_read_iter fill the whole request, and
 * random_write_iter → write_pool_user takes any amount, mixing it into the pool). Measured on the host (build with -DHOST):
 *   R. a 5000-byte read of /dev/urandom and of /dev/random returns 5000, and the bytes are not all zero; a 100000-byte read of
 *      /dev/urandom returns 100000;
 *   W. opened O_RDWR, a 5000-byte write returns 5000 and a 0-byte write 0, on both; a write on a read-only descriptor is EBADF;
 *   S. reads after the writes still return their full length. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long open_(const char *p, int f) { return rc(open(p, f)); }
static long read_(long fd, void *b, long n) { return rc(read((int)fd, b, (size_t)n)); }
static long write_(long fd, const void *b, long n) { return rc(write((int)fd, b, (size_t)n)); }
static void close_(long fd) { close((int)fd); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long open_(const char *p, int f) { return syscall3(9, (long)p, f, 0); }
static long read_(long fd, void *b, long n) { return syscall3(SYS_read, fd, (long)b, n); }
static long write_(long fd, const void *b, long n) { return syscall3(SYS_write, fd, (long)b, n); }
static void close_(long fd) { syscall1(11, fd); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello457:   ok   " : "hello457:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char big[100000];
static int nonzero(const unsigned char *b, long n) {
    for (long i = 0; i < n; i++) if (b[i]) return 1;
    return 0;
}
int main(void) {
    print("hello457: /dev/random and /dev/urandom reads and writes\n");
    long u = open_("/dev/urandom", 0), r = open_("/dev/random", 0);
    memset(big, 0, sizeof big);
    long ru = read_(u, big, 5000);
    int nzu = nonzero(big, 5000);
    memset(big, 0, sizeof big);
    long rr = read_(r, big, 5000);
    int nzr = nonzero(big, 5000);
    long rb = read_(u, big, 100000);
    snprintf(msg, sizeof msg, "R: urandom 5000: %ld nonzero %d; random 5000: %ld nonzero %d; urandom 100000: %ld (5000 1 5000 1 100000)", ru, nzu, rr, nzr, rb);
    check(ru == 5000 && nzu && rr == 5000 && nzr && rb == 100000, msg);

    long uw = open_("/dev/urandom", 2), rw = open_("/dev/random", 2);
    memset(big, 7, 5000);
    long w1 = write_(uw, big, 5000), w2 = write_(uw, big, 0), w3 = write_(rw, big, 5000), w4 = write_(rw, big, 0);
    long w5 = write_(u, big, 10);
    snprintf(msg, sizeof msg, "W: urandom write 5000 %ld, 0 %ld; random write 5000 %ld, 0 %ld; read-only write %ld (5000 0 5000 0 -9)", w1, w2, w3, w4, w5);
    check(uw >= 0 && rw >= 0 && w1 == 5000 && w2 == 0 && w3 == 5000 && w4 == 0 && w5 == -9, msg);

    long s1 = read_(uw, big, 3000), s2 = read_(rw, big, 3000);
    snprintf(msg, sizeof msg, "S: reads after the writes: %ld %ld (3000 3000)", s1, s2);
    check(s1 == 3000 && s2 == 3000, msg);

    close_(u);
    close_(r);
    close_(uw);
    close_(rw);
    print(failures ? "hello457: FAIL\n" : "hello457: PASS\n");
    return failures ? 1 : 0;
}
