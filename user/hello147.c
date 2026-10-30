/// hello147: the working directory and directory descriptors in path lookup.
///
///   A. chdir refuses a missing path (ENOENT) and a non-directory (ENOTDIR)
///      on the root disk and on /tmp, and leaves the cwd unchanged.
///   B. cwd on ext2 (/testdir): relative names in open/creat, mkdir, rename,
///      chmod, access, statx, symlink/readlink, link, truncate, unlink and
///      rmdir resolve under it; a bare root-disk name is no longer found
///      there; chdir("..") returns to "/".
///   C. cwd on /tmp: the same for tmpfs, nested directories included.
///   D. From "/", a relative "tmp/..." name means /tmp/....
///   E. An ext2 directory fd as dirfd for openat (with O_CREAT), openat2,
///      faccessat, statx and readlinkat; a regular file as dirfd is ENOTDIR,
///      a closed fd EBADF, and an absolute name ignores dirfd.
///   F. fchdir into an ext2 or tmpfs directory fd changes the cwd; on a
///      regular file it is ENOTDIR.
///   G. A tmpfs directory fd as dirfd for openat, mkdirat and unlinkat.


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
#define SYS_GETCWD    79
#define SYS_CHDIR     80
#define SYS_FCHDIR    81
#define SYS_RENAME    82
#define SYS_MKDIR     83
#define SYS_RMDIR     84
#define SYS_UNLINK    87
#define SYS_OPENAT    255
#define SYS_UNLINKAT  256
#define AT_FDCWD      ((uint64_t)-100)
#define O_RDONLY      0
#define O_RDWR_CREAT  0x42
#define ENOENT_  2

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello147:   ok   " : "hello147:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}
static int64_t mkfile(const char *path, const char *content) {
    int64_t f = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR_CREAT, 0644);
    if (f < 0) return f;
    uint64_t n = 0;
    while (content[n]) n++;
    syscall3(SYS_WRITE, (uint64_t)f, (uint64_t)content, n);
    syscall1(SYS_CLOSE, (uint64_t)f);
    return 0;
}
static int first(const char *path) {
    int64_t f = syscall3(SYS_OPEN, (uint64_t)path, O_RDONLY, 0);
    if (f < 0) return (int)f;
    char c = 0;
    int64_t n = syscall3(SYS_READ, (uint64_t)f, (uint64_t)&c, 1);
    syscall1(SYS_CLOSE, (uint64_t)f);
    return n == 1 ? c : -1;
}
static char cwd_buf[256];
static const char *cwd(void) {
    for (int i = 0; i < 256; i++) cwd_buf[i] = 0;
    if (syscall2(SYS_GETCWD, (uint64_t)cwd_buf, sizeof(cwd_buf)) <= 0) return "?";
    return cwd_buf;
}
static int64_t openat(int64_t dirfd, const char *name, uint64_t flags) {
    return syscall4(SYS_OPENAT, (uint64_t)dirfd, (uint64_t)name, flags, 0644);
}

