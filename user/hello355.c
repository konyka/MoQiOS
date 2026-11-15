/* hello355: splice and sendfile with an explicit offset read or write at that offset and leave the shared file offset alone
 * (Linux splice passes &offset to the file, sendfile reads at *offset; f_pos is untouched). Measured on the host (build with -DHOST):
 * while a parent makes 3000 calls on one shared description at offsets of its own, a forked child reading the same description 4
 * bytes at a time sees all 4096 records once, in order, each call moves its own records and advances its offset pointer, and the
 * shared offset ends where the child left it (16384, the file size), for
 *   A. splice file -> pipe with off_in;
 *   B. splice pipe -> file with off_out (the records written back are the ones already there);
 *   C. sendfile file -> pipe with an offset;
 *   D. with a NULL offset splice and sendfile use and advance the descriptor's offset (64 after moving 64 bytes each). */
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
static long spl(int in, long long *oi, int out, long long *oo, long n) {
    long r = syscall(SYS_splice, in, oi, out, oo, n, 0);
    return r < 0 ? -errno : r;
}
static long sfl(int out, int in, long long *off, long n) {
    long r = syscall(SYS_sendfile, out, in, off, n);
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
static long spl(int in, long long *oi, int out, long long *oo, long n) { return syscall6(145, in, (long)oi, out, (long)oo, n, 0); }
static long sfl(int out, int in, long long *off, long n) { return syscall4(40, out, in, (long)off, n); }
static long prd(int fd, void *b, long n, long off) { return syscall4(17, fd, (long)b, n, off); }
#endif
#define PATH "/tmp/hello355.dat"
#define NREC 4096
#define OPS 3000

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello355:   ok   " : "hello355:   FAIL ");
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
static long fd = -1;

static void round_of(int mode, const char *name) {
    lseek((int)fd, 0, 0);
    int p[2], q[2];
    if (pipe(p) != 0 || pipe(q) != 0) { check(0, "pipes"); return; }
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
        long long off = (long long)at * 4;
        unsigned int got[16];
        long r;
        if (mode == 1) {
            for (int i = 0; i < 16; i++) got[i] = at + (unsigned int)i;
            if (full(q[1], got, sizeof got, 1) != 0) { errs++; continue; }
            r = spl(q[0], 0, (int)fd, &off, 64);
            if (r != 64) { errs++; continue; }
            if (prd((int)fd, got, sizeof got, (long)at * 4) != (long)sizeof got) { wrong++; continue; }
        } else {
            r = mode == 0 ? spl((int)fd, &off, q[1], 0, 64) : sfl(q[1], (int)fd, &off, 64);
            if (r != 64) { errs++; continue; }
            if (full(q[0], got, sizeof got, 0) != 0) { wrong++; continue; }
        }
        if (off != (long long)at * 4 + 64) bad_ptr++;
        for (int i = 0; i < 16; i++) if (got[i] != at + (unsigned int)i) { wrong++; break; }
    }
    int count = -1, ordered = 0;
    if (full(p[0], &count, sizeof count, 0) != 0 || full(p[0], &ordered, sizeof ordered, 0) != 0) count = -1;
    close(p[0]);
    close(q[0]);
    close(q[1]);
    int ws = 0;
    waitpid(child, &ws, 0);
    long end = lseek((int)fd, 0, 1);
    snprintf(msg, sizeof msg, "%s: the child reads all 4096 records once, in order (read %d, in order %d); each call moves its own records "
             "and advances its offset (%d wrong, %d bad offsets, %d failed of %d); the shared offset ends at %ld (want %d)",
             name, count, ordered, wrong, bad_ptr, errs, OPS, end, NREC * 4);
    check(count == NREC && ordered && wrong == 0 && bad_ptr == 0 && errs == 0 && end == NREC * 4, msg);
}

int main(void) {
    print("hello355: splice and sendfile with an explicit offset leave the shared file offset alone\n");
    fd = opn(PATH, 2 | 0x40 | 0x200);
    static unsigned int recs[NREC];
    for (unsigned int i = 0; i < NREC; i++) recs[i] = i;
    int prep = fd < 0 || full((int)fd, recs, sizeof recs, 1) != 0;
    snprintf(msg, sizeof msg, "open %s, write 4096 records (fd %ld)", PATH, fd);
    check(!prep, msg);
    if (prep) { print("hello355: FAIL\n"); return 1; }

    round_of(0, "A splice file->pipe off_in");
    round_of(1, "B splice pipe->file off_out");
    round_of(2, "C sendfile file->pipe offset");

    int q[2];
    if (pipe(q) != 0) { print("hello355: FAIL\n"); return 1; }
    unsigned int got[16];
    lseek((int)fd, 0, 0);
    long r1 = spl((int)fd, 0, q[1], 0, 64);
    long pos1 = lseek((int)fd, 0, 1);
    full(q[0], got, sizeof got, 0);
    lseek((int)fd, 0, 0);
    long r2 = sfl(q[1], (int)fd, 0, 64);
    long pos2 = lseek((int)fd, 0, 1);
    full(q[0], got, sizeof got, 0);
    snprintf(msg, sizeof msg, "D: a NULL offset uses and advances the descriptor's offset (splice rc %ld at %ld, sendfile rc %ld at %ld, want 64)",
             r1, pos1, r2, pos2);
    check(r1 == 64 && pos1 == 64 && r2 == 64 && pos2 == 64, msg);
    close(q[0]);
    close(q[1]);

    close((int)fd);
    unlink(PATH);
    print(failures ? "hello355: FAIL\n" : "hello355: PASS\n");
    return failures ? 1 : 0;
}
