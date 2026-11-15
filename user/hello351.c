/* hello351: one read(), write(), readv() or writev() larger than 4 KiB on a shared open file description covers one contiguous
 * range (Linux holds f_pos_lock for the whole call). Measured on the host (build with -DHOST):
 *   A. a parent and a forked child each write 24 blocks of 16 KiB through one description; every 16 KiB block of the result is
 *      one writer's block, whole, over 8 rounds;
 *   B. the same with writev of four 4 KiB pieces per block;
 *   C. a parent and a forked child each read 16 KiB at a time from a file whose 4-byte words are their own index; every read
 *      returns consecutive words, and together they read every word once, over 8 rounds;
 *   D. the same with readv of four 4 KiB pieces. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wr(int fd, const void *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long rdv(int fd, struct iovec *v, int n) { long r = readv(fd, v, n); return r < 0 ? -errno : r; }
static long wrv(int fd, struct iovec *v, int n) { long r = writev(fd, v, n); return r < 0 ? -errno : r; }
static long opn(const char *p, long fl) { long r = open(p, (int)fl, 0644); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rd(int fd, void *b, long n) { return read(fd, b, (size_t)n); }
static long wr(int fd, const void *b, long n) { return write(fd, b, (size_t)n); }
static long rdv(int fd, struct iovec *v, int n) { return syscall3(19, fd, (long)v, n); }
static long wrv(int fd, struct iovec *v, int n) { return syscall3(20, fd, (long)v, n); }
static long opn(const char *p, long fl) { return open(p, fl, 0644); }
#endif
#define PATH "/tmp/hello351.dat"
#define BLK 16384
#define NBLK 24
#define ROUNDS 8
#define WORDS (2 * NBLK * BLK / 4)

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello351:   ok   " : "hello351:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned int blk[BLK / 4];
static unsigned char seen[WORDS / 8];
static unsigned char other[WORDS / 8];

static long xfer(int fd, void *b, int vec, int is_write) {
    if (!vec) return is_write ? wr(fd, b, BLK) : rd(fd, b, BLK);
    struct iovec v[4];
    for (int i = 0; i < 4; i++) { v[i].iov_base = (char *)b + i * (BLK / 4); v[i].iov_len = BLK / 4; }
    return is_write ? wrv(fd, v, 4) : rdv(fd, v, 4);
}
static int full(int fd, void *b, long n, int w) {
    char *p = b;
    while (n > 0) {
        long r = w ? wr(fd, p, n) : rd(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= r;
    }
    return 0;
}
/* Fork with a start line: the child says it is running and waits for the parent's go, so both start their calls together. */
static long fork_together(void) {
    int ready[2], go[2];
    if (pipe(ready) != 0) return -1;
    if (pipe(go) != 0) return -1;
    long child = fork();
    char c = 0;
    if (child == 0) {
        wr(ready[1], &c, 1);
        rd(go[0], &c, 1);
    } else {
        rd(ready[0], &c, 1);
        wr(go[1], &c, 1);
    }
    close(ready[0]); close(ready[1]); close(go[0]); close(go[1]);
    return child;
}
/* Rounds of two writers: 0 when every 16 KiB block of the file is one writer's block, whole, and each block appears once. */
static int write_round(int vec) {
    long fd = opn(PATH, 2 | 0x40 | 0x200);
    if (fd < 0) return 1;
    long child = fork_together();
    int tag = child == 0 ? 2 : 1;
    int err = 0;
    for (unsigned int b = 0; b < NBLK; b++) {
        for (unsigned int i = 0; i < BLK / 4; i++) blk[i] = ((unsigned int)tag << 28) | (b << 12) | i;
        if (xfer((int)fd, blk, vec, 1) != BLK) err = 1;
    }
    if (child == 0) _exit(err);
    int ws = 0;
    waitpid(child, &ws, 0);
    if (ws != 0) err = 1;
    long size = lseek((int)fd, 0, 2);
    if (size != 2L * NBLK * BLK) err = 1;
    lseek((int)fd, 0, 0);
    unsigned int got1 = 0, got2 = 0;
    for (int k = 0; k < 2 * NBLK && !err; k++) {
        if (full((int)fd, blk, BLK, 0) != 0) { err = 1; break; }
        unsigned int t = blk[0] >> 28, b = (blk[0] >> 12) & 0xFFFF;
        for (unsigned int i = 0; i < BLK / 4; i++)
            if (blk[i] != ((t << 28) | (b << 12) | i)) { err = 1; break; }
        if (b >= NBLK) err = 1;
        else if (t == 1) got1 |= 1u << b;
        else if (t == 2) got2 |= 1u << b;
        else err = 1;
    }
    if (got1 != (1u << NBLK) - 1 || got2 != (1u << NBLK) - 1) err = 1;
    close((int)fd);
    return err;
}
/* Rounds of two readers: 0 when every read returned consecutive words and the two together read every word exactly once. */
static int read_round(long fd, int vec) {
    lseek((int)fd, 0, 0);
    memset(seen, 0, sizeof seen);
    int p[2];
    if (pipe(p) != 0) return 1;
    long child = fork_together();
    int bad = 0;
    for (;;) {
        long r = xfer((int)fd, blk, vec, 0);
        if (r <= 0) break;
        if (r != BLK) bad = 1;
        unsigned int base = blk[0];
        for (long i = 0; i < r / 4; i++) {
            if (blk[i] != base + (unsigned int)i) bad = 1;
            if (blk[i] < WORDS) seen[blk[i] / 8] |= (unsigned char)(1u << (blk[i] % 8));
        }
    }
    if (child == 0) {
        close(p[0]);
        full(p[1], &bad, sizeof bad, 1);
        full(p[1], seen, sizeof seen, 1);
        _exit(0);
    }
    close(p[1]);
    int theirs = 1;
    if (full(p[0], &theirs, sizeof theirs, 0) != 0 || full(p[0], other, sizeof other, 0) != 0) theirs = 1;
    close(p[0]);
    int ws = 0;
    waitpid(child, &ws, 0);
    int dups = 0, count = 0;
    for (int i = 0; i < WORDS / 8; i++) {
        for (int b = 0; b < 8; b++) {
            dups += (seen[i] >> b) & (other[i] >> b) & 1;
            count += ((seen[i] | other[i]) >> b) & 1;
        }
    }
    return bad || theirs || dups || count != WORDS;
}

