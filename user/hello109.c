/// hello109: POSIX signal-delivery semantics (sigaction / sigreturn).
///
///   A. sa_mask is a per-handler mask: installing a handler with sa_mask
///      must NOT block those signals in the task mask afterwards (it used to
///      be written straight into the task mask, permanently).
///   B. While a handler runs, its own signal is blocked (no SA_NODEFER) and
///      sigreturn restores the interrupted mask.
///   C. SA_RESETHAND makes the handler one-shot (disposition back to SIG_DFL).
///   D. The handler's SSE use does not corrupt the interrupted code's xmm
///      registers: the signal frame saves and restores the FPU state.
///   E. SIGKILL and SIGSTOP cannot be caught or ignored (EINVAL).
///   F. A self-signal sent with tkill is allowed without cap_kill.

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

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_SIGACTION   13
#define SYS_SIGPROCMASK 14
#define SYS_SIGRETURN   15
#define SYS_GETPID      39
#define SYS_TKILL       223

#define SIGKILL  9
#define SIGUSR1  10
#define SIGUSR2  31
#define SIGSTOP  19
#define SIG_BLOCK   0
#define SIG_SETMASK 2
#define SA_RESETHAND 0x80000000UL

/* Linux layout: handler@0, flags@8, restorer@16, mask@24. */
struct ksigaction {
    void (*handler)(int);
    unsigned long flags;
    void *restorer;
    unsigned long mask;
};

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello109:   ok   " : "hello109:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static uint64_t bit(int sig) { return 1UL << (sig - 1); }

static uint64_t get_mask(void) {
    uint64_t old = 0;
    syscall4(SYS_SIGPROCMASK, SIG_BLOCK, 0, (uint64_t)&old, 8);
    return old;
}
static void set_mask(uint64_t m) {
    syscall4(SYS_SIGPROCMASK, SIG_SETMASK, (uint64_t)&m, 0, 8);
}

static long install(int sig, void (*h)(int), unsigned long flags, unsigned long mask) {
    struct ksigaction a = { h, flags, 0, mask };
    return syscall3(SYS_SIGACTION, sig, (uint64_t)&a, 0);
}

static int64_t self_tid(void) { return syscall1(SYS_GETPID, 0); }
static void raise_sig(int sig) { syscall2(SYS_TKILL, (uint64_t)self_tid(), (uint64_t)sig); }

static volatile int usr1_hits = 0;
static volatile uint64_t mask_in_handler = 0;
static void on_usr1(int s) {
    (void)s;
    usr1_hits++;
    mask_in_handler = get_mask();
}

static volatile int usr2_hits = 0;
static void on_usr2(int s) {
    (void)s;
    usr2_hits++;
    /* Clobber every xmm register the interrupted code may hold live. */
    __asm__ volatile (
        "pxor %%xmm0, %%xmm0\n\t"
        "pxor %%xmm1, %%xmm1\n\t"
        "pxor %%xmm2, %%xmm2\n\t"
        "pxor %%xmm3, %%xmm3\n\t"
        "pxor %%xmm7, %%xmm7\n\t"
        "pxor %%xmm15, %%xmm15\n\t"
        ::: "xmm0", "xmm1", "xmm2", "xmm3", "xmm7", "xmm15", "memory");
}

void _start(void) {
    print("hello109: sigaction / sigreturn delivery semantics\n");
    set_mask(0);

    /* A. sa_mask is applied only while the handler runs. */
    check(install(SIGUSR1, on_usr1, 0, bit(SIGUSR2)) == 0, "install SIGUSR1 with sa_mask=SIGUSR2");
    check((get_mask() & bit(SIGUSR2)) == 0, "A: sa_mask does not leak into the task mask");

    /* B. During the handler: own signal + sa_mask blocked; restored after. */
    raise_sig(SIGUSR1);
    check(usr1_hits == 1, "B: SIGUSR1 handler ran");
    check((mask_in_handler & bit(SIGUSR1)) != 0, "B: own signal blocked inside handler");
    check((mask_in_handler & bit(SIGUSR2)) != 0, "B: sa_mask blocked inside handler");
    check((get_mask() & (bit(SIGUSR1) | bit(SIGUSR2))) == 0, "B: sigreturn restored the interrupted mask");

    /* C. SA_RESETHAND: one-shot handler; the second raise would kill us, so
     * read the disposition back instead of raising again. */
    check(install(SIGUSR1, on_usr1, SA_RESETHAND, 0) == 0, "install SIGUSR1 with SA_RESETHAND");
    raise_sig(SIGUSR1);
    check(usr1_hits == 2, "C: SA_RESETHAND handler ran once");
    struct ksigaction cur = { 0, 0, 0, 0 };
    syscall3(SYS_SIGACTION, SIGUSR1, 0, (uint64_t)&cur);
    check(cur.handler == 0, "C: disposition reset to SIG_DFL");

    /* D. FPU state survives a handler that clobbers xmm registers. */
    check(install(SIGUSR2, on_usr2, 0, 0) == 0, "install SIGUSR2");
    uint64_t lo = 0, hi = 0;
    /* SSE2 only: the QEMU qemu64 model has no SSE4.1 (pinsrq/pextrq). */
    __asm__ volatile (
        "movabsq $0x1122334455667788, %%rax\n\t"
        "movq %%rax, %%xmm7\n\t"
        "punpcklqdq %%xmm7, %%xmm7\n\t"
        ::: "rax", "xmm7");
    raise_sig(SIGUSR2);
    __asm__ volatile (
        "movq %%xmm7, %0\n\t"
        "punpckhqdq %%xmm7, %%xmm7\n\t"
        "movq %%xmm7, %1\n\t"
        : "=r"(lo), "=r"(hi) :: "xmm7");
    check(usr2_hits == 1, "D: SIGUSR2 handler ran");
    check(lo == 0x1122334455667788UL && hi == 0x1122334455667788UL, "D: xmm7 preserved across the handler");

    /* E. SIGKILL / SIGSTOP dispositions are immutable. */
    check(install(SIGKILL, on_usr1, 0, 0) == -22, "E: sigaction(SIGKILL, handler) is EINVAL");
    check(install(SIGSTOP, (void (*)(int))1, 0, 0) == -22, "E: sigaction(SIGSTOP, SIG_IGN) is EINVAL");
    check(syscall3(SYS_SIGACTION, SIGKILL, 0, (uint64_t)&cur) == 0, "E: querying SIGKILL is allowed");

    print(failures == 0 ? "hello109: PASS\n" : "hello109: FAIL\n");
    print("hello109 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
