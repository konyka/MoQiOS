// hello82 - raw sched_getaffinity current-pid and single-CPU mask boundary.
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

static int cpu0_mask(const uint8_t *buf, uint64_t len) {
    if (len == 0 || buf[0] != 1) return 0;
    return all_value(buf + 1, 0, len - 1);
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
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0, 0, (uint64_t)mask) == 0, "pid zero size zero");
    failures += check(all_value(mask, 0xa5, sizeof(mask)), "size zero preserves mask");
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, pid, 1, (uint64_t)mask) == 1 && cpu0_mask(mask, 1), "current pid cpu zero");
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0, 127, (uint64_t)mask) == 127 && cpu0_mask(mask, 127), "size 127");
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0, 128, (uint64_t)mask) == 128 && cpu0_mask(mask, 128), "size 128");
    mask[128] = 0xa5;
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0, 129, (uint64_t)mask) == 128 && cpu0_mask(mask, 128) && mask[128] == 0xa5, "size 129 capped");

    for (uint64_t i = 0; i < sizeof(sentinel); i++) sentinel[i] = 0x5a;
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0x7fffffff, sizeof(sentinel), (uint64_t)sentinel) == -ESRCH && all_value(sentinel, 0x5a, sizeof(sentinel)), "invalid pid no mutation");
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 1, sizeof(sentinel), (uint64_t)sentinel) == -ESRCH && all_value(sentinel, 0x5a, sizeof(sentinel)), "noncurrent pid no mutation");
    failures += check(syscall3(SYS_SCHED_GETAFFINITY, 0, sizeof(sentinel), 0) == -EFAULT, "bad pointer");
    if (!failures) print("hello82: PASS (sched_getaffinity current-pid contract)\nhello82 done\n");
    else print("hello82: FAIL\nhello82 done\n");
    exit_raw(failures != 0);
}
