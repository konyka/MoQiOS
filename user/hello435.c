/* hello435: lseek on a terminal is ESPIPE (Linux: a tty is opened with FMODE_STREAM / no_llseek, so vfs_llseek fails with ESPIPE),
 * whether it is a standard descriptor or /dev/tty; a character device with a position such as /dev/null or /dev/zero still seeks
 * (noop_llseek returns the offset without moving). This kernel used to treat /dev/tty as seekable.
 * Measured on the host (build with -DHOST, run on a pseudo-terminal):
 *   A. lseek(1, 0, SEEK_CUR) -> -29;
 *   B. open("/dev/tty") then lseek(fd, 0, SEEK_SET) and SEEK_CUR -> -29 -29, also on a dup of it;
 *   C. /dev/null lseek(fd, 5, SEEK_SET) -> >= 0 (Linux 0), /dev/zero lseek(fd, 7, SEEK_SET) -> >= 0 (Linux 0). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long open_(const char *p, int f) { return rc(open(p, f)); }
static long lseek_(long fd, long off, int wh) { return rc(lseek((int)fd, off, wh)); }
static long dup_(long fd) { return rc(dup((int)fd)); }
static void close_(long fd) { close((int)fd); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
static long open_(const char *p, int f) { return syscall3(9, (long)p, f, 0); }
static long lseek_(long fd, long off, int wh) { return syscall3(SYS_lseek, fd, off, wh); }
static long dup_(long fd) { return syscall1(SYS_dup, fd); }
static void close_(long fd) { syscall1(11, fd); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello435:   ok   " : "hello435:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
int main(void) {
    print("hello435: lseek on a terminal is ESPIPE\n");
    long a = lseek_(1, 0, 1);
    snprintf(msg, sizeof msg, "A: lseek(stdout) %ld (-29)", a);
    check(a == -29, msg);

    long t = open_("/dev/tty", 2);
    long b0 = lseek_(t, 0, 0), b1 = lseek_(t, 0, 1);
    long d = dup_(t);
    long b2 = lseek_(d, 0, 0);
    snprintf(msg, sizeof msg, "B: open /dev/tty %ld; lseek SET %ld, CUR %ld; on a dup %ld (>=0; -29 -29; -29)", t, b0, b1, b2);
    check(t >= 0 && b0 == -29 && b1 == -29 && b2 == -29, msg);

    long n = open_("/dev/null", 2), z = open_("/dev/zero", 0);
    long c0 = lseek_(n, 5, 0), c1 = lseek_(z, 7, 0);
    snprintf(msg, sizeof msg, "C: /dev/null %ld lseek %ld; /dev/zero %ld lseek %ld (>=0 >=0; >=0 >=0)", n, c0, z, c1);
    check(n >= 0 && c0 >= 0 && z >= 0 && c1 >= 0, msg);

    close_(t);
    close_(d);
    close_(n);
    close_(z);
    print(failures == 0 ? "hello435: PASS\n" : "hello435: FAIL\n");
    return failures == 0 ? 0 : 1;
}
