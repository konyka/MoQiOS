/// hello126: access(2) / faccessat(2) / faccessat2(2) on ext2 and tmpfs.
///
///   A. Mode bits are judged, not just "can it be opened": a 0640 file the
///      caller owns allows R and W but refuses X (EACCES); F_OK needs only
///      existence; a mode with bits beyond R/W/X is EINVAL; a missing file
///      is ENOENT; a root-owned 0600 file refuses uid 1000 for R and W.
///   B. tmpfs gets the same treatment.
///   C. Real vs effective ids (child of this uid-0 program): with real uid
///      1000 and effective uid 0, access() judges as 1000 (R_OK on a
///      0600 root file is EACCES) while faccessat2(AT_EACCESS) judges as
///      the effective uid (allowed).
///   D. faccessat2 flags: unknown bits EINVAL; AT_EMPTY_PATH checks the fd;
///      a name under a directory fd works.

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
#define SYS_UNLINK    87
#define SYS_CHMOD     90
#define SYS_ACCESS    198
#define SYS_FACCESSAT 258
#define SYS_FACCESSAT2 321
#define SYS_SETRESUID 178
#define AT_FDCWD      ((uint64_t)-100)
#define AT_EACCESS    0x200
#define AT_EMPTY_PATH 0x1000
#define O_RDWR_CREAT  0x42
#define KEEP          ((uint64_t)-1)

#define ENOENT_ 2
#define EACCES_ 13
#define EINVAL_ 22
#define R_OK 4
#define W_OK 2
#define X_OK 1

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello126:   ok   " : "hello126:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t mkfile(const char *path, int mode) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, O_RDWR_CREAT, 0644);
    if (fd < 0) return fd;
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return syscall2(SYS_CHMOD, (uint64_t)path, (uint64_t)mode);
}
static int64_t acc(const char *p, int mode) { return syscall2(SYS_ACCESS, (uint64_t)p, (uint64_t)mode); }

void _start(void) {
    print("hello126: access/faccessat/faccessat2\n");
    mkfile("testdir/h126-a", 0640);
    mkfile("testdir/h126-x", 0755);
    mkfile("testdir/h126-r", 0600);
    mkfile("/tmp/h126-t", 0640);

    /* A (running as root with only the ID capabilities: no DAC override) */
    check(acc("testdir/h126-a", 0) == 0, "A: F_OK on an existing file");
    check(acc("testdir/h126-a", R_OK | W_OK) == 0, "A: R and W on an owned 0640 file");
    check(acc("testdir/h126-a", X_OK) == -EACCES_, "A: X on a 0640 file is EACCES");
    check(acc("testdir/h126-x", X_OK) == 0, "A: X on a 0755 file");
    check(acc("testdir/h126-a", 8) == -EINVAL_, "A: a mode beyond R/W/X is EINVAL");
    check(acc("testdir/h126-nope", R_OK) == -ENOENT_, "A: a missing file is ENOENT");

    /* B */
    check(acc("/tmp/h126-t", R_OK | W_OK) == 0, "B: tmpfs R and W on an owned file");
    check(acc("/tmp/h126-t", X_OK) == -EACCES_, "B: tmpfs X on a 0640 file is EACCES");
    check(acc("/tmp/h126-nope", R_OK) == -ENOENT_, "B: a missing tmpfs file is ENOENT");

    /* C: real uid 1000, effective uid 0 */
    {
        int64_t pid = syscall1(SYS_FORK, 0);
        if (pid == 0) {
            int bits = 0;
            if (syscall3(SYS_SETRESUID, 1000, 0, 0) != 0) syscall1(SYS_EXIT, 255);
            /* the root-owned 0600 file: real uid 1000 may not read it */
            if (acc("testdir/h126-r", R_OK) == -EACCES_) bits |= 1;
            if (syscall4(SYS_FACCESSAT2, AT_FDCWD, (uint64_t)"testdir/h126-r", R_OK, AT_EACCESS) == 0) bits |= 2;
            if (syscall4(SYS_FACCESSAT, AT_FDCWD, (uint64_t)"testdir/h126-r", R_OK, 0) == -EACCES_) bits |= 4;
            if (acc("testdir/h126-r", 0) == 0) bits |= 8;
            syscall1(SYS_EXIT, (uint64_t)bits);
            for (;;) {}
        }
        int status = 0;
        syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0);
        int bits = (status >> 8) & 0xff;
        check(bits & 1, "C: access() judges as the real uid (EACCES for a root-only file)");
        check(bits & 2, "C: faccessat2 with AT_EACCESS judges as the effective uid");
        check(bits & 4, "C: faccessat without flags judges as the real uid");
        check(bits & 8, "C: F_OK still only needs existence");
    }

    /* D */
    check(syscall4(SYS_FACCESSAT2, AT_FDCWD, (uint64_t)"testdir/h126-a", R_OK, 0x4) == -EINVAL_, "D: unknown flags are EINVAL");
    {
        int64_t fd = syscall2(SYS_OPEN, (uint64_t)"testdir/h126-a", 0);
        check(fd >= 0 && syscall4(SYS_FACCESSAT2, (uint64_t)fd, (uint64_t)"", R_OK, AT_EMPTY_PATH) == 0, "D: AT_EMPTY_PATH checks the descriptor (R ok)");
        check(fd >= 0 && syscall4(SYS_FACCESSAT2, (uint64_t)fd, (uint64_t)"", X_OK, AT_EMPTY_PATH) == -EACCES_, "D: AT_EMPTY_PATH checks the descriptor (X denied)");
        check(syscall4(SYS_FACCESSAT2, AT_FDCWD, (uint64_t)"", R_OK, 0) == -ENOENT_, "D: an empty name without AT_EMPTY_PATH is ENOENT");
        if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
        int64_t dfd = syscall2(SYS_OPEN, (uint64_t)"testdir", 0);
        check(dfd >= 0 && syscall4(SYS_FACCESSAT2, (uint64_t)dfd, (uint64_t)"h126-x", X_OK, 0) == 0, "D: a name under a directory fd");
        if (dfd >= 0) syscall1(SYS_CLOSE, (uint64_t)dfd);
    }

    syscall1(SYS_UNLINK, (uint64_t)"testdir/h126-a");
    syscall1(SYS_UNLINK, (uint64_t)"testdir/h126-x");
    syscall1(SYS_UNLINK, (uint64_t)"testdir/h126-r");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h126-t");

    print(failures == 0 ? "hello126: PASS\n" : "hello126: FAIL\n");
    print("hello126 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
