/* hello354: copy_file_range with offset pointers reads and writes at those offsets and leaves the descriptors' shared offsets
 * alone (Linux passes &pos to the copy, f_pos is untouched). Measured on the host (build with -DHOST):
 *   A. while a parent makes 3000 copy_file_range calls from one shared description at offsets of its own (off_in, off_out given),
 *      a forked child reading the same description 4 bytes at a time sees all 4096 records once, in order;
 *   B. every copy lands the records from its off_in at its off_out, and *off_in / *off_out advance by the bytes copied;
 *   C. afterwards the shared offset is where the child left it (16384, the file size);
 *   D. with NULL offset pointers the copy uses and advances the descriptors' offsets (fd_in at 64 after copying 64 bytes). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wr(int fd, const void *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long opn(const char *p, long fl) { long r = open(p, (int)fl, 0644); return r < 0 ? -errno : r; }
static long cfr(int in, long long *oi, int out, long long *oo, long n) {
    long r = syscall(SYS_copy_file_range, in, oi, out, oo, n, 0);
    return r < 0 ? -errno : r;
}
static long prd(int fd, void *b, long n, long off) { long r = pread(fd, b, (size_t)n, off); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rd(int fd, void *b, long n) { return read(fd, b, (size_t)n); }
static long wr(int fd, const void *b, long n) { return write(fd, b, (size_t)n); }
static long opn(const char *p, long fl) { return open(p, fl, 0644); }
static long cfr(int in, long long *oi, int out, long long *oo, long n) { return syscall6(184, in, (long)oi, out, (long)oo, n, 0); }
static long prd(int fd, void *b, long n, long off) { return syscall4(17, fd, (long)b, n, off); }
#endif
#define PATH "/tmp/hello354.dat"
#define OUT "/tmp/hello354.out"
#define NREC 4096
#define OPS 3000

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello354:   ok   " : "hello354:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
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
int main(void) {
    print("hello354: copy_file_range with offset pointers leaves the shared file offset alone\n");
    long fd = opn(PATH, 2 | 0x40 | 0x200);
    long out = opn(OUT, 2 | 0x40 | 0x200);
    static unsigned int recs[NREC];
    for (unsigned int i = 0; i < NREC; i++) recs[i] = i;
    int prep = fd < 0 || out < 0 || full((int)fd, recs, sizeof recs, 1) != 0;
    snprintf(msg, sizeof msg, "open %s and %s, write 4096 records (fd %ld, out %ld)", PATH, OUT, fd, out);
    check(!prep, msg);
    if (prep) { print("hello354: FAIL\n"); return 1; }
    lseek((int)fd, 0, 0);

    int p[2];
    if (pipe(p) != 0) { print("hello354: FAIL\n"); return 1; }
    long child = fork_together();
    if (child == 0) {
        close(p[0]);
        int count = 0, ordered = 1;
        unsigned int v, want = 0;
        while (rd((int)fd, &v, 4) == 4) {
            if (v != want) ordered = 0;
            want = v + 1;
            count++;
        }
        full(p[1], &count, sizeof count, 1);
        full(p[1], &ordered, sizeof ordered, 1);
        _exit(0);
    }
    close(p[1]);
    int wrong = 0, errs = 0, bad_ptr = 0;
    for (int k = 0; k < OPS; k++) {
        unsigned int at = (unsigned int)((k * 37) % (NREC - 16));
        long long oi = (long long)at * 4, oo = (long long)(k % 256) * 64;
        long r = cfr((int)fd, &oi, (int)out, &oo, 64);
        if (r != 64) { errs++; continue; }
        if (oi != (long long)at * 4 + 64 || oo != (long long)(k % 256) * 64 + 64) bad_ptr++;
        unsigned int got[16];
        if (prd((int)out, got, sizeof got, (long)(k % 256) * 64) != (long)sizeof got) { wrong++; continue; }
        for (int i = 0; i < 16; i++) if (got[i] != at + (unsigned int)i) { wrong++; break; }
    }
    int count = -1, ordered = 0;
    if (full(p[0], &count, sizeof count, 0) != 0 || full(p[0], &ordered, sizeof ordered, 0) != 0) count = -1;
    close(p[0]);
    int ws = 0;
    waitpid(child, &ws, 0);
    long end = lseek((int)fd, 0, 1);

    snprintf(msg, sizeof msg, "A: the child reads all 4096 records once, in order, while the copies run (read %d, in order %d)", count, ordered);
    check(count == NREC && ordered, msg);
    snprintf(msg, sizeof msg, "B: each copy moves its own records and advances *off_in, *off_out (%d wrong, %d bad pointers, %d failed of %d)",
             wrong, bad_ptr, errs, OPS);
    check(wrong == 0 && bad_ptr == 0 && errs == 0, msg);
    snprintf(msg, sizeof msg, "C: the shared offset is where the child left it (%ld, want %d)", end, NREC * 4);
    check(end == NREC * 4, msg);

    lseek((int)fd, 0, 0);
    lseek((int)out, 0, 0);
    long r = cfr((int)fd, 0, (int)out, 0, 64);
    long in_pos = lseek((int)fd, 0, 1), out_pos = lseek((int)out, 0, 1);
    snprintf(msg, sizeof msg, "D: NULL offset pointers use and advance the descriptors' offsets (rc %ld, in %ld, out %ld, want 64)", r, in_pos, out_pos);
    check(r == 64 && in_pos == 64 && out_pos == 64, msg);

    close((int)fd);
    close((int)out);
    unlink(PATH);
    unlink(OUT);
    print(failures ? "hello354: FAIL\n" : "hello354: PASS\n");
    return failures ? 1 : 0;
}
