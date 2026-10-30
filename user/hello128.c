/// hello128: errno semantics of rename/truncate/read/write/chmod/chown/readlink
/// and path-length limits on ext2 and tmpfs.

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
#define SYS_MKDIR     83
#define SYS_RENAME    82
#define SYS_RMDIR     84
#define SYS_LINK      86
#define SYS_UNLINK    87
#define SYS_SYMLINK   88
#define SYS_READLINK  89
#define SYS_CHMOD     90
#define SYS_CHOWN     92
#define SYS_TRUNCATE  210
#define SYS_FTRUNCATE 77
#define O_RDWR_CREAT  0x42
#define O_RDONLY      0

#define ENOENT_  2
#define EBADF_   9
#define EEXIST_  17
#define ENOTDIR_ 20
#define EISDIR_  21
#define EINVAL_  22
#define ENAMETOOLONG_ 36
#define ELOOP_   40
#define EPERM_   1

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello128:   ok   " : "hello128:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static char *join(char *out, const char *a, const char *b) {
    int i = 0;
    while (*a) out[i++] = *a++;
    while (*b) out[i++] = *b++;
    out[i] = 0;
    return out;
}
static int64_t mkfile(const char *path) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR_CREAT, 0644);
    if (fd < 0) return fd;
    syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"abc", 3);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return 0;
}

static void suite(const char *tag, const char *dir, int has_symlinks) {
    char f[96], d[96], m[96], n[96], l1[96], l2[96], under[96];
    join(f, dir, "/f"); join(d, dir, "/d"); join(m, dir, "/missing"); join(n, dir, "/n");
    join(l1, dir, "/l1"); join(l2, dir, "/l2"); join(under, f, "/x");
    print("hello128: -- "); print(tag); print("\n");
    syscall2(SYS_MKDIR, (uint64_t)d, 0755);
    mkfile(f);

    check(syscall2(SYS_RENAME, (uint64_t)m, (uint64_t)n) == -ENOENT_, "rename of a missing source is ENOENT");
    check(syscall2(SYS_RENAME, (uint64_t)f, (uint64_t)under) == -ENOTDIR_, "rename below a file is ENOTDIR");
    check(syscall2(SYS_RENAME, (uint64_t)f, (uint64_t)d) == -EISDIR_, "rename of a file onto a directory is EISDIR");
    check(syscall2(SYS_LINK, (uint64_t)m, (uint64_t)n) == -ENOENT_, "link of a missing source is ENOENT");
    check(syscall2(SYS_TRUNCATE, (uint64_t)d, 0) == -EISDIR_, "truncate of a directory is EISDIR");
    check(syscall2(SYS_TRUNCATE, (uint64_t)m, 0) == -ENOENT_, "truncate of a missing file is ENOENT");
    check(syscall2(SYS_CHMOD, (uint64_t)m, 0644) == -ENOENT_, "chmod of a missing file is ENOENT");
    check(syscall3(SYS_CHOWN, (uint64_t)m, 0, 0) == -ENOENT_, "chown of a missing file is ENOENT");
    char buf[16];
    check(syscall3(SYS_READLINK, (uint64_t)f, (uint64_t)buf, 15) == -EINVAL_, "readlink of a regular file is EINVAL");
    check(syscall3(SYS_READLINK, (uint64_t)m, (uint64_t)buf, 15) == -ENOENT_, "readlink of a missing name is ENOENT");
    {
        int64_t dfd = syscall3(SYS_OPEN, (uint64_t)d, O_RDONLY, 0);
                check(dfd >= 0 && syscall3(SYS_READ, (uint64_t)dfd, (uint64_t)buf, 8) == -EISDIR_, "read() of a directory is EISDIR");
        check(dfd >= 0 && syscall3(SYS_WRITE, (uint64_t)dfd, (uint64_t)"x", 1) == -EBADF_, "write() to a directory opened read-only is EBADF");
        if (dfd >= 0) syscall1(SYS_CLOSE, (uint64_t)dfd);
        int64_t ffd = syscall3(SYS_OPEN, (uint64_t)f, O_RDONLY, 0);
            check(ffd >= 0 && syscall3(SYS_WRITE, (uint64_t)ffd, (uint64_t)"x", 1) == -EBADF_, "write() to a read-only descriptor is EBADF");
        check(ffd >= 0 && syscall2(SYS_FTRUNCATE, (uint64_t)ffd, 0) < 0, "ftruncate of a read-only descriptor fails");
        if (ffd >= 0) syscall1(SYS_CLOSE, (uint64_t)ffd);
    }
    {
        /* a path longer than the kernel's 255-byte limit must say ENAMETOOLONG, not EFAULT/ENOENT/EPERM */
        static char longpath[400];
        int i = 0;
        for (const char *p = dir; *p; p++) longpath[i++] = *p;
        longpath[i++] = '/';
        for (int k = 0; k < 300; k++) longpath[i++] = 'a';
        longpath[i] = 0;
        int64_t r = syscall3(SYS_OPEN, (uint64_t)longpath, O_RDWR_CREAT, 0644);
        check(r == -ENAMETOOLONG_, "a path longer than 255 bytes is ENAMETOOLONG");
        if (r >= 0) syscall1(SYS_CLOSE, (uint64_t)r);
        r = syscall2(SYS_MKDIR, (uint64_t)longpath, 0755);
        check(r == -ENAMETOOLONG_, "mkdir with a path longer than 255 bytes is ENAMETOOLONG");
        r = syscall1(SYS_UNLINK, (uint64_t)longpath);
        check(r == -ENAMETOOLONG_, "unlink with a path longer than 255 bytes is ENAMETOOLONG");
    }
    if (has_symlinks) {
        syscall2(SYS_SYMLINK, (uint64_t)l2, (uint64_t)l1);
        syscall2(SYS_SYMLINK, (uint64_t)l1, (uint64_t)l2);
        int64_t fd = syscall3(SYS_OPEN, (uint64_t)l1, O_RDONLY, 0);
        check(fd == -ELOOP_, "a symlink loop is ELOOP");
        if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
        check(syscall2(SYS_SYMLINK, (uint64_t)f, (uint64_t)d) == -EEXIST_, "symlink onto an existing name is EEXIST");
        syscall1(SYS_UNLINK, (uint64_t)l1);
        syscall1(SYS_UNLINK, (uint64_t)l2);
    }
    syscall1(SYS_UNLINK, (uint64_t)f);
    syscall1(SYS_RMDIR, (uint64_t)d);
}

void _start(void) {
    print("hello128: more errno semantics\n");
    suite("ext2", "/testdir", 1);
    suite("tmpfs", "/tmp", 0);
    print(failures == 0 ? "hello128: PASS\n" : "hello128: FAIL\n");
    print("hello128 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
