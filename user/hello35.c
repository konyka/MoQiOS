/// hello35: a CLONE_VM thread runs and shares memory with its creator
///
/// Everything in this tree that exercises two tasks uses fork, which gives each
/// side its own address space. Nothing had ever run a real thread from user
/// space, so the CLONE_VM path was only ever exercised from the kernel's own
/// unit tests — and a race that needs two tasks in one address space could not
/// be reproduced at all.
///
/// This is the smallest thing that establishes the capability: spawn a thread
/// on an mmap'd stack, have it store to a shared location, and have the creator
/// observe the store.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8)
                      : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_MMAP        8
#define SYS_SCHED_YIELD 24
#define SYS_CLONE       243

#define CLONE_VM     0x100
#define CLONE_FS     0x200
#define CLONE_FILES  0x400
#define CLONE_THREAD 0x10000

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define STACK_SIZE (16 * 4096)

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_dec(int64_t v) {
    char buf[24];
    int pos = 0;
    if (v < 0) { print("-"); v = -v; }
    if (v == 0) { print("0"); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char t = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = t; }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

/// Written by the thread, read by its creator. Both see the same page only if
/// the address space is genuinely shared.
static volatile int64_t shared_flag = 0;

void _start(void) {
    print("hello35: CLONE_VM thread test\n");

    const int64_t stack = syscall6(SYS_MMAP, 0, STACK_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (stack <= 0) {
        print("hello35: FAIL (no stack)\n");
        print("hello35 done\n");
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }

    const int64_t tid = syscall5(SYS_CLONE,
                                 CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_THREAD,
                                 (uint64_t)(stack + STACK_SIZE - 16), 0, 0, 0);

    if (tid == 0) {
        /// Thread side. Its only job is to prove it ran and that its store is
        /// visible to the other task.
        shared_flag = 42;
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }

    if (tid < 0) {
        print("hello35: FAIL (clone=");
        print_dec(tid);
        print(")\n");
        print("hello35 done\n");
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }

    print("hello35:   thread tid=");
    print_dec(tid);
    print("\n");

    /// Bounded so a thread that never runs fails the test instead of hanging
    /// the smoke.
    /// Bounded so a thread that never runs fails the test instead of hanging
    /// the smoke.
    int spins = 0;
    while (shared_flag == 0 && spins < 100000) {
        syscall1(SYS_SCHED_YIELD, 0);
        spins++;
    }

    if (shared_flag == 42) {
        print("hello35: PASS (thread ran and shares memory)\n");
    } else {
        print("hello35: FAIL (thread store never observed)\n");
    }

    print("hello35 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
