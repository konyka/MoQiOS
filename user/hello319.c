/* hello319: F_SETLEASE needs the file's owner or CAP_LEASE (Linux fs/locks.c vfs_setlease: a caller whose fsuid is not the
 * inode's uid and who lacks CAP_LEASE gets EACCES; fcntl_setlease rejects a directory and lease_alloc an unknown type with
 * EINVAL first; after the owner check generic_setlease rejects what is not a regular file with EINVAL).
 * Measured on the host as uid 1000 without capabilities (build with -DHOST; the root-owned file is /etc/passwd):
 *   A. a file the caller created: F_RDLCK 0, F_GETLEASE 0, F_UNLCK 0, F_UNLCK again EAGAIN;
 *   B. (target only, holding CAP_LEASE) a root-owned file: F_RDLCK 0, F_GETLEASE 0, F_UNLCK 0;
 *   C. (target only) capget reports CAP_LEASE as bit 28;
 *   D. without CAP_LEASE a root-owned file: F_RDLCK, F_WRLCK and F_UNLCK EACCES, type 7 and -1 EINVAL, F_GETLEASE 2;
 *   E. without CAP_LEASE /dev/null and an eventfd (root-owned) are EACCES; a pipe and a directory are EINVAL;
 *   F. without CAP_LEASE the caller's own file still takes a lease.
 * The target runs as uid 1000 with only CAP_LEASE and drops it with capset before D. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r < 0 ? -errno : r; }
static long op(const char *p, long fl) { long r = open(p, (int)fl, 0600); return r < 0 ? -errno : r; }
static long evfd(void) { return eventfd(0, 0); }
static long cap_eff(void) { return -1; }
static long drop_caps(void) { return 0; }
static const char *ROOTFILE = "/etc/passwd";
#define PRIVILEGED 0
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long op(const char *p, long fl) { return open(p, fl, 0600); }
static long evfd(void) { return syscall2(169 /* native eventfd2 */, 0, 0); }
static unsigned int hdr[2], data[6];
static long cap_eff(void) {
    hdr[0] = 0x20080522u;
    hdr[1] = 0;
    memset(data, 0, sizeof data);
    long r = syscall2(306 /* native capget */, (long)hdr, (long)data);
    return r < 0 ? r : (long)data[0] | ((long)data[3] << 32);
}
static long drop_caps(void) {
    hdr[0] = 0x20080522u;
    hdr[1] = 0;
    memset(data, 0, sizeof data);
    return syscall2(307 /* native capset */, (long)hdr, (long)data);
}
static const char *ROOTFILE = "hello2";
#define PRIVILEGED 1
#endif

#define C_SETLEASE 1024
#define C_GETLEASE 1025
#define T_RDLCK 0
#define T_WRLCK 1
#define T_UNLCK 2
#define M_RO 0
#define M_RW 2
#define M_CREAT 0x40
#define M_DIR 0x10000

static int failures;
static char msg[240];
static void check(int ok, const char *w) {
    print(ok ? "hello319:   ok   " : "hello319:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long setl(long fd, long t) { return fc(fd, C_SETLEASE, t); }
static const char *F = "/tmp/h319a";

int main(void) {
    print("hello319: F_SETLEASE needs the file's owner or CAP_LEASE\n");
    unlink(F);
    long c = op(F, M_RW | M_CREAT);
    if (c >= 0) close((int)c);

    long fd = op(F, M_RO);
    long a0 = setl(fd, T_RDLCK), a1 = fc(fd, C_GETLEASE, 0), a2 = setl(fd, T_UNLCK), a3 = setl(fd, T_UNLCK);
    close((int)fd);
    snprintf(msg, sizeof msg, "A: the caller's own file takes a lease (%ld %ld %ld again %ld)", a0, a1, a2, a3);
    check(a0 == 0 && a1 == 0 && a2 == 0 && a3 == -11, msg);

    if (PRIVILEGED) {
        long r = op(ROOTFILE, M_RO);
        long b0 = setl(r, T_RDLCK), b1 = fc(r, C_GETLEASE, 0), b2 = setl(r, T_UNLCK);
        close((int)r);
        snprintf(msg, sizeof msg, "B: with CAP_LEASE a root-owned file takes a lease (%ld %ld %ld)", b0, b1, b2);
        check(r >= 0 && b0 == 0 && b1 == 0 && b2 == 0, msg);
        long e = cap_eff();
        snprintf(msg, sizeof msg, "C: capget reports CAP_LEASE as bit 28 (eff %#lx)", e);
        check(e == (1L << 28), msg);
        long d = drop_caps();
        e = cap_eff();
        snprintf(msg, sizeof msg, "C: capset drops it (%ld, eff %#lx)", d, e);
        check(d == 0 && e == 0, msg);
    }

    long r = op(ROOTFILE, M_RO);
    long d0 = setl(r, T_RDLCK), d1 = setl(r, T_WRLCK), d2 = setl(r, T_UNLCK), d3 = setl(r, 7), d4 = setl(r, -1);
    long d5 = fc(r, C_GETLEASE, 0);
    close((int)r);
    snprintf(msg, sizeof msg, "D: a root-owned file without CAP_LEASE (%ld %ld %ld; type %ld %ld; get %ld)", d0, d1, d2, d3, d4, d5);
    check(r >= 0 && d0 == -13 && d1 == -13 && d2 == -13 && d3 == -22 && d4 == -22 && d5 == 2, msg);

    long n = op("/dev/null", M_RO), ev = evfd();
    int p[2] = { -1, -1 };
    pipe2(p, 0);
    long dir = op("/tmp", M_RO | M_DIR);
    long e0 = setl(n, T_RDLCK), e1 = setl(ev, T_RDLCK), e2 = setl(p[0], T_RDLCK), e3 = setl(dir, T_RDLCK), e4 = setl(dir, T_UNLCK);
    close((int)n);
    close((int)ev);
    close(p[0]);
    close(p[1]);
    close((int)dir);
    snprintf(msg, sizeof msg, "E: /dev/null %ld, eventfd %ld EACCES; pipe %ld, directory %ld %ld EINVAL", e0, e1, e2, e3, e4);
    check(n >= 0 && ev >= 0 && dir >= 0 && e0 == -13 && e1 == -13 && e2 == -22 && e3 == -22 && e4 == -22, msg);

    fd = op(F, M_RO);
    long f0 = setl(fd, T_RDLCK), f1 = setl(fd, T_UNLCK);
    close((int)fd);
    snprintf(msg, sizeof msg, "F: without CAP_LEASE the caller's own file still takes one (%ld %ld)", f0, f1);
    check(f0 == 0 && f1 == 0, msg);

    unlink(F);
    print(failures == 0 ? "hello319: PASS\n" : "hello319: FAIL\n");
    return failures;
}
