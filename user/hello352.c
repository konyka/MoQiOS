/* hello352: getdents64 on a shared directory description moves its cursor atomically (Linux getdents64 takes f_pos_lock through
 * fdget_pos). Measured on the host (build with -DHOST):
 *   A. a directory with 120 entries e000..e119 is listed by a parent and a forked child at once through one description, with a
 *      buffer that holds about one entry per call; together they see every entry exactly once, over 8 rounds;
 *   B. after each round the cursor is at the end: one more getdents64 returns 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wr(int fd, const void *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long opn(const char *p, long fl) { long r = open(p, (int)fl, 0644); return r < 0 ? -errno : r; }
static long gd(int fd, void *b, long n) { long r = syscall(SYS_getdents64, fd, b, n); return r < 0 ? -errno : r; }
static long mkd(const char *p) { return mkdir(p, 0755) < 0 ? -errno : 0; }
static long rmd(const char *p) { return rmdir(p) < 0 ? -errno : 0; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rd(int fd, void *b, long n) { return read(fd, b, (size_t)n); }
static long wr(int fd, const void *b, long n) { return write(fd, b, (size_t)n); }
static long opn(const char *p, long fl) { return open(p, fl, 0644); }
static long gd(int fd, void *b, long n) { return syscall3(173, fd, (long)b, n); }
static long mkd(const char *p) { return mkdir(p, 0755); }
static long rmd(const char *p) { return rmdir(p); }
#endif
#define DIR_ "/tmp/hello352d"
#define N 120
#define ROUNDS 8

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello352:   ok   " : "hello352:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char seen[N], other[N];
static char path[64];
static void name_of(int i) { snprintf(path, sizeof path, "%s/e%03d", DIR_, i); }

/* List the rest of the directory, counting each eNNN entry in `seen`; returns 0, or 1 on a bad record. */
static int list(int fd) {
    char buf[40] __attribute__((aligned(8)));
    for (;;) {
        long r = gd(fd, buf, sizeof buf);
        if (r == 0) return 0;
        if (r < 0) return 1;
        for (long off = 0; off < r;) {
            unsigned short reclen;
            memcpy(&reclen, buf + off + 16, 2);
            if (reclen == 0 || off + reclen > r) return 1;
            const char *nm = buf + off + 19;
            if (nm[0] == 'e' && nm[1] >= '0' && nm[1] <= '9') {
                int v = (nm[1] - '0') * 100 + (nm[2] - '0') * 10 + (nm[3] - '0');
                if (v < N && seen[v] < 255) seen[v]++;
            }
            off += reclen;
        }
    }
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
/* Fork with a start line: the child says it is running and waits for the parent's go, so both start listing together. */
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
    print("hello352: getdents64 moves a shared directory cursor atomically\n");
    int prep = mkd(DIR_) != 0;
    for (int i = 0; i < N && !prep; i++) {
        name_of(i);
        long f = opn(path, 2 | 0x40 | 0x200);
        if (f < 0) prep = 1;
        else close((int)f);
    }
    snprintf(msg, sizeof msg, "create %s with %d entries", DIR_, N);
    check(!prep, msg);

    int bad = 0, dups = 0, missed = 0, not_end = 0;
    for (int round = 0; round < ROUNDS && !prep; round++) {
        long fd = opn(DIR_, 0x10000);
        if (fd < 0) { bad++; continue; }
        memset(seen, 0, sizeof seen);
        int p[2];
        if (pipe(p) != 0) { bad++; close((int)fd); continue; }
        long child = fork_together();
        int err = list((int)fd);
        if (child == 0) {
            close(p[0]);
            full(p[1], &err, sizeof err, 1);
            full(p[1], seen, sizeof seen, 1);
            _exit(0);
        }
        close(p[1]);
        int theirs = 1;
        if (full(p[0], &theirs, sizeof theirs, 0) != 0 || full(p[0], other, sizeof other, 0) != 0) theirs = 1;
        close(p[0]);
        int ws = 0;
        waitpid(child, &ws, 0);
        int rd_dups = 0, rd_miss = 0;
        for (int i = 0; i < N; i++) {
            int c = seen[i] + other[i];
            if (c > 1) rd_dups += c - 1;
            if (c == 0) rd_miss++;
        }
        char buf[64] __attribute__((aligned(8)));
        if (gd((int)fd, buf, sizeof buf) != 0) not_end++;
        if (err || theirs || rd_dups || rd_miss) bad++;
        dups += rd_dups;
        missed += rd_miss;
        close((int)fd);
    }
    snprintf(msg, sizeof msg, "A: two listers of one description see every entry once (%d of %d rounds wrong, %d seen twice, %d missed)",
             bad, ROUNDS, dups, missed);
    check(!prep && bad == 0, msg);
    snprintf(msg, sizeof msg, "B: the shared cursor ends at the end of the directory (%d of %d rounds not at the end)", not_end, ROUNDS);
    check(!prep && not_end == 0, msg);

    for (int i = 0; i < N; i++) { name_of(i); unlink(path); }
    rmd(DIR_);
    print(failures ? "hello352: FAIL\n" : "hello352: PASS\n");
    return failures ? 1 : 0;
}
