/// hello112: sigaltstack delivery and undeliverable-signal handling.
///
///   A. sigaltstack set/query round-trips; undersized stacks are ENOMEM.
///   B. an SA_ONSTACK handler runs on the alternate stack, sees SS_ONSTACK,
///      and cannot change the stack while on it (EPERM).
///   C. a handler without SA_ONSTACK stays on the normal stack.
///   D. a signal whose frame cannot be written (RSP points at unmapped
///      memory) kills the process with SIGSEGV instead of being dropped.

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
static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_WAITPID     6
#define SYS_MMAP        8
#define SYS_SIGACTION   13
#define SYS_GETPID      39
#define SYS_FORK        57
#define SYS_KILL        62
#define SYS_SIGALTSTACK 218

#define SIGUSR1 10
#define SIGUSR2 31
#define SIGSEGV 11
#define SA_ONSTACK 0x08000000ULL
#define SS_ONSTACK 1
#define SS_DISABLE 2
#define EPERM  1
#define ENOMEM 12
#define ALT_SIZE (16 * 4096)

struct ksigaction { uint64_t handler, flags, restorer, mask; };
struct kstack { uint64_t sp; int32_t flags; int32_t pad; uint64_t size; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello112:   ok   " : "hello112:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static uint64_t alt_base = 0;
static volatile uint64_t seen_sp = 0;
static volatile int32_t seen_flags = -1;
static volatile int64_t seen_set = 0;

static void on_usr1(int s) {
    (void)s;
    volatile int local = 0;
    seen_sp = (uint64_t)&local;
    struct kstack old = { 0, 0, 0, 0 };
    syscall2(SYS_SIGALTSTACK, 0, (uint64_t)&old);
    seen_flags = old.flags;
    struct kstack other = { alt_base, 0, 0, ALT_SIZE };
    seen_set = syscall2(SYS_SIGALTSTACK, (uint64_t)&other, 0);
}

static void on_usr2(int s) {
    (void)s;
    volatile int local = 0;
    seen_sp = (uint64_t)&local;
}

static int on_alt(uint64_t sp) { return sp > alt_base && sp <= alt_base + ALT_SIZE; }

static long install(int sig, uint64_t handler, uint64_t flags) {
    struct ksigaction a = { handler, flags, 0, 0 };
    return syscall3(SYS_SIGACTION, sig, (uint64_t)&a, 0);
}

void _start(void) {
    print("hello112: sigaltstack delivery and undeliverable signals\n");
    int64_t pid = syscall1(SYS_GETPID, 0);

    /* A. set / query */
    int64_t m = syscall6(SYS_MMAP, 0, ALT_SIZE, 3, 0x22, (uint64_t)-1, 0);
    check(m > 0, "A: mmap alternate stack");
    alt_base = (uint64_t)m;
    struct kstack small = { alt_base, 0, 0, 1024 };
    check(syscall2(SYS_SIGALTSTACK, (uint64_t)&small, 0) == -ENOMEM, "A: undersized stack is ENOMEM");
    struct kstack ss = { alt_base, 0, 0, ALT_SIZE };
    check(syscall2(SYS_SIGALTSTACK, (uint64_t)&ss, 0) == 0, "A: sigaltstack accepted");
    struct kstack q = { 0, -1, 0, 0 };
    syscall2(SYS_SIGALTSTACK, 0, (uint64_t)&q);
    check(q.sp == alt_base && q.size == ALT_SIZE && q.flags == 0, "A: query reports the stack, not on it");

    /* B. SA_ONSTACK */
    install(SIGUSR1, (uint64_t)on_usr1, SA_ONSTACK);
    syscall2(SYS_KILL, (uint64_t)pid, SIGUSR1);
    check(on_alt(seen_sp), "B: SA_ONSTACK handler ran on the alternate stack");
    check(seen_flags == SS_ONSTACK, "B: handler sees SS_ONSTACK");
    check(seen_set == -EPERM, "B: changing the stack while on it is EPERM");

    /* C. no SA_ONSTACK */
    seen_sp = 0;
    install(SIGUSR2, (uint64_t)on_usr2, 0);
    syscall2(SYS_KILL, (uint64_t)pid, SIGUSR2);
    check(seen_sp != 0 && !on_alt(seen_sp), "C: plain handler stays on the normal stack");

    struct kstack off = { 0, SS_DISABLE, 0, 0 };
    syscall2(SYS_SIGALTSTACK, (uint64_t)&off, 0);
    q.flags = 0;
    syscall2(SYS_SIGALTSTACK, 0, (uint64_t)&q);
    check(q.flags == SS_DISABLE, "C: SS_DISABLE turns it off");

    /* D. frame cannot be written: the child dies by SIGSEGV */
    int64_t child = syscall1(SYS_FORK, 0);
    if (child == 0) {
        install(SIGUSR1, (uint64_t)on_usr2, 0);
        int64_t me = syscall1(SYS_GETPID, 0);
        register uint64_t bad __asm__("rbx") = 0x500000000ULL;
        __asm__ volatile (
            "mov %%rbx, %%rsp\n"
            "mov $62, %%eax\n"
            "syscall\n"
            "mov $2, %%eax\n"
            "xor %%edi, %%edi\n"
            "syscall\n"
            "1: jmp 1b\n"
            :: "r"(bad), "D"(me), "S"((uint64_t)SIGUSR1) : "rax", "rcx", "r11", "memory");
    }
    int32_t st = 0;
    int64_t r = syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
    check(r == child && (st & 0x7f) == SIGSEGV, "D: undeliverable signal kills with SIGSEGV");

    print(failures == 0 ? "hello112: PASS\n" : "hello112: FAIL\n");
    print("hello112 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
