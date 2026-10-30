/// hello124: linkat / symlinkat / fchownat (native #490 / #491 / #492).
///
///   A. linkat: a new name under a directory fd shares the inode (nlink 2,
///      same contents); an existing target is EEXIST; AT_SYMLINK_FOLLOW
///      links the symlink's target, without it the symlink itself; unknown
///      flags EINVAL; AT_EMPTY_PATH is ENOENT; across /tmp EXDEV; inside
///      /tmp EPERM (tmpfs has no hard links).
///   B. symlinkat: creates a link under a directory fd whose target is
///      stored verbatim (readlink returns it); EEXIST on a second try; on
///      /tmp EPERM; bad dirfd EBADF.
///   C. fchownat: chown to the file's own ids works under a directory fd,
///      to another uid is EPERM (no CAP_CHOWN), flags other than
///      NOFOLLOW/EMPTY_PATH are EINVAL, AT_SYMLINK_NOFOLLOW acts on the
///      link itself, AT_EMPTY_PATH with a NULL path is fchown(dirfd).

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
#define SYS_OPEN      9
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_FSTAT     110
#define SYS_UNLINK    87
#define SYS_READLINK  89
#define SYS_LINKAT    490
#define SYS_SYMLINKAT 491
#define SYS_FCHOWNAT  492
#define AT_FDCWD      ((uint64_t)-100)
#define O_RDWR_CREAT  0x42
#define AT_SYMLINK_NOFOLLOW 0x100
#define AT_SYMLINK_FOLLOW   0x400
#define AT_EMPTY_PATH       0x1000

#define EPERM_  1
#define ENOENT_ 2
#define EBADF_  9
#define EEXIST_ 17
#define EXDEV_  18
#define EINVAL_ 22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello124:   ok   " : "hello124:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t mkfile(const char *path, const char *data) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR_CREAT, 0644);
    if (fd < 0) return fd;
    uint64_t n = 0;
    while (data[n]) n++;
    syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)data, n);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return 0;
}
static int first(const char *path) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, 0, 0);
    if (fd < 0) return -1;
    char c = 0;
    int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&c, 1);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return n == 1 ? (unsigned char)c : -1;
}
static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}
/* st_nlink, st_uid, st_gid of a path (following symlinks), or -1 */
static int stat_ids(const char *path, uint64_t *nlink, uint64_t *uid, uint64_t *gid) {
    int64_t fd = syscall2(SYS_OPEN, (uint64_t)path, 0);
    if (fd < 0) return -1;
    uint64_t st[18];
    for (int i = 0; i < 18; i++) st[i] = 0;
    int64_t r = syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)st);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    if (r != 0) return -1;
    *nlink = st[2];
    *uid = st[3] >> 32;
    *gid = st[4] & 0xFFFFFFFF;
    return 0;
}

