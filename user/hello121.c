/// hello121: the working directory and directory descriptors in path lookup.
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
#define SYS_FSTAT     110
#define SYS_GETCWD    79
#define SYS_CHDIR     80
#define SYS_FCHDIR    81
#define SYS_RENAME    82
#define SYS_MKDIR     83
#define SYS_RMDIR     84
#define SYS_LINK      86
#define SYS_UNLINK    87
#define SYS_SYMLINK   88
#define SYS_READLINK  89
#define SYS_CHMOD     90
#define SYS_STATX     183
#define SYS_ACCESS    198
#define SYS_TRUNCATE  210
#define SYS_OPENAT    255
#define SYS_UNLINKAT  256
#define SYS_MKDIRAT   257
#define SYS_FACCESSAT 258
#define SYS_READLINKAT 259
#define SYS_OPENAT2   437
#define AT_FDCWD      ((uint64_t)-100)
#define AT_REMOVEDIR  0x200
#define O_RDONLY      0
#define O_RDWR_CREAT  0x42

#define ENOENT_  2
#define EBADF_   9
#define ENOTDIR_ 20

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello121:   ok   " : "hello121:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
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
static int read_first(int64_t fd) {
    if (fd < 0) return -1;
    char c = 0;
    int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&c, 1);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return n == 1 ? (unsigned char)c : -1;
}
/* first byte of a file, or -1 if it cannot be opened or is empty */
static int first(const char *path) { return read_first(syscall3(SYS_OPEN, (uint64_t)path, O_RDONLY, 0)); }
static int exists(const char *path) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDONLY, 0);
    if (fd < 0) return 0;
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return 1;
}
static uint32_t mode_of(const char *path) {
    int64_t fd = syscall2(SYS_OPEN, (uint64_t)path, 0);
    if (fd < 0) return 0xFFFFFFFF;
    uint64_t st[18];
    for (int i = 0; i < 18; i++) st[i] = 0;
    int64_t r = syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)st);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    if (r != 0) return 0xFFFFFFFF;
    return (uint32_t)(st[3] & 0xFFFFFFFF) & 07777;
}
static char cwd_buf[256];
static const char *cwd(void) {
    for (int i = 0; i < 256; i++) cwd_buf[i] = 0;
    if (syscall2(SYS_GETCWD, (uint64_t)cwd_buf, sizeof(cwd_buf)) <= 0) return "?";
    return cwd_buf;
}

