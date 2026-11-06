// hello82 - raw sched_getaffinity: current-pid rule and the mask size rules. Expected values were measured on Linux with the raw call:
// the size must be a multiple of 8 and not smaller than the kernel mask (0, 1, 4, 7, 9, 127, 129 are EINVAL), 8/16/128/200 return 8
// and write only 8 bytes; an unpinned task reports every configured CPU, so the first byte is 1 only on a one-CPU system.
#include <stdint.h>

static inline int64_t syscall1(uint64_t n, uint64_t a) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall3(uint64_t n, uint64_t a, uint64_t b, uint64_t c) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "r"(x) : "rcx", "r11", "memory");
    return r;
}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_GETPID 4
#define SYS_SCHED_GETAFFINITY 227
#define EFAULT 14
#define ESRCH 3
#define EINVAL 22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello82: FAIL ");
        print(name);
        print("\n");
        return 1;
    }
    return 0;
}

static int all_value(const uint8_t *buf, uint8_t value, uint64_t len) {
    for (uint64_t i = 0; i < len; i++) {
        if (buf[i] != value) return 0;
    }
    return 1;
}

__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(SYS_EXIT, (uint64_t)status);
    for (;;) {}
}

void _start(void) {
    int failures = 0;
    uint8_t mask[129];
    uint8_t sentinel[8];
    uint64_t pid = (uint64_t)syscall1(SYS_GETPID, 0);

    print("hello82: start\n");
    for (uint64_t i = 0; i < sizeof(mask); i++) mask[i] = 0xa5;
    static const uint64_t refused[] = { 0, 1, 4, 7, 9, 15, 127, 129 };
    for (unsigned k = 0; k < sizeof(refused) / sizeof(refused[0]); k++) {
        for (uint64_t i = 0; i < sizeof(mask); i++) mask[i] = 0xa5;
        failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0, refused[k], (uint64_t)mask) == -EINVAL && all_value(mask, 0xa5, sizeof(mask)), "size that is not a multiple of 8, or too small, is EINVAL and writes nothing");
    }
    for (uint64_t i = 0; i < sizeof(mask); i++) mask[i] = 0xa5;
    int64_t own = syscall3(SYS_SCHED_GETAFFINITY, pid, 8, (uint64_t)mask);
    failures += check(own == 8 && (mask[0] & 1) == 1 && all_value(mask + 8, 0xa5, sizeof(mask) - 8), "current pid, 8 bytes: 8 returned, CPU 0 in the mask, nothing written past it");
    static const uint64_t accepted[] = { 8, 16, 128 };
    for (unsigned k = 0; k < sizeof(accepted) / sizeof(accepted[0]); k++) {
        for (uint64_t i = 0; i < sizeof(mask); i++) mask[i] = 0xa5;
        failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0, accepted[k], (uint64_t)mask) == 8 && all_value(mask + 8, 0xa5, sizeof(mask) - 8), "a larger multiple of 8 returns 8 and writes only 8 bytes");
    }
    for (uint64_t i = 0; i < sizeof(sentinel); i++) sentinel[i] = 0x5a;
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0x7fffffff, sizeof(sentinel), (uint64_t)sentinel) == -ESRCH && all_value(sentinel, 0x5a, sizeof(sentinel)), "invalid pid no mutation");
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 1, sizeof(sentinel), (uint64_t)sentinel) == -ESRCH && all_value(sentinel, 0x5a, sizeof(sentinel)), "noncurrent pid no mutation");
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0, sizeof(sentinel), 0) == -EFAULT, "bad pointer");
    if (!failures) print("hello82: PASS (sched_getaffinity current-pid contract)\nhello82 done\n");
    else print("hello82: FAIL\nhello82 done\n");
    exit_raw(failures != 0);
}
