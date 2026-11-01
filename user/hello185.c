/// hello185: file-descriptor and path errno conformance, checked against real Linux.

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
#define SYS_PIPE      22
#define SYS_DUP2      33
#define SYS_RT_SIGACTION 13
#define SYS_GETCWD    79
#define SYS_CHDIR     80
#define SYS_RENAME    82
#define SYS_MKDIR     83
#define SYS_RMDIR     84
#define SYS_UNLINK    87
#define SYS_FSTAT     110
#define SYS_FCNTL     142
#define SYS_LSEEK     197
#define SYS_FTRUNCATE 211
#define SYS_DUP       32
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2
#define O_CREAT  0x40
#define O_EXCL   0x80
#define O_DIRECTORY 0x10000
#define F_DUPFD 0
#define F_GETFD 1
#define EPERM_ 1
#define ENOENT_ 2
#define EBADF_ 9
#define EEXIST_ 17
#define ENOTDIR_ 20
#define EISDIR_ 21
#define EINVAL_ 22
#define ESPIPE_ 29
#define EPIPE_ 32
#define ENOTEMPTY_ 39

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello185:   ok   " : "hello185:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void print_num(const char *label, int64_t x) {
    char r[24]; int m = 0; char o[40]; int k = 0;
    print(label);
    if (x < 0) { o[k++] = '-'; x = -x; }
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k++] = '\n'; o[k] = 0;
    print(o);
}
/* check that call `v` returned -errno */
static void expect(int64_t v, int64_t errno_, const char *what) {
    if (v != -errno_) { print("hello185:   got "); print_num("", v); }
    check(v == -errno_, what);
}

