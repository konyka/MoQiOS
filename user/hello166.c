/// hello166: SSE register state across fork.

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
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_SCHED_YIELD 24

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello166:   ok   " : "hello166:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}

/* The syscall wrappers do not list the SSE registers as clobbered, exactly
 * like any compiled user program: the ABI says a syscall preserves them. */
static inline void load_xmm(const uint8_t *p) {
    __asm__ volatile ("movdqu 0(%0), %%xmm0\n\tmovdqu 16(%0), %%xmm1\n\tmovdqu 32(%0), %%xmm2\n\tmovdqu 48(%0), %%xmm3"
                      : : "r"(p) : "xmm0", "xmm1", "xmm2", "xmm3", "memory");
}
static inline void store_xmm(uint8_t *p) {
    __asm__ volatile ("movdqu %%xmm0, 0(%0)\n\tmovdqu %%xmm1, 16(%0)\n\tmovdqu %%xmm2, 32(%0)\n\tmovdqu %%xmm3, 48(%0)"
                      : : "r"(p) : "memory");
}
static int same(const uint8_t *a, const uint8_t *b) {
    for (int i = 0; i < 64; i++) if (a[i] != b[i]) return 0;
    return 1;
}

void _start(void) {
    print("hello166: SSE register state across fork\n");
    uint8_t pat[64], got[64];

    int imm_bad = 0, later_bad = 0, parent_bad = 0, child_fail = 0;
    for (int round = 0; round < 24; round++) {
        for (int k = 0; k < 64; k++) pat[k] = (uint8_t)((round * 37 + k * 11 + 1) | 1);
        load_xmm(pat);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            /* first thing the child does: look at its own SSE registers */
            store_xmm(got);
            int ok_now = same(got, pat);
            /* and again after a sleep, i.e. after being switched out and back in */
            sleep_ms(3);
            store_xmm(got);
            int ok_later = same(got, pat);
            syscall1(SYS_EXIT, (ok_now ? 0 : 1) | (ok_later ? 0 : 2));
            for (;;) {}
        }
        store_xmm(got);
        if (!same(got, pat)) parent_bad++;
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        int code = (st >> 8) & 0xff;
        if (code & 1) imm_bad++;
        if (code & 2) later_bad++;
        if ((st & 0x7f) != 0) child_fail++;
    }
    check(imm_bad == 0, "A: a forked child starts with the parent's SSE registers (24 forks)");
    check(later_bad == 0, "A: and keeps them across a sleep (switch out and back in)");
    check(parent_bad == 0, "A: the parent's own registers are untouched by fork");
    check(child_fail == 0, "A: and every child exited normally");

    print(failures == 0 ? "hello166: PASS\n" : "hello166: FAIL\n");
    print("hello166 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
