/* hello216: the registers a user program holds across a system call must come back unchanged (the syscall instruction
 * itself only clobbers rcx and r11; the kernel must restore everything else, also when the call blocks, is interrupted, or
 * the task is migrated to another CPU in the middle). Checked with FUTEX_WAKE and FUTEX_WAIT (which blocks), while other
 * threads keep the scheduler busy. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello216:   ok   " : "hello216:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile int futex_word;
static volatile int stop;
static volatile long bad_regs;

#define SYS_FUTEX 202

/* Calls futex with callee-saved and scratch registers loaded with a pattern derived from `seed`, then compares every one of
 * them after the call. Returns a bit mask of the registers that changed (0 = all preserved). */
static long futex_with_regs(volatile int *addr, long op, long val, long seed) {
    long mask = 0;
    long r8v = seed ^ 0x1111111111111111L, r9v = seed ^ 0x2222222222222222L, r10v = 0;
    long r12v = seed ^ 0x4444444444444444L, r13v = seed ^ 0x5555555555555555L;
    long r14v = seed ^ 0x6666666666666666L, r15v = seed ^ 0x7777777777777777L;
    long a8, a9, a12, a13, a14, a15;
    __asm__ volatile (
        "mov %[r8v], %%r8\n\t"
        "mov %[r9v], %%r9\n\t"
        "mov %[r10v], %%r10\n\t"
        "mov %[r12v], %%r12\n\t"
        "mov %[r13v], %%r13\n\t"
        "mov %[r14v], %%r14\n\t"
        "mov %[r15v], %%r15\n\t"
        "mov $202, %%eax\n\t"
        "syscall\n\t"
        "mov %%r8, %[a8]\n\t"
        "mov %%r9, %[a9]\n\t"
        "mov %%r12, %[a12]\n\t"
        "mov %%r13, %[a13]\n\t"
        "mov %%r14, %[a14]\n\t"
        "mov %%r15, %[a15]\n\t"
        : [a8] "=m"(a8), [a9] "=m"(a9), [a12] "=m"(a12), [a13] "=m"(a13), [a14] "=m"(a14), [a15] "=m"(a15)
        : "D"(addr), "S"(op), "d"(val), [r8v] "m"(r8v), [r9v] "m"(r9v), [r10v] "m"(r10v),
          [r12v] "m"(r12v), [r13v] "m"(r13v), [r14v] "m"(r14v), [r15v] "m"(r15v)
        : "rax", "rcx", "r11", "r8", "r9", "r10", "r12", "r13", "r14", "r15", "memory");
    if (a8 != r8v) mask |= 1;
    if (a9 != r9v) mask |= 2;
    if (a12 != r12v) mask |= 4;
    if (a13 != r13v) mask |= 8;
    if (a14 != r14v) mask |= 16;
    if (a15 != r15v) mask |= 32;
    return mask;
}

/* No system call at all: the registers are loaded once and compared against memory copies on every iteration of a long
 * loop, so the only things that can change them are timer interrupts, preemption and migration to another CPU. Returns 0
 * when every comparison matched for the whole run. */
static long spin_regs(long seed, long iters) {
    long e8 = seed ^ 0x1111111111111111L, e9 = seed ^ 0x2222222222222222L, e12 = seed ^ 0x4444444444444444L;
    long e13 = seed ^ 0x5555555555555555L, e14 = seed ^ 0x6666666666666666L, e15 = seed ^ 0x7777777777777777L;
    long out = 0;
    __asm__ volatile (
        "mov %[e8], %%r8\n\t"
        "mov %[e9], %%r9\n\t"
        "mov %[e12], %%r12\n\t"
        "mov %[e13], %%r13\n\t"
        "mov %[e14], %%r14\n\t"
        "mov %[e15], %%r15\n\t"
        "mov %[n], %%rdx\n\t"
        "xor %%esi, %%esi\n\t"
        "1:\n\t"
        "cmp %[e8], %%r8\n\t" "jne 2f\n\t"
        "cmp %[e9], %%r9\n\t" "jne 2f\n\t"
        "cmp %[e12], %%r12\n\t" "jne 2f\n\t"
        "cmp %[e13], %%r13\n\t" "jne 2f\n\t"
        "cmp %[e14], %%r14\n\t" "jne 2f\n\t"
        "cmp %[e15], %%r15\n\t" "jne 2f\n\t"
        "dec %%rdx\n\t"
        "jnz 1b\n\t"
        "jmp 3f\n\t"
        "2:\n\t"
        "mov $1, %%esi\n\t"
        "3:\n\t"
        "mov %%rsi, %[out]\n\t"
        : [out] "=m"(out)
        : [n] "r"(iters), [e8] "m"(e8), [e9] "m"(e9), [e12] "m"(e12), [e13] "m"(e13), [e14] "m"(e14), [e15] "m"(e15)
        : "rdx", "rsi", "r8", "r9", "r12", "r13", "r14", "r15", "cc", "memory");
    return out;
}

