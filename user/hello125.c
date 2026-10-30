/// hello125: statx(2) fields and flags.
///
///   A. ext2: mask claims the timestamp and block bits and the values match
///      utimensat; blocks > 0 for a file with data; size/nlink/mode right.
///   B. AT_EMPTY_PATH describes dirfd itself (also a directory fd); without
///      it an empty name is ENOENT; a bad fd is EBADF.
///   C. AT_SYMLINK_NOFOLLOW describes a final symlink (S_IFLNK) and the
///      default follows it; unknown flags and the reserved mask bit EINVAL.
///   D. tmpfs reports mode/size but its mask does not claim timestamps or
///      blocks (the bytes stay zero instead of a fake epoch time).

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
#define SYS_CLOSE     11
#define SYS_UNLINK    87
#define SYS_SYMLINK   88
#define SYS_STATX     183
#define SYS_UTIMENSAT 489
#define AT_FDCWD      ((uint64_t)-100)
#define AT_SYMLINK_NOFOLLOW 0x100
#define AT_EMPTY_PATH       0x1000
#define O_RDWR_CREAT  0x42

#define STATX_ATIME  0x20
#define STATX_MTIME  0x40
#define STATX_CTIME  0x80
#define STATX_BLOCKS 0x400
#define STATX_SIZE   0x200
#define STATX_MODE   0x2

#define ENOENT_ 2
#define EBADF_  9
#define EINVAL_ 22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello125:   ok   " : "hello125:   FAIL ");
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
/* struct statx views */
static uint32_t mask_of(const uint8_t *b) { return *(const uint32_t *)b; }
static uint32_t nlink_of(const uint8_t *b) { return *(const uint32_t *)(b + 16); }
static uint16_t mode_of(const uint8_t *b) { return *(const uint16_t *)(b + 28); }
static uint64_t size_of(const uint8_t *b) { return *(const uint64_t *)(b + 40); }
static uint64_t blocks_of(const uint8_t *b) { return *(const uint64_t *)(b + 48); }
static uint64_t atime_of(const uint8_t *b) { return *(const uint64_t *)(b + 64); }
static uint64_t ctime_of(const uint8_t *b) { return *(const uint64_t *)(b + 96); }
static uint64_t mtime_of(const uint8_t *b) { return *(const uint64_t *)(b + 112); }

static uint8_t sx[144];
static int64_t sx_call(uint64_t dirfd, const char *path, uint64_t flags, uint64_t mask) {
    for (int i = 0; i < 144; i++) sx[i] = 0xEE;
    return syscall5(SYS_STATX, dirfd, (uint64_t)path, flags, mask, (uint64_t)sx);
}
struct ts { int64_t sec, nsec; };

void _start(void) {
    print("hello125: statx\n");
    mkfile("testdir/h125", "hello");

    /* A */
    struct ts t[2] = { { 1111111, 0 }, { 2222222, 0 } };
    syscall4(SYS_UTIMENSAT, AT_FDCWD, (uint64_t)"testdir/h125", (uint64_t)t, 0);
    check(sx_call(AT_FDCWD, "testdir/h125", 0, 0x7ff) == 0, "A: statx of an ext2 file");
    check((mask_of(sx) & (STATX_ATIME | STATX_MTIME | STATX_CTIME | STATX_BLOCKS | STATX_SIZE | STATX_MODE)) ==
          (STATX_ATIME | STATX_MTIME | STATX_CTIME | STATX_BLOCKS | STATX_SIZE | STATX_MODE), "A: the mask claims times, blocks, size and mode");
    check(atime_of(sx) == 1111111 && mtime_of(sx) == 2222222, "A: atime and mtime match utimensat");
    check(ctime_of(sx) > 2222222, "A: ctime is the time of the change");
    check(size_of(sx) == 5 && nlink_of(sx) == 1 && (mode_of(sx) & 0170000) == 0100000, "A: size, nlink and file type");
    check(blocks_of(sx) > 0, "A: blocks are reported for a file with data");

    /* B */
    {
        int64_t fd = syscall2(SYS_OPEN, (uint64_t)"testdir/h125", 0);
        check(fd >= 0 && sx_call((uint64_t)fd, "", AT_EMPTY_PATH, 0x7ff) == 0 && size_of(sx) == 5 && mtime_of(sx) == 2222222, "B: AT_EMPTY_PATH describes the descriptor itself");
        if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
        int64_t dfd = syscall2(SYS_OPEN, (uint64_t)"testdir", 0);
        check(dfd >= 0 && sx_call((uint64_t)dfd, "", AT_EMPTY_PATH, 0x7ff) == 0 && (mode_of(sx) & 0170000) == 0040000, "B: and a directory descriptor (S_IFDIR)");
        check(dfd >= 0 && sx_call((uint64_t)dfd, "h125", 0, 0x7ff) == 0 && size_of(sx) == 5, "B: a name under the directory fd");
        if (dfd >= 0) syscall1(SYS_CLOSE, (uint64_t)dfd);
    }
    check(sx_call(AT_FDCWD, "", 0, 0x7ff) == -ENOENT_, "B: an empty name without AT_EMPTY_PATH is ENOENT");
    check(sx_call(200, "", AT_EMPTY_PATH, 0x7ff) == -EBADF_, "B: AT_EMPTY_PATH on a closed fd is EBADF");

    /* C */
    syscall2(SYS_SYMLINK, (uint64_t)"h125", (uint64_t)"testdir/h125-l");
    check(sx_call(AT_FDCWD, "testdir/h125-l", 0, 0x7ff) == 0 && (mode_of(sx) & 0170000) == 0100000 && size_of(sx) == 5, "C: the default follows the symlink");
    check(sx_call(AT_FDCWD, "testdir/h125-l", AT_SYMLINK_NOFOLLOW, 0x7ff) == 0 && (mode_of(sx) & 0170000) == 0120000, "C: AT_SYMLINK_NOFOLLOW describes the link itself (S_IFLNK)");
    check(sx_call(AT_FDCWD, "testdir/h125", 0x2, 0x7ff) == -EINVAL_, "C: unknown flags are EINVAL");
    check(sx_call(AT_FDCWD, "testdir/h125", 0, 0x80000000u) == -EINVAL_, "C: the reserved mask bit is EINVAL");

    /* D */
    mkfile("/tmp/h125-t", "tmp");
    check(sx_call(AT_FDCWD, "/tmp/h125-t", 0, 0x7ff) == 0 && size_of(sx) == 3 && (mode_of(sx) & 0170000) == 0100000, "D: tmpfs reports size and type");
    check((mask_of(sx) & (STATX_ATIME | STATX_MTIME | STATX_CTIME | STATX_BLOCKS)) == 0 && mtime_of(sx) == 0, "D: but does not claim timestamps or blocks");

    syscall1(SYS_UNLINK, (uint64_t)"testdir/h125-l");
    syscall1(SYS_UNLINK, (uint64_t)"testdir/h125");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h125-t");

    print(failures == 0 ? "hello125: PASS\n" : "hello125: FAIL\n");
    print("hello125 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