void _start(void) {
    print("hello121: cwd and directory descriptors in path lookup\n");
    syscall1(SYS_CHDIR, (uint64_t)"/");

    /* A: chdir validates its target */
    mkfile("testdir/h121-file", "f");
    check(syscall1(SYS_CHDIR, (uint64_t)"/h121-nope") == -ENOENT_ && streq(cwd(), "/"), "A: chdir to a missing ext2 path is ENOENT and the cwd stays");
    check(syscall1(SYS_CHDIR, (uint64_t)"testdir/h121-file") == -ENOTDIR_ && streq(cwd(), "/"), "A: chdir to an ext2 file is ENOTDIR");
    mkfile("/tmp/h121-tf", "t");
    check(syscall1(SYS_CHDIR, (uint64_t)"/tmp/h121-nope") == -ENOENT_, "A: chdir to a missing /tmp path is ENOENT");
    check(syscall1(SYS_CHDIR, (uint64_t)"/tmp/h121-tf") == -ENOTDIR_ && streq(cwd(), "/"), "A: chdir to a /tmp file is ENOTDIR");
    check(syscall1(SYS_CHDIR, (uint64_t)"/tmp") == 0 && streq(cwd(), "/tmp"), "A: chdir /tmp");
    check(syscall1(SYS_CHDIR, (uint64_t)"/") == 0 && streq(cwd(), "/"), "A: chdir / back");

    /* B: cwd on ext2 */
    check(syscall1(SYS_CHDIR, (uint64_t)"/testdir") == 0 && streq(cwd(), "/testdir"), "B: chdir /testdir");
    check(first("h121-file") == 'f', "B: open of a relative name reads /testdir's file");
    check(!exists("hello2"), "B: a root-disk name is not found from /testdir");
    check(first("../hello2") >= 0, "B: ../hello2 reaches the root again");
    check(mkfile("h121-b", "b") == 0 && first("/testdir/h121-b") == 'b', "B: O_CREAT of a relative name creates it under /testdir");
    check(syscall2(SYS_MKDIR, (uint64_t)"h121-bd", 0755) == 0 && mkfile("/testdir/h121-bd/x", "x") == 0, "B: mkdir of a relative name");
    check(syscall2(SYS_RENAME, (uint64_t)"h121-b", (uint64_t)"h121-bd/y") == 0 && first("/testdir/h121-bd/y") == 'b', "B: rename between relative names");
    check(syscall2(SYS_CHMOD, (uint64_t)"h121-bd/y", 0600) == 0 && mode_of("/testdir/h121-bd/y") == 0600, "B: chmod of a relative name");
    check(syscall2(SYS_ACCESS, (uint64_t)"h121-bd/y", 0) == 0 && syscall2(SYS_ACCESS, (uint64_t)"h121-nope", 0) == -ENOENT_, "B: access of relative names");
    {
        static uint64_t stx[32];
        check(syscall5(SYS_STATX, AT_FDCWD, (uint64_t)"h121-bd/y", 0, 0x7ff, (uint64_t)stx) == 0 && stx[5] == 1, "B: statx of a relative name reports its size");
    }
    check(syscall2(SYS_SYMLINK, (uint64_t)"h121-bd/y", (uint64_t)"h121-ln") == 0 && first("/testdir/h121-ln") == 'b', "B: symlink at a relative name (relative target resolves from /testdir)");
    {
        char lk[32];
        for (int i = 0; i < 32; i++) lk[i] = 0;
        int64_t r = syscall3(SYS_READLINK, (uint64_t)"h121-ln", (uint64_t)lk, 31);
        check(r == 9 && streq(lk, "h121-bd/y"), "B: readlink of a relative name");
    }
    check(syscall2(SYS_LINK, (uint64_t)"h121-bd/y", (uint64_t)"h121-hl") == 0 && first("/testdir/h121-hl") == 'b', "B: link between relative names");
    check(syscall2(SYS_TRUNCATE, (uint64_t)"h121-hl", 0) == 0 && first("/testdir/h121-bd/y") == -1, "B: truncate of a relative name");
    check(syscall1(SYS_UNLINK, (uint64_t)"h121-hl") == 0 && syscall1(SYS_UNLINK, (uint64_t)"h121-ln") == 0 &&
          syscall1(SYS_UNLINK, (uint64_t)"h121-bd/y") == 0 && syscall1(SYS_UNLINK, (uint64_t)"h121-bd/x") == 0 &&
          !exists("/testdir/h121-bd/y"), "B: unlink of relative names");
    check(syscall1(SYS_RMDIR, (uint64_t)"h121-bd") == 0 && !exists("/testdir/h121-bd"), "B: rmdir of a relative name");
    check(syscall1(SYS_CHDIR, (uint64_t)"..") == 0 && streq(cwd(), "/"), "B: chdir .. returns to /");

    /* C: cwd on /tmp */
    syscall2(SYS_MKDIR, (uint64_t)"/tmp/h121-c", 0755);
    check(syscall1(SYS_CHDIR, (uint64_t)"/tmp/h121-c") == 0 && streq(cwd(), "/tmp/h121-c"), "C: chdir into a /tmp directory");
    check(mkfile("c1", "c") == 0 && first("/tmp/h121-c/c1") == 'c', "C: O_CREAT of a relative name lands in /tmp/h121-c");
    check(syscall2(SYS_MKDIR, (uint64_t)"sub", 0755) == 0 && mkfile("sub/c2", "d") == 0 && first("/tmp/h121-c/sub/c2") == 'd', "C: nested relative mkdir and create");
    check(syscall2(SYS_RENAME, (uint64_t)"c1", (uint64_t)"sub/c3") == 0 && first("sub/c3") == 'c', "C: rename between relative tmpfs names");
    {
        int64_t r = syscall2(SYS_CHMOD, (uint64_t)"sub/c3", 0640);
        uint32_t m = mode_of("/tmp/h121-c/sub/c3");
        check(r == 0 && m == 0640, "C: chmod of a relative tmpfs name");
    }
    check(syscall1(SYS_UNLINK, (uint64_t)"sub/c3") == 0 && syscall1(SYS_UNLINK, (uint64_t)"sub/c2") == 0 &&
          syscall1(SYS_RMDIR, (uint64_t)"sub") == 0 && !exists("/tmp/h121-c/sub"), "C: unlink and rmdir of relative tmpfs names");
    {
        int64_t r = syscall1(SYS_CHDIR, (uint64_t)"..");
        check(r == 0 && streq(cwd(), "/tmp"), "C: chdir .. gives /tmp");
    }
    check(syscall1(SYS_CHDIR, (uint64_t)"/") == 0, "C: back to /");

    /* D: from the root, tmp/... is /tmp/... */
    check(first("tmp/h121-tf") == 't', "D: a relative tmp/ name from / opens the tmpfs file");
    check(mkfile("tmp/h121-c/d1", "e") == 0 && first("/tmp/h121-c/d1") == 'e', "D: and creates there");
    check(syscall1(SYS_UNLINK, (uint64_t)"tmp/h121-c/d1") == 0, "D: and unlinks there");
    check(!exists("/tmph121-tf"), "D: /tmpX is not an alias of /tmp/X");

    /* E: ext2 directory fd as dirfd */
    {
        int64_t dfd = syscall2(SYS_OPEN, (uint64_t)"testdir", 0);
        check(dfd >= 0, "E: open testdir");
        int64_t f = syscall4(SYS_OPENAT, (uint64_t)dfd, (uint64_t)"h121-file", O_RDONLY, 0);
        check(read_first(f) == 'f', "E: openat reads a name under the directory fd");
        f = syscall4(SYS_OPENAT, (uint64_t)dfd, (uint64_t)"h121-e", O_RDWR_CREAT, 0644);
        if (f >= 0) { syscall3(SYS_WRITE, (uint64_t)f, (uint64_t)"E", 1); syscall1(SYS_CLOSE, (uint64_t)f); }
        check(first("/testdir/h121-e") == 'E', "E: openat(O_CREAT) creates under the directory fd");
        {
            uint64_t how[3] = { 0, 0, 0 };
            check(read_first(syscall4(SYS_OPENAT2, (uint64_t)dfd, (uint64_t)"h121-e", (uint64_t)how, sizeof(how))) == 'E', "E: openat2 resolves under the directory fd");
        }
        check(syscall4(SYS_FACCESSAT, (uint64_t)dfd, (uint64_t)"h121-e", 0, 0) == 0, "E: faccessat under the directory fd");
        {
            static uint64_t stx[32];
            check(syscall5(SYS_STATX, (uint64_t)dfd, (uint64_t)"h121-e", 0, 0x7ff, (uint64_t)stx) == 0 && stx[5] == 1, "E: statx under the directory fd");
        }
        syscall2(SYS_SYMLINK, (uint64_t)"h121-e", (uint64_t)"testdir/h121-el");
        {
            char lk[16];
            for (int i = 0; i < 16; i++) lk[i] = 0;
            int64_t r = syscall4(SYS_READLINKAT, (uint64_t)dfd, (uint64_t)"h121-el", (uint64_t)lk, 15);
            check(r == 6 && streq(lk, "h121-e"), "E: readlinkat under the directory fd");
        }
        int64_t ffd = syscall2(SYS_OPEN, (uint64_t)"testdir/h121-e", 0);
        check(syscall4(SYS_OPENAT, (uint64_t)ffd, (uint64_t)"x", O_RDONLY, 0) == -ENOTDIR_, "E: a regular file as dirfd is ENOTDIR");
        check(syscall4(SYS_FACCESSAT, (uint64_t)ffd, (uint64_t)"x", 0, 0) == -ENOTDIR_, "E: faccessat with a file dirfd is ENOTDIR");
        syscall1(SYS_CLOSE, (uint64_t)ffd);
        check(syscall4(SYS_OPENAT, 200, (uint64_t)"h121-e", O_RDONLY, 0) == -EBADF_, "E: a closed dirfd is EBADF");
        check(read_first(syscall4(SYS_OPENAT, 200, (uint64_t)"/testdir/h121-e", O_RDONLY, 0)) == 'E', "E: an absolute name ignores dirfd");

        /* F: fchdir */
        check(syscall1(SYS_FCHDIR, (uint64_t)dfd) == 0 && streq(cwd(), "/testdir"), "F: fchdir into the ext2 directory fd");
        check(first("h121-e") == 'E', "F: relative open after fchdir");
        ffd = syscall2(SYS_OPEN, (uint64_t)"/testdir/h121-e", 0);
        check(syscall1(SYS_FCHDIR, (uint64_t)ffd) == -ENOTDIR_ && streq(cwd(), "/testdir"), "F: fchdir on a regular file is ENOTDIR");
        syscall1(SYS_CLOSE, (uint64_t)ffd);
        syscall1(SYS_CHDIR, (uint64_t)"/");
        syscall1(SYS_UNLINK, (uint64_t)"/testdir/h121-el");
        syscall1(SYS_UNLINK, (uint64_t)"/testdir/h121-e");
        if (dfd >= 0) syscall1(SYS_CLOSE, (uint64_t)dfd);
    }

    /* G: tmpfs directory fd as dirfd */
    {
        int64_t tfd = syscall2(SYS_OPEN, (uint64_t)"/tmp/h121-c", 0);
        check(tfd >= 0, "G: open /tmp/h121-c");
        int64_t f = syscall4(SYS_OPENAT, (uint64_t)tfd, (uint64_t)"g1", O_RDWR_CREAT, 0644);
        if (f >= 0) { syscall3(SYS_WRITE, (uint64_t)f, (uint64_t)"G", 1); syscall1(SYS_CLOSE, (uint64_t)f); }
        check(first("/tmp/h121-c/g1") == 'G', "G: openat(O_CREAT) under a tmpfs directory fd");
        check(syscall3(SYS_MKDIRAT, (uint64_t)tfd, (uint64_t)"gd", 0755) == 0 && mkfile("/tmp/h121-c/gd/f", "h") == 0, "G: mkdirat under a tmpfs directory fd");
        check(syscall3(SYS_UNLINKAT, (uint64_t)tfd, (uint64_t)"gd/f", 0) == 0 && syscall3(SYS_UNLINKAT, (uint64_t)tfd, (uint64_t)"gd", AT_REMOVEDIR) == 0 &&
              !exists("/tmp/h121-c/gd"), "G: unlinkat under a tmpfs directory fd");
        check(syscall1(SYS_FCHDIR, (uint64_t)tfd) == 0 && streq(cwd(), "/tmp/h121-c") && first("g1") == 'G', "G: fchdir into a tmpfs directory fd");
        syscall1(SYS_CHDIR, (uint64_t)"/");
        check(syscall3(SYS_UNLINKAT, (uint64_t)tfd, (uint64_t)"g1", 0) == 0, "G: unlinkat of the file");
        if (tfd >= 0) syscall1(SYS_CLOSE, (uint64_t)tfd);
    }

    /* cleanup */
    syscall1(SYS_CHDIR, (uint64_t)"/");
    syscall1(SYS_UNLINK, (uint64_t)"/testdir/h121-file");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h121-tf");
    syscall1(SYS_RMDIR, (uint64_t)"/tmp/h121-c");

    print(failures == 0 ? "hello121: PASS\n" : "hello121: FAIL\n");
    print("hello121 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
