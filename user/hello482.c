/* hello482: per-user pipe pages (Linux fs/pipe.c: user_struct.pipe_bufs, /proc/sys/fs/pipe-user-pages-soft 16384 and -hard 0).
 * Each pipe charges its pages to the real uid that made it. Past the soft limit an unprivileged user's new pipe gets 2 pages
 * (PIPE_MIN_DEF_BUFFERS) and F_SETPIPE_SZ may not grow a pipe; past the hard limit pipe() is ENFILE. Shrinking is always allowed.
 * The test runs as root with CAP_SETUID and CAP_SYS_RESOURCE; the user part runs in a child that has taken uid 4242, which drops
 * both capabilities.
 * Measured on the host (build with -DHOST, `unshare --map-auto --map-root-user -n`; userns root is unprivileged for the initial
 * namespace's capable()): A and C pass with the default limits, where other pipes of the same real uid also count, which is why C
 * grows pipes until the first EPERM rather than counting them. The writes (B, D, E) need the initial user namespace and run only
 * here, following the Linux code:
 *   A. pipe-user-pages-soft reads "16384\n", pipe-user-pages-hard "0\n";
 *   B. root writes soft "256": the write returns 3 and reads back; "-1" and "abc" are EINVAL;
 *   C. growing 64 KiB pipes to 1 MiB (on MoQiOS 256 KiB) stops with EPERM (on MoQiOS after exactly 4, 4 x 64 = 256 pages); 16-page
 *      pipes are made until one has 8192 bytes (on MoQiOS the one that hit EPERM already has: 272 > 256); the next pipe has 8192 and cannot
 *      grow (EPERM), a big pipe can still shrink to 4096; once they are all closed a new pipe has 65536;
 *   D. with hard "40" and soft "0" (none): a user holding two 16-page pipes gets ENFILE from pipe(); one of them shrinks to 1 page
 *      and grows to 2 (18 pages in all), growing it to 32 pages (48) is EPERM; root, holding CAP_SYS_RESOURCE, still gets 65536;
 *   E. the limits go back to 16384 and 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long pipe_(int *p) { return rc(pipe(p)); }
static long fcntl_(int fd, int cmd, long arg) { return rc(fcntl(fd, cmd, arg)); }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long io_(long fd, const char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, (char *)b, n)); }
static void close_(long s) { close((int)s); }
static long fork_(void) { return fork(); }
static long setuid_(long u) { return rc(setuid((uid_t)u)); }
static int wait_(long c) { int st = 0; waitpid((pid_t)c, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 100; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long pipe_(int *p) { return syscall2(SYS_pipe2, (long)p, 0); }
static long fcntl_(int fd, int cmd, long arg) { return syscall3(SYS_fcntl, fd, cmd, arg); }
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr ? 1 : 0, 0); }
static long io_(long fd, const char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
static long fork_(void) { return syscall0(57); }
static long setuid_(long u) { return syscall3(178, u, u, u); }
static int wait_(long c) { int st = 0; syscall3(6, c, (long)&st, 0); return (st & 0x7f) ? 100 : (st >> 8) & 0xff; }
#endif
#define F_SETPIPE_SZ 1031
#define F_GETPIPE_SZ 1032
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello482:   ok   " : "hello482:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char *soft_path = "/proc/sys/fs/pipe-user-pages-soft";
static const char *hard_path = "/proc/sys/fs/pipe-user-pages-hard";
static char cur[32];
static long rd(const char *path) {
    long fd = open_(path, 0);
    if (fd < 0) return fd;
    long n = io_(fd, cur, 31, 0);
    close_(fd);
    cur[n > 0 ? n : 0] = 0;
    return n;
}
static long wr(const char *path, const char *v) {
    long fd = open_(path, 1);
    if (fd < 0) return fd;
    long n = io_(fd, v, (int)strlen(v), 1);
    close_(fd);
    return n;
}
static long new_pipe_size(void) {
    int p[2];
    long r = pipe_(p);
    if (r < 0) return r;
    long sz = fcntl_(p[0], F_GETPIPE_SZ, 0);
    close_(p[0]);
    close_(p[1]);
    return sz;
}
/* C, in a child: exit status bit 0 set when a check failed; the report goes to stdout. */
static int part_c(int exact) {
    static int big[70][2];
    int n = 0, bad = 0;
    long last = 0;
    while (n < 64) {
        if (pipe_(big[n]) < 0) break;
        last = fcntl_(big[n][1], F_SETPIPE_SZ, exact ? 262144 : 1 << 20);
        n++;
        if (last < 0) break;
    }
    int grown = last < 0 ? n - 1 : n;
    snprintf(msg, sizeof msg, "C: grew %d pipes to %s, then F_SETPIPE_SZ %ld (EPERM%s)", grown, exact ? "256 KiB" : "1 MiB", last, exact ? " after 4" : "");
    check(last == -1 && (!exact || grown == 4), msg);
    if (last != -1 || (exact && grown != 4)) bad = 1;
    /* Over the soft limit now? Keep making pipes until one comes back with 2 pages (on MoQiOS the pipe that hit EPERM already has). */
    int extra = 0;
    long small = fcntl_(big[n - 1][0], F_GETPIPE_SZ, 0);
    while (small != 8192 && n < 68) {
        if (pipe_(big[n]) < 0) break;
        small = fcntl_(big[n][0], F_GETPIPE_SZ, 0);
        n++;
        extra++;
    }
    int p[2];
    long pr = pipe_(p);
    long again = fcntl_(p[0], F_GETPIPE_SZ, 0);
    long grow = fcntl_(p[1], F_SETPIPE_SZ, 65536);
    long shrink = fcntl_(big[0][1], F_SETPIPE_SZ, 4096);
    int okc = small == 8192 && (!exact || extra == 0) && pr == 0 && again == 8192 && grow == -1 && shrink == 4096;
    snprintf(msg, sizeof msg, "C: a 2-page pipe after %d more, the next pipe %ld has %ld, growing it %ld, shrinking a big one %ld (%s8192, 0, 8192, -1, 4096)",
             extra, pr, again, grow, shrink, exact ? "0 more, " : "");
    check(okc, msg);
    if (!okc) bad = 1;
    close_(p[0]);
    close_(p[1]);
    for (int i = 0; i < n; i++) {
        close_(big[i][0]);
        close_(big[i][1]);
    }
    long fresh = new_pipe_size();
    snprintf(msg, sizeof msg, "C: after closing them a new pipe has %ld (65536)", fresh);
    check(fresh == 65536, msg);
    if (fresh != 65536) bad = 1;
    return bad;
}
int main(void) {
    print("hello482: per-user pipe pages\n");
    long ns = rd(soft_path);
    char soft[32];
    strcpy(soft, cur);
    long nh = rd(hard_path);
    snprintf(msg, sizeof msg, "A: soft %ld \"%s\", hard %ld \"%s\" (\"16384\\n\", \"0\\n\")", ns, soft, nh, cur);
    check(strcmp(soft, "16384\n") == 0 && strcmp(cur, "0\n") == 0, msg);
#ifndef HOST
    long w = wr(soft_path, "256");
    rd(soft_path);
    long neg = wr(soft_path, "-1"), junk = wr(soft_path, "abc");
    snprintf(msg, sizeof msg, "B: soft \"256\" %ld, reads \"%s\", \"-1\" %ld, \"abc\" %ld (3, \"256\\n\", -22, -22)", w, cur, neg, junk);
    check(w == 3 && strcmp(cur, "256\n") == 0 && neg == -22 && junk == -22, msg);
#endif
    long c = fork_();
    if (c == 0) {
#ifndef HOST
        if (setuid_(4242) != 0) _exit(9);
        _exit(part_c(1));
#else
        _exit(part_c(0));
#endif
    }
    int st = wait_(c);
    snprintf(msg, sizeof msg, "C: the child exited %d (0)", st);
    check(st == 0, msg);
#ifndef HOST
    long wh = wr(hard_path, "40"), ws = wr(soft_path, "0");
    c = fork_();
    if (c == 0) {
        if (setuid_(4242) != 0) _exit(9);
        int a[2], b[2], d[2];
        long ra = pipe_(a), rb = pipe_(b), rd_ = pipe_(d);
        int bad = !(ra == 0 && rb == 0 && rd_ == -23);
        snprintf(msg, sizeof msg, "D: as uid 4242 pipes %ld, %ld, then %ld (0, 0, -23 ENFILE)", ra, rb, rd_);
        check(!bad, msg);
        long shrink = fcntl_(b[1], F_SETPIPE_SZ, 4096);
        long ok = fcntl_(b[1], F_SETPIPE_SZ, 8192);
        long grow = fcntl_(b[1], F_SETPIPE_SZ, 131072);
        snprintf(msg, sizeof msg, "D: shrink to 4096 %ld, grow to 8192 %ld, to 131072 %ld (4096, 8192, -1)", shrink, ok, grow);
        check(shrink == 4096 && ok == 8192 && grow == -1, msg);
        if (!(shrink == 4096 && ok == 8192 && grow == -1)) bad = 1;
        _exit(bad);
    }
    st = wait_(c);
    long root_pipe = new_pipe_size();
    snprintf(msg, sizeof msg, "D: hard \"40\" %ld, soft \"0\" %ld, child %d, root's new pipe %ld (2, 1, 0, 65536)", wh, ws, st, root_pipe);
    check(wh == 2 && ws == 1 && st == 0 && root_pipe == 65536, msg);
    wr(hard_path, "0");
    wr(soft_path, "16384");
    rd(soft_path);
    strcpy(soft, cur);
    rd(hard_path);
    snprintf(msg, sizeof msg, "E: soft \"%s\", hard \"%s\" (\"16384\\n\", \"0\\n\")", soft, cur);
    check(strcmp(soft, "16384\n") == 0 && strcmp(cur, "0\n") == 0, msg);
#endif
    print(failures ? "hello482: FAIL\n" : "hello482: PASS\n");
    return failures ? 1 : 0;
}
