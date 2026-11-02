/// hello197: gettimeofday/time-of-day pointer errnos, checked against real Linux (host gcc run).
/// Linux: a bad tv is EFAULT, a bad tz is EFAULT even when tv is fine or NULL, tz is written on success
/// (tz_minuteswest = 0, tz_dsttime = 0 on a UTC kernel), and NULL/NULL succeeds.

#include <stdint.h>

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_GETTIMEOFDAY 96
#define KP 0xffff800000000000ULL

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello197:   ok   " : "hello197:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

void _start(void) {
    print("hello197: gettimeofday pointer conformance (expected values from real Linux)\n");
    int64_t tv[2] = { -1, -1 };
    int32_t tz[2] = { 7, 7 };

    check(syscall2(SYS_GETTIMEOFDAY, (uint64_t)tv, 0) == 0 && tv[0] > 1500000000LL, "tv ok, tz NULL");
    check(syscall2(SYS_GETTIMEOFDAY, 0, 0) == 0, "tv NULL, tz NULL");
    check(syscall2(SYS_GETTIMEOFDAY, 1, 0) == -14, "bad tv is EFAULT");
    check(syscall2(SYS_GETTIMEOFDAY, KP, 0) == -14, "kernel-half tv is EFAULT");
    check(syscall2(SYS_GETTIMEOFDAY, (uint64_t)tv, 1) == -14, "good tv, bad tz is EFAULT");
    check(syscall2(SYS_GETTIMEOFDAY, 0, 1) == -14, "NULL tv, bad tz is EFAULT");
    check(syscall2(SYS_GETTIMEOFDAY, 0, KP) == -14, "NULL tv, kernel-half tz is EFAULT");
    check(syscall2(SYS_GETTIMEOFDAY, 1, 1) == -14, "both bad is EFAULT");

    check(syscall2(SYS_GETTIMEOFDAY, (uint64_t)tv, (uint64_t)tz) == 0, "good tv and tz");
    check(tz[0] == 0 && tz[1] == 0, "tz is written (minuteswest 0, dsttime 0)");
    tz[0] = 7; tz[1] = 7;
    check(syscall2(SYS_GETTIMEOFDAY, 0, (uint64_t)tz) == 0, "NULL tv with good tz succeeds");
    check(tz[0] == 0 && tz[1] == 0, "tz is written even when tv is NULL");

    if (failures == 0) print("hello197: PASS\n");
    else print("hello197: FAIL\n");
    syscall2(2, failures ? 1 : 0, 0);
    for (;;) {}
}
