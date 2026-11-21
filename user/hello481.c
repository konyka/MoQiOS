/* hello481: /proc/sys/fs/pipe-max-size (Linux fs/pipe.c: pipe_max_size 1048576, proc_dopipe_max_size = proc_douintvec with
 * round_pipe_size and a minimum of 1, mode 0644; pipe_set_size's EPERM past it without CAP_SYS_RESOURCE; alloc_pipe_info shrinks a
 * new pipe to max_size >> PAGE_SHIFT pages when 16 pages are more). The test runs as root without CAP_SYS_RESOURCE.
 * Measured on the host (build with -DHOST, `unshare --map-auto --map-root-user -n`): A reads "1048576\n"; the fs sysctls belong to
 * the initial user namespace, so the writes (B-G) can only run here; they follow the Linux code:
 *   A. the file reads "1048576\n";
 *   B. writing "100000\n" returns 7 and the file reads "131072\n" (rounded up to a power-of-two number of pages);
 *   C. F_SETPIPE_SZ 262144 is EPERM, 131072 is taken; a new pipe still has 65536;
 *   D. after "16384": a new pipe has 16384, F_SETPIPE_SZ 65536 on it is EPERM, 8192 is taken;
 *   E. "-5" and "abc" are EINVAL, "2147483649" (rounds past 2^31) ERANGE; the value stays 16384;
 *   F. after "4096": a new pipe has 4096 and a non-blocking writer fits 4096 bytes, then EAGAIN;
 *   G. "1048576" again: a new pipe has 65536. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long pipe_nb(int *p) { return rc(pipe2(p, O_NONBLOCK)); }
static long fcntl_(int fd, int cmd, long arg) { return rc(fcntl(fd, cmd, arg)); }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long io_(long fd, const char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, (char *)b, n)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long pipe_nb(int *p) { return syscall2(SYS_pipe2, (long)p, 0x800); }
static long fcntl_(int fd, int cmd, long arg) { return syscall3(SYS_fcntl, fd, cmd, arg); }
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr ? 1 : 0, 0); }
static long io_(long fd, const char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
#define F_SETPIPE_SZ 1031
#define F_GETPIPE_SZ 1032
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello481:   ok   " : "hello481:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char *path = "/proc/sys/fs/pipe-max-size";
static char cur[32];
static long rd(void) {
    long fd = open_(path, 0);
    if (fd < 0) return fd;
    long n = io_(fd, cur, 31, 0);
    close_(fd);
    cur[n > 0 ? n : 0] = 0;
    return n;
}
static long wr(const char *v) {
    long fd = open_(path, 1);
    if (fd < 0) return fd;
    long n = io_(fd, v, (int)strlen(v), 1);
    close_(fd);
    return n;
}
/* F_GETPIPE_SZ of a new pipe, then F_SETPIPE_SZ `set` on it (0: none); the pipe is closed. */
static long new_pipe(long set, long *set_ret) {
    int p[2];
    long r = pipe_nb(p);
    if (r < 0) return r;
    long sz = fcntl_(p[0], F_GETPIPE_SZ, 0);
    if (set_ret) *set_ret = fcntl_(p[1], F_SETPIPE_SZ, set);
    close_(p[0]);
    close_(p[1]);
    return sz;
}
static char block[4100];
int main(void) {
    print("hello481: /proc/sys/fs/pipe-max-size\n");
    long n = rd();
    snprintf(msg, sizeof msg, "A: read %ld \"%s\" (8 \"1048576\\n\")", n, n > 0 ? cur : "");
    check(n == 8 && strcmp(cur, "1048576\n") == 0, msg);
#ifdef HOST
    print("hello481: writes need the initial user namespace; B-G run only on MoQiOS\n");
#else
    long w = wr("100000\n");
    rd();
    snprintf(msg, sizeof msg, "B: write \"100000\" %ld, reads \"%s\" (7, \"131072\\n\")", w, cur);
    check(w == 7 && strcmp(cur, "131072\n") == 0, msg);

    int p[2];
    pipe_nb(p);
    long big = fcntl_(p[1], F_SETPIPE_SZ, 262144);
    long ok = fcntl_(p[1], F_SETPIPE_SZ, 131072);
    close_(p[0]);
    close_(p[1]);
    long fresh = new_pipe(0, 0);
    snprintf(msg, sizeof msg, "C: F_SETPIPE_SZ 262144 %ld, 131072 %ld, new pipe %ld (-1 EPERM, 131072, 65536)", big, ok, fresh);
    check(big == -1 && ok == 131072 && fresh == 65536, msg);

    w = wr("16384");
    long grow = 0, shrink = 0;
    long small = new_pipe(65536, &grow);
    new_pipe(8192, &shrink);
    snprintf(msg, sizeof msg, "D: write %ld, new pipe %ld, F_SETPIPE_SZ 65536 %ld, 8192 %ld (5, 16384, -1, 8192)", w, small, grow, shrink);
    check(w == 5 && small == 16384 && grow == -1 && shrink == 8192, msg);

    long neg = wr("-5"), junk = wr("abc"), huge = wr("2147483649");
    rd();
    snprintf(msg, sizeof msg, "E: \"-5\" %ld, \"abc\" %ld, \"2147483649\" %ld, reads \"%s\" (-22, -22, -34, \"16384\\n\")", neg, junk, huge, cur);
    check(neg == -22 && junk == -22 && huge == -34 && strcmp(cur, "16384\n") == 0, msg);

    w = wr("4096");
    pipe_nb(p);
    long one = fcntl_(p[0], F_GETPIPE_SZ, 0);
    long first = io_(p[1], block, 4096, 1);
    long again = io_(p[1], block, 1, 1);
    close_(p[0]);
    close_(p[1]);
    snprintf(msg, sizeof msg, "F: write %ld, new pipe %ld, writes %ld then %ld (4, 4096, 4096, -11)", w, one, first, again);
    check(w == 4 && one == 4096 && first == 4096 && again == -11, msg);

    w = wr("1048576");
    fresh = new_pipe(0, 0);
    rd();
    snprintf(msg, sizeof msg, "G: write %ld, reads \"%s\", new pipe %ld (7, \"1048576\\n\", 65536)", w, cur, fresh);
    check(w == 7 && strcmp(cur, "1048576\n") == 0 && fresh == 65536, msg);
#endif
    print(failures ? "hello481: FAIL\n" : "hello481: PASS\n");
    return failures ? 1 : 0;
}