void _start(void) {
    print("hello147: a directory descriptor follows its directory across rename\n");
    syscall1(SYS_CHDIR, (uint64_t)"/");
    syscall2(SYS_MKDIR, (uint64_t)"/testdir/h147-a", 0755);
    syscall2(SYS_MKDIR, (uint64_t)"/testdir/h147-b", 0755);
    mkfile("/testdir/h147-a/f", "A");

    /* A: rename the directory the descriptor names */
    {
        int64_t d = syscall3(SYS_OPEN, (uint64_t)"/testdir/h147-a", O_RDONLY, 0);
        check(d >= 0, "A: open a directory descriptor");
        check(openat(d, "f", O_RDONLY) >= 0, "A: openat(dirfd, \"f\") finds the file before the rename");
        check(syscall2(SYS_RENAME, (uint64_t)"/testdir/h147-a", (uint64_t)"/testdir/h147-a2") == 0, "A: rename the directory");
        int64_t f = openat(d, "f", O_RDONLY);
        check(f >= 0, "A: openat(dirfd, \"f\") still finds the file after the rename");
        if (f >= 0) {
            char c = 0;
            syscall3(SYS_READ, (uint64_t)f, (uint64_t)&c, 1);
            check(c == 'A', "A: and it is the same file");
            syscall1(SYS_CLOSE, (uint64_t)f);
        }
        check(openat(d, "new", O_RDWR_CREAT) >= 0 && first("/testdir/h147-a2/new") >= -1 && first("/testdir/h147-a2/new") != -ENOENT_, "A: a file created through the descriptor lands in the renamed directory");
        check(first("/testdir/h147-a/new") == -ENOENT_, "A: and not under the old name");
        check(syscall1(SYS_FCHDIR, (uint64_t)d) == 0 && streq(cwd(), "/testdir/h147-a2"), "A: fchdir moves into the renamed directory, not the old path");
        syscall1(SYS_CHDIR, (uint64_t)"/");
        syscall1(SYS_CLOSE, (uint64_t)d);
    }

    /* B: move the directory under another parent */
    {
        int64_t d = syscall3(SYS_OPEN, (uint64_t)"/testdir/h147-a2", O_RDONLY, 0);
        check(syscall2(SYS_RENAME, (uint64_t)"/testdir/h147-a2", (uint64_t)"/testdir/h147-b/moved") == 0, "B: move the directory into another one");
        check(openat(d, "f", O_RDONLY) >= 0, "B: the descriptor still reaches its file");
        check(syscall1(SYS_FCHDIR, (uint64_t)d) == 0 && streq(cwd(), "/testdir/h147-b/moved"), "B: fchdir follows the move");
        syscall1(SYS_CHDIR, (uint64_t)"/");
        syscall1(SYS_CLOSE, (uint64_t)d);
    }

    /* C: an unchanged directory still works, and so does the root */
    {
        int64_t d = syscall3(SYS_OPEN, (uint64_t)"/testdir/h147-b", O_RDONLY, 0);
        check(openat(d, "moved/f", O_RDONLY) >= 0, "C: an untouched directory descriptor resolves relative names");
        syscall1(SYS_CLOSE, (uint64_t)d);
        int64_t r = syscall3(SYS_OPEN, (uint64_t)"/", O_RDONLY, 0);
        check(r >= 0, "C: open(\"/\") gives a directory descriptor");
        check(r >= 0 && openat(r, "testdir/h147-b/moved/f", O_RDONLY) >= 0, "C: and it resolves relative names from the root");
        char one;
        check(r >= 0 && syscall3(SYS_READ, (uint64_t)r, (uint64_t)&one, 1) == -21, "C: reading the root directory is EISDIR");
        syscall1(SYS_CLOSE, (uint64_t)r);
        check(syscall3(SYS_OPEN, (uint64_t)"/", 2 /* O_RDWR */, 0) == -21, "C: opening the root directory for writing is EISDIR");
    }

    /* D: a removed directory */
    {
        syscall2(SYS_MKDIR, (uint64_t)"/testdir/h147-gone", 0755);
        int64_t d = syscall3(SYS_OPEN, (uint64_t)"/testdir/h147-gone", O_RDONLY, 0);
        check(syscall1(SYS_RMDIR, (uint64_t)"/testdir/h147-gone") == 0, "D: remove the directory");
        check(openat(d, "x", O_RDWR_CREAT) < 0, "D: creating a file in a removed directory fails");
        syscall1(SYS_CLOSE, (uint64_t)d);
    }

    syscall1(SYS_UNLINK, (uint64_t)"/testdir/h147-b/moved/f");
    syscall1(SYS_UNLINK, (uint64_t)"/testdir/h147-b/moved/new");
    syscall1(SYS_RMDIR, (uint64_t)"/testdir/h147-b/moved");
    syscall1(SYS_RMDIR, (uint64_t)"/testdir/h147-b");
    print(failures == 0 ? "hello147: PASS\n" : "hello147: FAIL\n");
    print("hello147 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
