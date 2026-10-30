/// hello123: utimensat(2) / futimens (native #489).
///
///   A. Explicit atime/mtime on an ext2 file are visible in fstat; ctime
///      moves to "now"; UTIME_OMIT leaves a field alone; UTIME_NOW sets it
///      to the current time; times == NULL sets both to now.
///   B. Validation: tv_nsec out of range EINVAL, negative seconds EOVERFLOW,
///      unknown flags EINVAL, missing file ENOENT, bad dirfd EBADF.
///   C. futimens (pathname NULL, dirfd = the file); a name under a directory
///      fd; a read-only volume-less tmpfs file is EPERM (no timestamps).
///   D. Permission, in a child that drops to uid 1000: explicit times on a
///      file it does not own are EPERM; "now" without write access EACCES,
///      with write access allowed.

#include <stdint.h>


static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_OPEN      9
#define SYS_CLOSE     11
#define SYS_FORK      57
#define SYS_FSTAT     110
#define SYS_UNLINK    87
#define SYS_CHMOD     90
#define SYS_SETUID    174
#define SYS_UTIMENSAT 489
#define AT_FDCWD      ((uint64_t)-100)
#define O_RDWR_CREAT  0x42
#define UTIME_NOW     ((1L << 30) - 1)
#define UTIME_OMIT    ((1L << 30) - 2)

#define EPERM_     1
#define ENOENT_    2
#define EBADF_     9
#define EACCES_    13
#define EINVAL_    22
#define EOVERFLOW_ 75

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello123:   ok   " : "hello123:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t mkfile(const char *path) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR_CREAT, 0644);
    if (fd < 0) return fd;
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return 0;
}
/* st_atime/st_mtime/st_ctime (seconds) of a path, or -1 */
static int stat_times(const char *path, uint64_t *a, uint64_t *m, uint64_t *c) {
    int64_t fd = syscall2(SYS_OPEN, (uint64_t)path, 0);
    if (fd < 0) return -1;
    uint64_t st[18];
    for (int i = 0; i < 18; i++) st[i] = 0;
    int64_t r = syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)st);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    if (r != 0) return -1;
    *a = st[9]; *m = st[11]; *c = st[13];
    return 0;
}
struct ts { int64_t sec, nsec; };
static int64_t utim(uint64_t dirfd, const char *path, const struct ts *t, uint64_t flags) {
    return syscall4(SYS_UTIMENSAT, dirfd, (uint64_t)path, (uint64_t)t, flags);
}