int main(void) {
    print("hello351: a read or write larger than 4 KiB on a shared description covers one contiguous range\n");
    int a = 0, b = 0, c = 0, d = 0;
    for (int r = 0; r < ROUNDS; r++) a += write_round(0);
    snprintf(msg, sizeof msg, "A: two writers' 16 KiB write() calls never interleave (%d of %d rounds wrong)", a, ROUNDS);
    check(a == 0, msg);
    for (int r = 0; r < ROUNDS; r++) b += write_round(1);
    snprintf(msg, sizeof msg, "B: two writers' 4 x 4 KiB writev() calls never interleave (%d of %d rounds wrong)", b, ROUNDS);
    check(b == 0, msg);

    long fd = opn(PATH, 2 | 0x40 | 0x200);
    int prep = fd < 0;
    for (unsigned int k = 0; k < 2 * NBLK && !prep; k++) {
        for (unsigned int i = 0; i < BLK / 4; i++) blk[i] = k * (BLK / 4) + i;
        if (full((int)fd, blk, BLK, 1) != 0) prep = 1;
    }
    check(!prep, "write the 768 KiB numbered file");
    for (int r = 0; r < ROUNDS && !prep; r++) c += read_round(fd, 0);
    snprintf(msg, sizeof msg, "C: two readers' 16 KiB read() calls each get consecutive words, every word once (%d of %d rounds wrong)", c, ROUNDS);
    check(!prep && c == 0, msg);
    for (int r = 0; r < ROUNDS && !prep; r++) d += read_round(fd, 1);
    snprintf(msg, sizeof msg, "D: two readers' 4 x 4 KiB readv() calls each get consecutive words, every word once (%d of %d rounds wrong)", d, ROUNDS);
    check(!prep && d == 0, msg);
    if (fd >= 0) close((int)fd);
    unlink(PATH);

    print(failures ? "hello351: FAIL\n" : "hello351: PASS\n");
    return failures ? 1 : 0;
}
