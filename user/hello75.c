// hello75 - raw openat2 acceptance for the native and standard syscall numbers.

typedef unsigned long u64;
typedef long s64;

static inline s64 syscall1(u64 nr, u64 a1) {
    s64 ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall4(u64 nr, u64 a1, u64 a2, u64 a3, u64 a4) {
    s64 ret;
    register u64 rdx __asm__("rdx") = a3;
    register u64 r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_CLOSE 11
#define SYS_OPENAT2 320
#define SYS_OPENAT2_ALIAS 437
#define AT_FDCWD ((u64)-100L)
#define EINVAL 22
#define EBADF 9
#define EFAULT 14

struct open_how {
    u64 flags;
    u64 mode;
    u64 resolve;
};

static u64 strlen_raw(const char *s) { u64 n = 0; while (s[n]) n++; return n; }
static void print(const char *s) { syscall4(1, 1, (u64)s, strlen_raw(s), 0); }
static int check(int ok, const char *name) {
    if (!ok) { print("hello75: FAIL "); print(name); print("\n"); return 1; }
    return 0;
}
__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(2, (u64)status);
    for (;;) {}
}

static int check_number(u64 nr) {
    int failures = 0;
    struct open_how how = {0, 0, 0};
    struct open_how resolve = {0, 0, 1};
    struct open_how flags = {1UL << 63, 0, 0};
    const char *path = "hello2";

    s64 fd = syscall4(nr, AT_FDCWD, (u64)path, (u64)&how, sizeof(how));
    failures += check(fd >= 0, "valid existing path");
    if (fd >= 0) failures += check(syscall1(SYS_CLOSE, (u64)fd) == 0, "close valid fd");

    failures += check(syscall4(nr, AT_FDCWD, (u64)path, (u64)&how, sizeof(how) - 1) == -EINVAL,
                      "size below open_how");
    failures += check(syscall4(nr, (u64)-1L, (u64)path, (u64)&how, sizeof(how)) == -EBADF,
                      "invalid dirfd");
    failures += check(syscall4(nr, AT_FDCWD, (u64)path, (u64)&resolve, sizeof(resolve)) == -EINVAL,
                      "nonzero resolve");
    failures += check(syscall4(nr, AT_FDCWD, (u64)path, (u64)&flags, sizeof(flags)) == -EINVAL,
                      "unknown flags");
    failures += check(syscall4(nr, AT_FDCWD, (u64)path, 1, sizeof(how)) == -EFAULT,
                      "invalid how pointer");
    return failures;
}

void _start(void) {
    int failures = 0;
    print("hello75: start\n");
    failures += check_number(SYS_OPENAT2);
    failures += check_number(SYS_OPENAT2_ALIAS);
    if (failures == 0) {
        print("hello75: PASS (strict openat2 #320/#437)\nhello75 done\n");
        exit_raw(0);
    }
    print("hello75: FAIL\nhello75 done\n");
    exit_raw(1);
}
