/* hello379: the /proc directories above the files MoQiOS has (/proc/net for arp, /proc/sys/net/ipv4 for ping_group_range) open as
 * directories and list those files, as Linux does (proc_net, proc_sys). Measured on the host (build with -DHOST; any user, any
 * namespace):
 *   R. /proc lists "sys" as a directory and "net" (a symlink to self/net on Linux, so DT_LNK or DT_DIR);
 *   N. /proc/net and /proc/net/ open, fstat says S_IFDIR, and getdents64 lists "arp" as a regular file;
 *   S. /proc/sys lists "net", /proc/sys/net lists "ipv4" (directories), /proc/sys/net/ipv4 lists "ping_group_range" (a file);
 *   F. the files are still read through the directories' paths: /proc/sys/net/ipv4/ping_group_range reads two numbers;
 *   E. /proc/sys/nosuch and /proc/net/nosuch are ENOENT; getdents64 on /proc/net/arp is ENOTDIR. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long open_(const char *p) { return rc(open(p, O_RDONLY)); }
static long read_(long fd, char *b, int n) { return rc(read((int)fd, b, n)); }
static long dents(long fd, char *b, int n) { return rc(syscall(SYS_getdents64, (int)fd, b, n)); }
static long fmode(long fd) { struct stat st; long r = rc(fstat((int)fd, &st)); return r < 0 ? r : (long)st.st_mode; }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long open_(const char *p) { return syscall3(9, (long)p, 0, 0); }
static long read_(long fd, char *b, int n) { return syscall3(10, fd, (long)b, n); }
static long dents(long fd, char *b, int n) { return syscall3(173, fd, (long)b, n); }
static long fmode(long fd) { unsigned int st[36]; long r = syscall2(110, fd, (long)st); return r < 0 ? r : (long)st[6]; }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[480];
static void check(int ok, const char *w) {
    print(ok ? "hello379:   ok   " : "hello379:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* The d_type of `name` in directory `path` (0 when it is not listed, negative errno when the directory cannot be listed). */
static long type_in(const char *path, const char *name) {
    long fd = open_(path);
    if (fd < 0) return fd;
    char b[2048];
    long found = 0;
    for (;;) {
        long n = dents(fd, b, sizeof b);
        if (n < 0) { found = n; break; }
        if (n == 0) break;
        for (long off = 0; off < n; ) {
            unsigned short reclen = (unsigned short)((unsigned char)b[off + 16] | ((unsigned char)b[off + 17] << 8));
            if (strcmp(b + off + 19, name) == 0) found = (unsigned char)b[off + 18];
            off += reclen;
        }
    }
    close_(fd);
    return found;
}
static long dir_mode(const char *path) {
    long fd = open_(path);
    if (fd < 0) return fd;
    long m = fmode(fd);
    close_(fd);
    return m < 0 ? m : (m & 0170000);
}
int main(void) {
    print("hello379: /proc/net and /proc/sys list their files\n");
    long rs = type_in("/proc", "sys"), rn = type_in("/proc", "net");
    snprintf(msg, sizeof msg, "R: /proc lists sys as %ld, net as %ld (4, 10 or 4)", rs, rn);
    check(rs == 4 && (rn == 10 || rn == 4), msg);

    long n1 = dir_mode("/proc/net"), n2 = dir_mode("/proc/net/"), n3 = type_in("/proc/net", "arp");
    snprintf(msg, sizeof msg, "N: /proc/net mode 0%lo, /proc/net/ 0%lo, lists arp as %ld (040000 040000 8)", n1, n2, n3);
    check(n1 == 040000 && n2 == 040000 && n3 == 8, msg);

    long s1 = dir_mode("/proc/sys"), s2 = type_in("/proc/sys", "net"), s3 = dir_mode("/proc/sys/net"), s4 = type_in("/proc/sys/net", "ipv4");
    long s5 = dir_mode("/proc/sys/net/ipv4/"), s6 = type_in("/proc/sys/net/ipv4", "ping_group_range");
    snprintf(msg, sizeof msg, "S: /proc/sys 0%lo lists net %ld; /proc/sys/net 0%lo lists ipv4 %ld; /proc/sys/net/ipv4/ 0%lo lists ping_group_range %ld (040000 4 040000 4 040000 8)", s1, s2, s3, s4, s5, s6);
    check(s1 == 040000 && s2 == 4 && s3 == 040000 && s4 == 4 && s5 == 040000 && s6 == 8, msg);

    char b[64];
    long fd = open_("/proc/sys/net/ipv4/ping_group_range");
    long fr = fd >= 0 ? read_(fd, b, sizeof b - 1) : fd;
    if (fd >= 0) close_(fd);
    int two = 0;
    if (fr > 0) { b[fr] = 0; for (long i = 0; i < fr; i++) if (b[i] == '\t' || b[i] == ' ') two = 1; }
    snprintf(msg, sizeof msg, "F: ping_group_range reads %ld bytes with two numbers %d", fr, two);
    check(fr > 0 && two, msg);

    long e1 = open_("/proc/sys/nosuch"), e2 = open_("/proc/net/nosuch");
    long a = open_("/proc/net/arp");
    long e3 = a >= 0 ? dents(a, b, sizeof b) : a;
    if (a >= 0) close_(a);
    if (e1 >= 0) close_(e1);
    if (e2 >= 0) close_(e2);
    snprintf(msg, sizeof msg, "E: /proc/sys/nosuch %ld, /proc/net/nosuch %ld, getdents64 on /proc/net/arp %ld (-2 -2 -20)", e1, e2, e3);
    check(e1 == -2 && e2 == -2 && e3 == -20, msg);
    print(failures ? "hello379: FAIL\n" : "hello379: PASS\n");
    return failures ? 1 : 0;
}
