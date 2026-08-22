// hello74 - raw mprotect transaction and ordinary-page COW acceptance.

typedef unsigned long u64;
typedef long s64;

static inline s64 syscall1(u64 nr, u64 a1) {
    s64 ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall2(u64 nr, u64 a1, u64 a2) {
    s64 ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall3(u64 nr, u64 a1, u64 a2, u64 a3) {
    s64 ret;
    register u64 rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall4(u64 nr, u64 a1, u64 a2, u64 a3, u64 a4) {
    s64 ret;
    register u64 rdx __asm__("rdx") = a3;
    register u64 r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall6(u64 nr, u64 a1, u64 a2, u64 a3, u64 a4, u64 a5, u64 a6) {
    s64 ret;
    register u64 rdx __asm__("rdx") = a3;
    register u64 r10 __asm__("r10") = a4;
    register u64 r8 __asm__("r8") = a5;
    register u64 r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_WAITPID 6
#define SYS_MMAP 8
#define SYS_MUNMAP 12
#define SYS_FORK 57
#define SYS_MPROTECT 164
#define PAGE 4096UL
#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_RW (PROT_READ | PROT_WRITE)
#define MAP_PRIVATE 0x02
#define MAP_ANONYMOUS 0x20
#define MAP_FIXED 0x10
#define EINVAL 22
#define USER_ADDR_MAX 0x0000800000000000UL

static u64 strlen_raw(const char *s) { u64 n = 0; while (s[n]) n++; return n; }
static void print(const char *s) { syscall3(SYS_WRITE, 1, (u64)s, strlen_raw(s)); }
static int check(int ok, const char *name) {
    if (!ok) { print("hello74: FAIL "); print(name); print("\n"); return 1; }
    return 0;
}
__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(SYS_EXIT, (u64)status);
    for (;;) {}
}

static int wait_child(s64 pid, int expect_success) {
    int status = 0;
    return syscall4(SYS_WAITPID, (u64)pid, (u64)&status, 0, 0) == pid && (status == 0) == expect_success;
}

void _start(void) {
    int failures = 0;
    print("hello74: start\n");
    volatile unsigned char *base = (volatile unsigned char *)syscall6(
        SYS_MMAP, 0, 3 * PAGE, PROT_RW, MAP_PRIVATE | MAP_ANONYMOUS, (u64)-1, 0);
    failures += check((u64)base > 0, "three pages mapped");
    if ((u64)base > 0) {
        base[0] = 0x11; base[PAGE] = 0x22; base[2 * PAGE] = 0x33;
        failures += check(syscall3(SYS_MPROTECT, (u64)(base + PAGE), PAGE, PROT_READ) == 0,
                          "middle page becomes read-only");
        base[0] = 0x44; base[2 * PAGE] = 0x55;
        failures += check(base[PAGE] == 0x22, "read-only middle page retains data");
        failures += check(syscall3(SYS_MPROTECT, (u64)(base + PAGE), PAGE, PROT_RW) == 0,
                          "middle page restores read-write");
        base[PAGE] = 0x66;
        failures += check(base[PAGE] == 0x66, "restored middle page accepts writes");

        volatile unsigned char *fault_page = (volatile unsigned char *)syscall6(
            SYS_MMAP, 0, PAGE, PROT_RW, MAP_PRIVATE | MAP_ANONYMOUS, (u64)-1, 0);
        failures += check((u64)fault_page > 0, "fault page mapped");
        if ((u64)fault_page > 0) *fault_page = 0x66;
        failures += check(syscall3(SYS_MPROTECT, (u64)fault_page, PAGE, PROT_NONE) == 0,
                          "fault page becomes inaccessible");
        failures += check(syscall3(SYS_MPROTECT, (u64)fault_page, PAGE, PROT_RW) == 0,
                          "PROT_NONE page restores read-write");
        s64 child = syscall1(SYS_FORK, 0);
        failures += check(child >= 0, "fork for PROT_NONE fault succeeds");
        if (child == 0) {
            volatile unsigned char *child_page = (volatile unsigned char *)syscall6(
                SYS_MMAP, 0, PAGE, PROT_RW, MAP_PRIVATE | MAP_ANONYMOUS, (u64)-1, 0);
            if ((u64)child_page <= 0 || syscall3(SYS_MPROTECT, (u64)child_page, PAGE, PROT_NONE) != 0) exit_raw(1);
            *child_page = 0x77;
            exit_raw(1);
        } else if (child > 0) {
            failures += check(wait_child(child, 0), "PROT_NONE child write faults");
        }
        failures += check(syscall2(SYS_MUNMAP, (u64)fault_page, PAGE) == 0, "fault page cleanup");

        failures += check(syscall3(SYS_MPROTECT, (u64)(base + PAGE), 0, PROT_NONE) == -EINVAL,
                          "zero length is EINVAL");
        failures += check(syscall3(SYS_MPROTECT, (u64)(base + PAGE + 1), PAGE, PROT_READ) == -EINVAL,
                          "unaligned address is EINVAL");
        failures += check(syscall3(SYS_MPROTECT, (u64)base, PAGE, 8) == -EINVAL,
                          "unknown protection bits are EINVAL");
        failures += check(syscall3(SYS_MPROTECT, USER_ADDR_MAX, PAGE, PROT_READ) == -EINVAL,
                          "kernel-half address is EINVAL");
        base[0] = 0x91; base[PAGE] = 0x92; base[2 * PAGE] = 0x93;
        failures += check(syscall3(SYS_MPROTECT, (u64)(base + PAGE), PAGE, PROT_RW) == 0,
                          "invalid requests leave mapping usable");

        child = syscall1(SYS_FORK, 0);
        failures += check(child >= 0, "fork for COW isolation succeeds");
        if (child == 0) { base[0] = 0xa1; exit_raw(0); }
        if (child > 0) {
            failures += check(wait_child(child, 1), "COW child exits cleanly");
            failures += check(base[0] == 0x91, "COW child write is isolated");
        }
        failures += check(syscall2(SYS_MUNMAP, (u64)base, 3 * PAGE) == 0, "mapping cleanup");
    }
    if (failures == 0) { print("hello74: PASS\nhello74 done\n"); exit_raw(0); }
    print("hello74: FAIL\nhello74 done\n"); exit_raw(1);
}
