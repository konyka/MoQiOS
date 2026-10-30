/// hello129: descriptor semantics on ext2 and tmpfs: lseek, pread/pwrite,
/// ftruncate, O_APPEND, O_TRUNC and offsets shared through dup.

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
#define SYS_WAITPID   6
#define SYS_FORK      57
#define SYS_CLOSE     11
#define SYS_FSTAT     110
#define SYS_UNLINK    87
#define SYS_FTRUNCATE 77
#define SYS_PREAD     136
#define SYS_PWRITE    137
#define SYS_DUP       160
#define SYS_LSEEK     197
#define O_RDWR_CREAT  0x42
#define O_RDONLY      0
#define O_RDWR        2
#define O_TRUNC       0x200
#define O_APPEND      0x400
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define EBADF_  9
#define EINVAL_ 22
#define ESPIPE_ 29
#define EFBIG_  27

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello129:   ok   " : "hello129:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t size_of(int64_t fd) {
    uint64_t st[18];
    for (int i = 0; i < 18; i++) st[i] = 0;
    if (syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)st) != 0) return -1;
    return (int64_t)st[6];
}
static int64_t wr(int64_t fd, const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    return syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)s, n);
}

static void suite(const char *tag, const char *path) {
    print("hello129: -- "); print(tag); print("\n");
    syscall1(SYS_UNLINK, (uint64_t)path);
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR_CREAT, 0644);
    check(fd >= 0, "create");
    check(wr(fd, "0123456789") == 10, "write 10 bytes");
    char b[16];
    for (int i = 0; i < 16; i++) b[i] = 0;

    /* lseek */
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_CUR) == 10, "lseek(SEEK_CUR, 0) is the write position");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 3, SEEK_SET) == 3, "lseek SEEK_SET");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 2, SEEK_CUR) == 5, "lseek SEEK_CUR");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, (uint64_t)-4, SEEK_END) == 6, "lseek SEEK_END with a negative offset");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, (uint64_t)-1, SEEK_SET) == -EINVAL_, "lseek to a negative position is EINVAL");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, 9) == -EINVAL_, "lseek with an unknown whence is EINVAL");
    check(syscall3(SYS_LSEEK, 999, 0, SEEK_SET) == -EBADF_, "lseek on a bad fd is EBADF");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 20, SEEK_SET) == 20, "lseek past the end is allowed");
    check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)b, 4) == 0, "read past the end is 0");

    /* a hole: write after seeking past the end */
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 14, SEEK_SET) == 14 && wr(fd, "Z") == 1 && size_of(fd) == 15, "write past the end extends the file");
    check(syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)b, 5, 10) == 5 && b[0] == 0 && b[3] == 0 && b[4] == 'Z', "the gap reads as zeros");

    /* pread / pwrite do not move the offset */
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 1, SEEK_SET) == 1, "position at 1");
    check(syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)b, 3, 5) == 3 && b[0] == '5' && b[2] == '7', "pread reads at its own offset");
    check(syscall4(SYS_PWRITE, (uint64_t)fd, (uint64_t)"AB", 2, 0) == 2, "pwrite at 0");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_CUR) == 1, "pread/pwrite leave the file offset alone");
    check(syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)b, 3, (uint64_t)-1) == -EINVAL_, "pread at a negative offset is EINVAL");

    /* ftruncate */
    check(syscall2(SYS_FTRUNCATE, (uint64_t)fd, 4) == 0 && size_of(fd) == 4, "ftruncate shrinks");
    check(syscall2(SYS_FTRUNCATE, (uint64_t)fd, 8) == 0 && size_of(fd) == 8, "ftruncate grows");
    check(syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)b, 4, 4) == 4 && b[0] == 0 && b[3] == 0, "the grown part reads as zeros");
    check(syscall2(SYS_FTRUNCATE, (uint64_t)fd, (uint64_t)-1) == -EINVAL_, "ftruncate to a negative length is EINVAL");
    check(syscall2(SYS_FTRUNCATE, 999, 0) == -EBADF_, "ftruncate of a bad fd is EBADF");

    /* dup shares the offset */
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_SET) == 0, "rewind");
    int64_t d = syscall1(SYS_DUP, (uint64_t)fd);
    check(d >= 0, "dup");
    check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)b, 2) == 2, "read 2 through the original");
    check(syscall3(SYS_LSEEK, (uint64_t)d, 0, SEEK_CUR) == 2, "the dup shares the offset");
    check(syscall3(SYS_READ, (uint64_t)d, (uint64_t)b, 1) == 1 && syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_CUR) == 3, "reading through the dup moves the original too");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 6, SEEK_SET) == 6 && syscall3(SYS_LSEEK, (uint64_t)d, 0, SEEK_CUR) == 6, "lseek through the original moves the dup");

    /* an independent open() of the same file keeps its own offset */
    {
        int64_t other = syscall3(SYS_OPEN, (uint64_t)path, O_RDONLY, 0);
        check(other >= 0 && syscall3(SYS_LSEEK, (uint64_t)other, 0, SEEK_CUR) == 0, "a separate open() starts at 0, not at the dup's offset");
        if (other >= 0) syscall1(SYS_CLOSE, (uint64_t)other);
    }
    /* after the dup is closed the original still works and keeps the position */
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_CUR) == 6, "the position survives closing the dup (checked before close)");
    syscall1(SYS_CLOSE, (uint64_t)d);
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_CUR) == 6, "and after it");
    check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)b, 1) == 1, "reads keep working");
    /* fork: parent and child share the description */
    {
        check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_SET) == 0, "rewind before fork");
        int64_t pid = syscall1(SYS_FORK, 0);
        if (pid == 0) {
            char c[2];
            syscall3(SYS_READ, (uint64_t)fd, (uint64_t)c, 2);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        int status = 0;
        syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0);
        check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_CUR) == 2, "a read in the forked child moves the parent's offset");
    }
    syscall1(SYS_CLOSE, (uint64_t)fd);

    /* O_APPEND and O_TRUNC */
    fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR | O_APPEND, 0);
    check(fd >= 0 && syscall3(SYS_LSEEK, (uint64_t)fd, 0, SEEK_SET) == 0 && wr(fd, "TAIL") == 4 && size_of(fd) == 12, "O_APPEND writes at the end regardless of the offset");
    check(syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)b, 4, 8) == 4 && b[0] == 'T' && b[3] == 'L', "the appended bytes are at the end");
    syscall1(SYS_CLOSE, (uint64_t)fd);
    fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR | O_TRUNC, 0);
    check(fd >= 0 && size_of(fd) == 0, "O_TRUNC empties the file");
    check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)b, 4) == 0, "and reads 0 bytes");
    syscall1(SYS_CLOSE, (uint64_t)fd);

    /* a read-only descriptor */
    fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDONLY, 0);
    check(fd >= 0 && syscall2(SYS_FTRUNCATE, (uint64_t)fd, 0) < 0, "ftruncate through a read-only descriptor fails");
    syscall1(SYS_CLOSE, (uint64_t)fd);
    syscall1(SYS_UNLINK, (uint64_t)path);
}

void _start(void) {
    print("hello129: descriptor semantics\n");
    suite("ext2", "/testdir/h129");
    suite("tmpfs", "/tmp/h129");
    print(failures == 0 ? "hello129: PASS\n" : "hello129: FAIL\n");
    print("hello129 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
