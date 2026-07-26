/// hello37: audit regressions for user output, fd bounds, poll, and mmap metadata.

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

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE   1
#define SYS_MMAP    8
#define SYS_CLOSE   11
#define SYS_MUNMAP  12
#define SYS_DUP2    33
#define SYS_FCNTL   72
#define SYS_GETCWD  109
#define SYS_FSTAT   110
#define SYS_POLL    162
#define SYS_IOCTL   165
#define SYS_EXIT    2

#define PROT_READ       1
#define MAP_PRIVATE     2
#define MAP_ANONYMOUS   0x20
#define F_GETFD         1
#define TIOCGWINSZ      0x5413
#define PAGE            4096UL
#define SPARSE_BASE     0x0000000300000000UL

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello37: FAIL (");
    print(why);
    print(")\nhello37 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    const int64_t ro = syscall6(SYS_MMAP, 0, PAGE, PROT_READ,
                                MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (ro <= 0) fail("readonly mmap");

    if (syscall2(SYS_GETCWD, (uint64_t)ro, PAGE) != -14) fail("getcwd EFAULT");
    if (syscall2(SYS_FSTAT, 1, (uint64_t)ro) != -14) fail("fstat EFAULT");
    if (syscall3(SYS_IOCTL, 1, TIOCGWINSZ, (uint64_t)ro) != -14) fail("ioctl EFAULT");
    if (syscall3(SYS_POLL, (uint64_t)ro, 1, 0) != -14) fail("poll EFAULT");

    if (syscall2(SYS_DUP2, 1, 40) != 40) fail("dup2 high fd");
    if (syscall3(SYS_FCNTL, 40, F_GETFD, 0) < 0) fail("fcntl high fd");
    syscall1(SYS_CLOSE, 40);

    uint64_t mapped[63];
    for (uint64_t i = 0; i < 63; i++) {
        const uint64_t hint = SPARSE_BASE + i * 2 * PAGE;
        const int64_t p = syscall6(SYS_MMAP, hint, PAGE, PROT_READ,
                                   MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (p != (int64_t)hint) fail("sparse mmap");
        mapped[i] = (uint64_t)p;
    }

    const uint64_t overflow_hint = SPARSE_BASE + 63 * 2 * PAGE;
    if (syscall6(SYS_MMAP, overflow_hint, PAGE, PROT_READ,
                 MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0) != -12) {
        fail("mmap metadata ENOMEM");
    }

    for (uint64_t i = 0; i < 63; i++) syscall2(SYS_MUNMAP, mapped[i], PAGE);
    syscall2(SYS_MUNMAP, (uint64_t)ro, PAGE);

    print("hello37: PASS (EFAULT/fd/mmap/poll)\nhello37 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