void _start(void) {
    print("hello185: fd/path errno conformance (expected values from real Linux)\n");
    uint64_t act[4] = { 1, 0, 0, 0 }; /* SIGPIPE ignored */
    syscall4(SYS_RT_SIGACTION, 13, (uint64_t)act, 0, 8);
    char b[16];
    const char *F = "/tmp/h185f", *D = "/tmp/h185d", *Z = "/tmp/h185d/z";
    syscall1(SYS_UNLINK, (uint64_t)Z);
    syscall1(SYS_RMDIR, (uint64_t)D);
    syscall1(SYS_UNLINK, (uint64_t)F);
    syscall2(SYS_MKDIR, (uint64_t)D, 0755);
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)F, O_CREAT | O_RDWR, 0644);
    check(fd >= 0, "setup: create a file");
    syscall3(SYS_WRITE, fd, (uint64_t)"hello", 5);

    /* open */
    expect(syscall3(SYS_OPEN, (uint64_t)F, O_CREAT | O_EXCL | O_RDWR, 0644), EEXIST_, "open(O_CREAT|O_EXCL) on an existing file is EEXIST");
    expect(syscall3(SYS_OPEN, (uint64_t)"/tmp/h185-nope", O_RDONLY, 0), ENOENT_, "open of a missing file is ENOENT");
    expect(syscall3(SYS_OPEN, (uint64_t)D, O_WRONLY, 0), EISDIR_, "open(directory, O_WRONLY) is EISDIR");
    expect(syscall3(SYS_OPEN, (uint64_t)F, O_RDONLY | O_DIRECTORY, 0), ENOTDIR_, "open(file, O_DIRECTORY) is ENOTDIR");
    expect(syscall3(SYS_OPEN, (uint64_t)"", O_RDONLY, 0), ENOENT_, "open(\"\") is ENOENT");
    expect(syscall3(SYS_OPEN, (uint64_t)"/tmp/h185f/x", O_RDONLY, 0), ENOTDIR_, "open of a path through a file is ENOTDIR");

    /* read/write permission by open mode, and on a directory */
    int64_t ro = syscall3(SYS_OPEN, (uint64_t)F, O_RDONLY, 0);
    int64_t wo = syscall3(SYS_OPEN, (uint64_t)F, O_WRONLY, 0);
    int64_t dfd = syscall3(SYS_OPEN, (uint64_t)D, O_RDONLY, 0);
    expect(syscall3(SYS_WRITE, ro, (uint64_t)"x", 1), EBADF_, "write on an O_RDONLY fd is EBADF");
    expect(syscall3(SYS_READ, wo, (uint64_t)b, 4), EBADF_, "read on an O_WRONLY fd is EBADF");
    expect(syscall3(SYS_READ, dfd, (uint64_t)b, 4), EISDIR_, "read on a directory is EISDIR");
    expect(syscall3(SYS_WRITE, dfd, (uint64_t)"x", 1), EBADF_, "write on a directory opened read-only is EBADF");
    expect(syscall3(SYS_READ, 99, (uint64_t)b, 1), EBADF_, "read on a bad fd is EBADF");
    expect(syscall3(SYS_WRITE, 99, (uint64_t)"x", 1), EBADF_, "write on a bad fd is EBADF");

    /* lseek */
    expect(syscall3(SYS_LSEEK, fd, (uint64_t)-1, 0), EINVAL_, "lseek to a negative offset is EINVAL");
    expect(syscall3(SYS_LSEEK, fd, 2, 9), EINVAL_, "lseek with a bad whence is EINVAL");
    int pv[2];
    syscall1(SYS_PIPE, (uint64_t)pv);
    expect(syscall3(SYS_LSEEK, pv[0], 0, 0), ESPIPE_, "lseek on a pipe is ESPIPE");

    /* close / dup / fcntl */
    expect(syscall1(SYS_CLOSE, 99), EBADF_, "close of a bad fd is EBADF");
    check(syscall1(SYS_CLOSE, wo) == 0, "close of an open fd succeeds");
    expect(syscall1(SYS_CLOSE, wo), EBADF_, "closing it again is EBADF");
    expect(syscall1(SYS_DUP, 99), EBADF_, "dup of a bad fd is EBADF");
    expect(syscall2(SYS_DUP2, 99, 5), EBADF_, "dup2 from a bad fd is EBADF");
    check(syscall2(SYS_DUP2, fd, fd) == fd, "dup2(fd, fd) returns fd");
    expect(syscall2(SYS_DUP2, fd, (uint64_t)-1), EBADF_, "dup2 to fd -1 is EBADF");
    expect(syscall3(SYS_FCNTL, 99, F_GETFD, 0), EBADF_, "fcntl on a bad fd is EBADF");
    check(syscall3(SYS_FCNTL, fd, F_DUPFD, 5) >= 5, "fcntl(F_DUPFD, 5) returns a fd >= 5");
    expect(syscall3(SYS_FCNTL, fd, 9999, 0), EINVAL_, "fcntl with an unknown command is EINVAL");

    /* pipes */
    syscall1(SYS_CLOSE, pv[0]);
    expect(syscall3(SYS_WRITE, pv[1], (uint64_t)"x", 1), EPIPE_, "write to a pipe whose read end is closed is EPIPE");

    /* zero-length and truncate */
    check(syscall3(SYS_READ, fd, (uint64_t)b, 0) == 0, "read of 0 bytes returns 0");
    check(syscall3(SYS_WRITE, fd, (uint64_t)b, 0) == 0, "write of 0 bytes returns 0");
    expect(syscall2(SYS_FTRUNCATE, ro, 0), EINVAL_, "ftruncate on a read-only fd is EINVAL");
    expect(syscall2(SYS_FTRUNCATE, fd, (uint64_t)-1), EINVAL_, "ftruncate to a negative length is EINVAL");
    expect(syscall2(SYS_FSTAT, 99, (uint64_t)b), EBADF_, "fstat of a bad fd is EBADF");

    /* directories and names */
    expect(syscall2(SYS_MKDIR, (uint64_t)D, 0755), EEXIST_, "mkdir of an existing directory is EEXIST");
    int64_t z = syscall3(SYS_OPEN, (uint64_t)Z, O_CREAT | O_RDWR, 0644);
    if (z >= 0) syscall1(SYS_CLOSE, z);
    expect(syscall1(SYS_RMDIR, (uint64_t)D), ENOTEMPTY_, "rmdir of a non-empty directory is ENOTEMPTY");
    expect(syscall1(SYS_RMDIR, (uint64_t)F), ENOTDIR_, "rmdir of a file is ENOTDIR");
    expect(syscall1(SYS_UNLINK, (uint64_t)D), EISDIR_, "unlink of a directory is EISDIR");
    expect(syscall1(SYS_UNLINK, (uint64_t)"/tmp/h185-nope"), ENOENT_, "unlink of a missing file is ENOENT");
    expect(syscall2(SYS_RENAME, (uint64_t)"/tmp/h185-nope", (uint64_t)"/tmp/h185-n2"), ENOENT_, "rename of a missing file is ENOENT");
    expect(syscall1(SYS_CHDIR, (uint64_t)F), ENOTDIR_, "chdir to a file is ENOTDIR");
    expect(syscall1(SYS_CHDIR, (uint64_t)"/tmp/h185-nope"), ENOENT_, "chdir to a missing directory is ENOENT");

    syscall1(SYS_UNLINK, (uint64_t)Z);
    syscall1(SYS_RMDIR, (uint64_t)D);
    syscall1(SYS_UNLINK, (uint64_t)F);
    print(failures == 0 ? "hello185: PASS\n" : "hello185: FAIL\n");
    print("hello185 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