void _start(void) {
    print("hello123: utimensat\n");
    uint64_t a, m, c, a2, m2, c2;
    mkfile("testdir/h123");

    /* A */
    struct ts t1[2] = { { 1000000, 5 }, { 2000000, 7 } };
    check(utim(AT_FDCWD, "testdir/h123", t1, 0) == 0 && stat_times("testdir/h123", &a, &m, &c) == 0 && a == 1000000 && m == 2000000, "A: explicit atime and mtime");
    check(c > 2000000, "A: ctime moves to now");
    struct ts t2[2] = { { 0, UTIME_OMIT }, { 3000000, 0 } };
    check(utim(AT_FDCWD, "testdir/h123", t2, 0) == 0 && stat_times("testdir/h123", &a, &m, &c) == 0 && a == 1000000 && m == 3000000, "A: UTIME_OMIT leaves atime alone");
    struct ts t3[2] = { { 0, UTIME_NOW }, { 0, UTIME_OMIT } };
    check(utim(AT_FDCWD, "testdir/h123", t3, 0) == 0 && stat_times("testdir/h123", &a, &m, &c) == 0 && a != 1000000 && m == 3000000, "A: UTIME_NOW sets atime, mtime kept");
    check(utim(AT_FDCWD, "testdir/h123", 0, 0) == 0 && stat_times("testdir/h123", &a2, &m2, &c2) == 0 && m2 != 3000000 && m2 == a2, "A: times == NULL sets both to now");

    /* B */
    struct ts bad_ns[2] = { { 1, 1000000000L }, { 1, 0 } };
    struct ts neg_ns[2] = { { 1, 0 }, { 1, -1 } };
    struct ts neg_s[2] = { { -1, 0 }, { 1, 0 } };
    struct ts omit_all[2] = { { -9, UTIME_OMIT }, { -9, UTIME_OMIT } };
    check(utim(AT_FDCWD, "testdir/h123", bad_ns, 0) == -EINVAL_, "B: tv_nsec >= 1e9 is EINVAL");
    check(utim(AT_FDCWD, "testdir/h123", neg_ns, 0) == -EINVAL_, "B: negative tv_nsec is EINVAL");
    check(utim(AT_FDCWD, "testdir/h123", neg_s, 0) == -EOVERFLOW_, "B: negative seconds is EOVERFLOW");
    check(utim(AT_FDCWD, "testdir/h123", omit_all, 0) == 0, "B: both UTIME_OMIT is a no-op success");
    check(utim(AT_FDCWD, "testdir/h123", 0, 0x2) == -EINVAL_, "B: unknown flags are EINVAL");
    check(utim(AT_FDCWD, "testdir/h123-nope", 0, 0) == -ENOENT_, "B: a missing file is ENOENT");
    check(utim(999, "h123", 0, 0) == -EBADF_, "B: a bad dirfd is EBADF");
    check(syscall4(SYS_UTIMENSAT, AT_FDCWD, 0, 0, 0) == -EBADF_, "B: futimens(AT_FDCWD) is EBADF");

    /* C */
    {
        int64_t fd = syscall2(SYS_OPEN, (uint64_t)"testdir/h123", 0);
        check(fd >= 0 && syscall4(SYS_UTIMENSAT, (uint64_t)fd, 0, (uint64_t)t1, 0) == 0 && stat_times("testdir/h123", &a, &m, &c) == 0 && a == 1000000 && m == 2000000, "C: futimens on an ext2 fd");
        if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
        int64_t dfd = syscall2(SYS_OPEN, (uint64_t)"testdir", 0);
        check(dfd >= 0 && utim((uint64_t)dfd, "h123", t2, 0) == 0 && stat_times("testdir/h123", &a, &m, &c) == 0 && m == 3000000, "C: a name under a directory fd");
        if (dfd >= 0) syscall1(SYS_CLOSE, (uint64_t)dfd);
        mkfile("/tmp/h123-t");
        check(utim(AT_FDCWD, "/tmp/h123-t", 0, 0) == -EPERM_, "C: a tmpfs file keeps no timestamps (EPERM)");
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h123-t");
    }

    /* D */
    {
        syscall2(SYS_CHMOD, (uint64_t)"testdir/h123", 0644);
        mkfile("testdir/h123-w");
        syscall2(SYS_CHMOD, (uint64_t)"testdir/h123-w", 0666);
        int64_t pid = syscall1(SYS_FORK, 0);
        if (pid == 0) {
            int bits = 0;
            if (syscall1(SYS_SETUID, 1000) != 0) syscall1(SYS_EXIT, 255);
            if (utim(AT_FDCWD, "testdir/h123", t1, 0) == -EPERM_) bits |= 1;
            if (utim(AT_FDCWD, "testdir/h123", 0, 0) == -EACCES_) bits |= 2;
            if (utim(AT_FDCWD, "testdir/h123-w", 0, 0) == 0) bits |= 4;
            if (utim(AT_FDCWD, "testdir/h123-w", t1, 0) == -EPERM_) bits |= 8;
            syscall1(SYS_EXIT, (uint64_t)bits);
            for (;;) {}
        }
        int status = 0;
        syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0);
        int bits = (status >> 8) & 0xff;
        check(bits & 1, "D: explicit times on another user's file are EPERM");
        check(bits & 2, "D: now without write access is EACCES");
        check(bits & 4, "D: now with write access is allowed");
        check(bits & 8, "D: explicit times still need ownership even with write access");
        syscall1(SYS_UNLINK, (uint64_t)"testdir/h123-w");
    }
    syscall1(SYS_UNLINK, (uint64_t)"testdir/h123");

    print(failures == 0 ? "hello123: PASS\n" : "hello123: FAIL\n");
    print("hello123 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