static void *waker(void *arg) {
    (void)arg;
    long seed = 0x0123456789abcdefL;
    while (!stop) {
        long m = futex_with_regs(&futex_word, 1 /* FUTEX_WAKE */ | 128, 1, seed);
        if (m) bad_regs |= m;
        seed += 0x9e3779b97f4a7c15L;
        yield();
    }
    return (void *)0;
}

static void *spinner(void *arg) {
    (void)arg;
    unsigned long x = 1;
    while (!stop) { x = x * 6364136223846793005UL + 1442695040888963407UL; if ((x & 0xfff) == 0) yield(); }
    return (void *)x;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello216: registers survive system calls\n");

    pthread_t w[3], s[3];
    int ok = 1;
    for (int i = 0; i < 3; i++) {
        int tries = 0;
        while (pthread_create(&w[i], (void *)0, waker, (void *)0) != 0 && tries++ < 1000) yield();
        tries = 0;
        while (pthread_create(&s[i], (void *)0, spinner, (void *)0) != 0 && tries++ < 1000) yield();
    }

    long seed = 42;
    long waited_bad = 0;
    for (int i = 0; i < 4000; i++) {
        futex_word = 0;
        /* FUTEX_WAIT with a value that does not match returns EAGAIN at once; with a timeout of 0 it would block, so use
         * the cheap non-blocking forms here and the blocking one below. */
        long m = futex_with_regs(&futex_word, 0 | 128 /* FUTEX_WAIT_PRIVATE */, 1 /* != word: EAGAIN */, seed);
        if (m) waited_bad |= m;
        m = futex_with_regs(&futex_word, 1 | 128 /* FUTEX_WAKE_PRIVATE */, 1, seed);
        if (m) waited_bad |= m;
        seed += 0x9e3779b97f4a7c15L;
    }
    check(waited_bad == 0, "A: r8, r9, r12-r15 are preserved across 8000 futex calls while other threads run");

    /* A blocking wait: the main thread sleeps in the kernel until the helper wakes it, then checks its registers. */
    long blocked_bad = 0;
    for (int i = 0; i < 300; i++) {
        futex_word = 0;
        long m = futex_with_regs(&futex_word, 0 | 128, 0, seed + i);
        blocked_bad |= m;
        yield();
    }
    check(1, "B: blocking futex waits returned (woken by the waker threads or by their wakes racing)");
    check(blocked_bad == 0, "B: and the registers were preserved across the blocking waits");

    /* D: registers across timer interrupts and preemption, no system call in between. */
    long spin_bad = 0;
    for (int i = 0; i < 6; i++) spin_bad |= spin_regs(0x0f0e0d0c0b0a0908L + i, 12000000L);
    check(spin_bad == 0, "D: r8, r9, r12-r15 held in a system-call-free loop stay intact across timer interrupts and migrations");

    stop = 1;
    for (int i = 0; i < 3; i++) { pthread_join(w[i], (void **)0); pthread_join(s[i], (void **)0); }
    check(bad_regs == 0, "C: the waker threads' own register checks, made while they ran concurrently, all passed");

    print(failures == 0 ? "hello216: PASS\n" : "hello216: FAIL\n");
    return failures;
}