void _start(void) {
    print("hello124: linkat / symlinkat / fchownat\n");
    int64_t dfd = syscall2(SYS_OPEN, (uint64_t)"testdir", 0);
    uint64_t n, u, g;
    mkfile("testdir/h124-a", "L");

    /* A */
    check(syscall5(SYS_LINKAT, (uint64_t)dfd, (uint64_t)"h124-a", (uint64_t)dfd, (uint64_t)"h124-b", 0) == 0 &&
          first("testdir/h124-b") == 'L' && stat_ids("testdir/h124-a", &n, &u, &g) == 0 && n == 2, "A: linkat under a directory fd shares the inode (nlink 2)");
    check(syscall5(SYS_LINKAT, (uint64_t)dfd, (uint64_t)"h124-a", (uint64_t)dfd, (uint64_t)"h124-b", 0) == -EEXIST_, "A: an existing target is EEXIST");
    check(syscall5(SYS_LINKAT, AT_FDCWD, (uint64_t)"testdir/h124-a", AT_FDCWD, (uint64_t)"testdir/h124-c", 0x2) == -EINVAL_, "A: unknown flags are EINVAL");
    check(syscall5(SYS_LINKAT, AT_FDCWD, (uint64_t)"", AT_FDCWD, (uint64_t)"testdir/h124-c", AT_EMPTY_PATH) == -ENOENT_, "A: AT_EMPTY_PATH is ENOENT without CAP_DAC_READ_SEARCH");
    check(syscall5(SYS_LINKAT, 999, (uint64_t)"h124-a", AT_FDCWD, (uint64_t)"testdir/h124-c", 0) == -EBADF_, "A: a bad olddirfd is EBADF");
    mkfile("/tmp/h124-t", "T");
    check(syscall5(SYS_LINKAT, AT_FDCWD, (uint64_t)"/tmp/h124-t", AT_FDCWD, (uint64_t)"testdir/h124-x", 0) == -EXDEV_, "A: tmpfs to ext2 is EXDEV");
    check(syscall5(SYS_LINKAT, AT_FDCWD, (uint64_t)"testdir/h124-a", AT_FDCWD, (uint64_t)"/tmp/h124-x", 0) == -EXDEV_, "A: ext2 to tmpfs is EXDEV");
    check(syscall5(SYS_LINKAT, AT_FDCWD, (uint64_t)"/tmp/h124-t", AT_FDCWD, (uint64_t)"/tmp/h124-u", 0) == -EPERM_, "A: inside tmpfs there are no hard links (EPERM)");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h124-t");

    /* B */
    check(syscall3(SYS_SYMLINKAT, (uint64_t)"h124-a", (uint64_t)dfd, (uint64_t)"h124-s") == 0 && first("testdir/h124-s") == 'L', "B: symlinkat under a directory fd (relative target resolves)");
    {
        char lk[16];
        for (int i = 0; i < 16; i++) lk[i] = 0;
        check(syscall3(SYS_READLINK, (uint64_t)"testdir/h124-s", (uint64_t)lk, 15) == 6 && streq(lk, "h124-a"), "B: the target is stored verbatim");
    }
    check(syscall3(SYS_SYMLINKAT, (uint64_t)"h124-a", (uint64_t)dfd, (uint64_t)"h124-s") == -EEXIST_, "B: a second symlinkat on the same name is EEXIST");
    check(syscall3(SYS_SYMLINKAT, (uint64_t)"x", AT_FDCWD, (uint64_t)"/tmp/h124-sl") == -EPERM_, "B: no symlinks on tmpfs (EPERM)");
    check(syscall3(SYS_SYMLINKAT, (uint64_t)"x", 999, (uint64_t)"h124-q") == -EBADF_, "B: a bad dirfd is EBADF");

    /* A (continued): symlink handling in linkat */
    check(syscall5(SYS_LINKAT, (uint64_t)dfd, (uint64_t)"h124-s", (uint64_t)dfd, (uint64_t)"h124-f", AT_SYMLINK_FOLLOW) == 0 &&
          stat_ids("testdir/h124-a", &n, &u, &g) == 0 && n == 3, "A: AT_SYMLINK_FOLLOW links the file the symlink points at");
    {
        char lk[16];
        for (int i = 0; i < 16; i++) lk[i] = 0;
        check(syscall5(SYS_LINKAT, (uint64_t)dfd, (uint64_t)"h124-s", (uint64_t)dfd, (uint64_t)"h124-n", 0) == 0 &&
              syscall3(SYS_READLINK, (uint64_t)"testdir/h124-n", (uint64_t)lk, 15) == 6, "A: without it the symlink itself is linked");
    }

    /* C */
    check(stat_ids("testdir/h124-a", &n, &u, &g) == 0, "C: stat the fixture");
    check(syscall5(SYS_FCHOWNAT, (uint64_t)dfd, (uint64_t)"h124-a", u, g, 0) == 0, "C: chown to the file's own ids under a directory fd");
    check(syscall5(SYS_FCHOWNAT, (uint64_t)dfd, (uint64_t)"h124-a", u + 1, (uint64_t)-1, 0) == -EPERM_, "C: chown to another uid is EPERM (no CAP_CHOWN)");
    check(syscall5(SYS_FCHOWNAT, (uint64_t)dfd, (uint64_t)"h124-a", (uint64_t)-1, (uint64_t)-1, 0x2) == -EINVAL_, "C: unknown flags are EINVAL");
    check(syscall5(SYS_FCHOWNAT, (uint64_t)dfd, (uint64_t)"h124-nope", u, g, 0) == -ENOENT_, "C: a missing file is ENOENT");
    check(syscall5(SYS_FCHOWNAT, (uint64_t)dfd, (uint64_t)"h124-s", u, g, AT_SYMLINK_NOFOLLOW) == 0, "C: AT_SYMLINK_NOFOLLOW acts on the link");
    {
        int64_t ffd = syscall2(SYS_OPEN, (uint64_t)"testdir/h124-a", 0);
        check(ffd >= 0 && syscall5(SYS_FCHOWNAT, (uint64_t)ffd, 0, u, g, AT_EMPTY_PATH) == 0, "C: AT_EMPTY_PATH with a NULL path is fchown(dirfd)");
        if (ffd >= 0) syscall1(SYS_CLOSE, (uint64_t)ffd);
    }
    check(syscall5(SYS_FCHOWNAT, 999, (uint64_t)"h124-a", u, g, 0) == -EBADF_, "C: a bad dirfd is EBADF");

    syscall1(SYS_UNLINK, (uint64_t)"testdir/h124-a");
    syscall1(SYS_UNLINK, (uint64_t)"testdir/h124-b");
    syscall1(SYS_UNLINK, (uint64_t)"testdir/h124-s");
    syscall1(SYS_UNLINK, (uint64_t)"testdir/h124-f");
    syscall1(SYS_UNLINK, (uint64_t)"testdir/h124-n");
    if (dfd >= 0) syscall1(SYS_CLOSE, (uint64_t)dfd);

    print(failures == 0 ? "hello124: PASS\n" : "hello124: FAIL\n");
    print("hello124 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
