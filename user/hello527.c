/* hello527: a pipe write whose source runs into unreadable memory, into a pipe that already holds data (Linux 7.2 anon_pipe_write,
 * measured). The write's remainder (its length modulo 4096) first goes into the pipe's last buffer when that buffer has room for
 * it; a fault in that copy is EFAULT for the whole write. Then the bytes fill fresh pages, and a page that faults is dropped. A: with
 * 100 bytes already in the pipe, writes of 4112, 5016, 8207 and 8208 bytes of which 4096, 5000, 8191 and 8192 can be read take 16,
 * 920, 4111 and 4112; B: with 4096 bytes in it (a full last buffer, no merge) the same writes take 4096, 4096, 4096 and 8192, as in
 * an empty pipe; C: with 4000 bytes in it, 4016 bytes of which 4000 can be read are EFAULT and 5016 of which 5000 can take 4096; D:
 * writev of the same source in two iovecs takes the same as write. Measured with -DHOST. */
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
static long wr(int fd, const void *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wv(int fd, const struct iovec *v, int n) { long r = writev(fd, v, n); return r < 0 ? -errno : r; }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static int mkpipe(int p[2]) { return pipe2(p, O_NONBLOCK); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/mman.h"
#include "../lib/moqi_libc/include/fcntl.h"
static long wr(int fd, const void *b, long n) { return syscall3(SYS_write, fd, (long)b, n); }
static long wv(int fd, const struct iovec *v, int n) { return syscall3(139, fd, (long)v, n); }
static long rd(int fd, void *b, long n) { return syscall3(SYS_read, fd, (long)b, n); }
static int mkpipe(int p[2]) { return (int)syscall2(SYS_pipe2, (long)p, 0x800); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello527:   ok   " : "hello527:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static char *hole; /* the first unreadable byte: four readable pages end here */
static char big[16384];
/* write (or writev in two pieces) `total` bytes that start `good` bytes before the hole into a pipe holding `pre` bytes. */
static long one(int pre, int good, int total, int vec) {
    int p[2];
    if (mkpipe(p) != 0) return -1000;
    memset(big, 'p', sizeof big);
    if (pre && wr(p[1], big, pre) != pre) return -1001;
    long r;
    if (vec) {
        struct iovec v[2] = {{hole - good, 10}, {hole - good + 10, (size_t)(total - 10)}};
        r = wv(p[1], v, 2);
    } else {
        r = wr(p[1], hole - good, total);
    }
    long held = 0, k;
    while ((k = rd(p[0], big, sizeof big)) > 0) held += k;
    close(p[0]);
    close(p[1]);
    if (r > 0 && held != pre + r) return -2000;
    return r;
}
int main(void) {
    print("hello527: pipe writes into a hole when the pipe holds data\n");
    char *m = (char *)mmap(0, 8 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) {
        print("hello527: FAIL\n");
        return 1;
    }
    memset(m, 'x', 8 * 4096);
    hole = m + 4 * 4096;
    munmap(hole, 4096);
    long a1 = one(100, 4096, 4112, 0), a2 = one(100, 5000, 5016, 0), a3 = one(100, 8191, 8207, 0), a4 = one(100, 8192, 8208, 0);
    snprintf(msg, sizeof msg, "A: 100 bytes in the pipe: %ld %ld %ld %ld (16 920 4111 4112)", a1, a2, a3, a4);
    check(a1 == 16 && a2 == 920 && a3 == 4111 && a4 == 4112, msg);
    long b1 = one(4096, 4096, 4112, 0), b2 = one(4096, 5000, 5016, 0), b3 = one(4096, 8191, 8207, 0), b4 = one(4096, 8192, 8208, 0);
    snprintf(msg, sizeof msg, "B: a full page in the pipe: %ld %ld %ld %ld (4096 4096 4096 8192)", b1, b2, b3, b4);
    check(b1 == 4096 && b2 == 4096 && b3 == 4096 && b4 == 8192, msg);
    long c1 = one(4000, 4000, 4016, 0), c2 = one(4000, 5000, 5016, 0), c3 = one(100, 100, 116, 0);
    snprintf(msg, sizeof msg, "C: 4000 in the pipe, 4000 of 4016 readable %ld, 5000 of 5016 %ld; 100 in it, 100 of 116 %ld (-14 4096 -14)", c1, c2, c3);
    check(c1 == -EFAULT && c2 == 4096 && c3 == -EFAULT, msg);
    long d1 = one(100, 5000, 5016, 1), d2 = one(4096, 5000, 5016, 1), d3 = one(4000, 4000, 4016, 1);
    snprintf(msg, sizeof msg, "D: writev in two pieces: %ld %ld %ld (920 4096 -14)", d1, d2, d3);
    check(d1 == 920 && d2 == 4096 && d3 == -EFAULT, msg);
    print(failures ? "hello527: FAIL\n" : "hello527: PASS\n");
    return failures ? 1 : 0;
}
