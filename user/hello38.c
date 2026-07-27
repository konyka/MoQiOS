/// hello38: futex user-word faults must not be mistaken for a zero value.

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

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_MMAP        8
#define SYS_MUNMAP      12
#define SYS_FUTEX       143
#define SYS_FUTEX_WAITV 449

#define FUTEX_WAIT      0
#define PROT_READ       1
#define PROT_WRITE      2
#define MAP_PRIVATE     2
#define MAP_ANONYMOUS   0x20
#define PAGE            4096UL

struct futex_waitv {
    uint64_t val;
    uint64_t uaddr;
    uint32_t flags;
    uint32_t reserved;
};

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello38: FAIL (");
    print(why);
    print(")\nhello38 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    const int64_t page = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (page <= 0) fail("rw mmap");

    if (syscall2(SYS_MUNMAP, (uint64_t)page, PAGE) != 0) fail("munmap");
    if (syscall6(SYS_FUTEX, (uint64_t)page, FUTEX_WAIT, 0, 0, 0, 0) != -14) {
        fail("unmapped futex word EFAULT");
    }

    if (syscall2(SYS_FUTEX_WAITV, 0, 1) != -14) fail("null waiter array EFAULT");
    if (syscall2(SYS_FUTEX_WAITV, 0, 17) != -22) fail("oversized waiter array EINVAL");

    const int64_t array_page = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                        MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (array_page <= 0) fail("array mmap");
    if (syscall2(SYS_FUTEX_WAITV, (uint64_t)array_page + PAGE - 16, 1) != -14) {
        fail("partial waiter record EFAULT");
    }

    const int64_t ro = syscall6(SYS_MMAP, 0, PAGE, PROT_READ,
                                MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (ro <= 0) fail("readonly mmap");
    if (syscall6(SYS_FUTEX, (uint64_t)ro, FUTEX_WAIT, 1, 0, 0, 0) != -11) {
        fail("readonly zero remains readable");
    }

    syscall2(SYS_MUNMAP, (uint64_t)array_page, PAGE);
    syscall2(SYS_MUNMAP, (uint64_t)ro, PAGE);
    print("hello38: PASS (futex EFAULT/waitv validation)\nhello38 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
