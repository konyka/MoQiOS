/// hello135: signal call argument and errno rules.

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
#define SYS_WAITPID   6
#define SYS_GETPID    39
#define SYS_FORK      57
#define SYS_KILL      62
#define SYS_SIGACTION 13
#define SYS_SIGPROCMASK 14
#define SYS_SIGPENDING 219
#define SYS_SIGTIMEDWAIT 221
#define SYS_TKILL     223
#define SYS_NANOSLEEP 35
#define SIG_SETMASK 2
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define EINVAL_ 22

struct ksigaction { uint64_t handler, flags, restorer, mask; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello136:   ok   " : "hello136:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct { int64_t s, n; } t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static volatile int got;
static volatile int got_count;
static volatile int order[8];
static void handler(int s) { got = s; if (got_count < 8) order[got_count] = s; got_count++; }
static volatile uint64_t mask_in_handler;
static void mask_probe(int s) {
    (void)s;
    syscall4(SYS_SIGPROCMASK, SIG_BLOCK, 0, (uint64_t)&mask_in_handler, 8);
}
__attribute__((naked)) static void restorer(void) { __asm__ volatile ("movq $15, %rax\n syscall"); }
static int64_t sigact(int sig, uint64_t h, uint64_t flags, uint64_t mask) {
    struct ksigaction a = { h, flags | 0x04000000, (uint64_t)restorer, mask };
    return syscall4(SYS_SIGACTION, (uint64_t)sig, (uint64_t)&a, 0, 8);
}
static uint64_t self(void) { return (uint64_t)syscall1(SYS_GETPID, 0); }

void _start(void) {
    print("hello136: real-time signals 32..64\n");
    struct ksigaction q;

    /* A: the whole range 1..64 is valid, 0 and 65 are not */
    check(sigact(32, (uint64_t)handler, 0, 0) == 0, "A: SIGRTMIN (32) can be installed");
    check(sigact(34, (uint64_t)handler, 0, 0) == 0, "A: signal 34 can be installed");
    check(sigact(64, (uint64_t)handler, 0, 0) == 0, "A: SIGRTMAX (64) can be installed");
    check(sigact(65, (uint64_t)handler, 0, 0) == -EINVAL_, "A: signal 65 is EINVAL");
    check(syscall4(SYS_SIGACTION, 34, 0, (uint64_t)&q, 8) == 0 && q.handler == (uint64_t)handler, "A: the installed action is reported back");
    check(syscall2(SYS_KILL, self(), 65) == -EINVAL_, "A: kill with signal 65 is EINVAL");
    check(syscall2(SYS_TKILL, self(), 65) == -EINVAL_, "A: tkill with signal 65 is EINVAL");

    /* B: delivery runs the handler with the right number */
    got = 0;
    check(syscall2(SYS_KILL, self(), 34) == 0 && got == 34, "B: kill(self, 34) runs the handler with 34");
    got = 0;
    check(syscall2(SYS_KILL, self(), 64) == 0 && got == 64, "B: kill(self, 64) runs the handler with 64");
    got = 0;
    check(syscall2(SYS_TKILL, self(), 32) == 0 && got == 32, "B: tkill(self, 32) runs the handler with 32");

    /* C: blocking, pending, unblocking */
    uint64_t set = 1ULL << (40 - 1);
    check(sigact(40, (uint64_t)handler, 0, 0) == 0, "C: install a handler for 40");
    check(syscall4(SYS_SIGPROCMASK, SIG_BLOCK, (uint64_t)&set, 0, 8) == 0, "C: block signal 40");
    got = 0;
    syscall2(SYS_KILL, self(), 40);
    check(got == 0, "C: a blocked real-time signal is not delivered");
    uint64_t pend = 0;
    check(syscall2(SYS_SIGPENDING, (uint64_t)&pend, 8) == 0 && (pend & set) != 0, "C: it is reported pending in bit 39");
    check(syscall4(SYS_SIGPROCMASK, SIG_UNBLOCK, (uint64_t)&set, 0, 8) == 0 && got == 40, "C: unblocking delivers it before the call returns");
    pend = ~0ULL;
    syscall2(SYS_SIGPENDING, (uint64_t)&pend, 8);
    check((pend & set) == 0, "C: and it is no longer pending");

    /* D: rt_sigtimedwait consumes a blocked real-time signal */
    uint64_t wait_set = 1ULL << (50 - 1);
    syscall4(SYS_SIGPROCMASK, SIG_BLOCK, (uint64_t)&wait_set, 0, 8);
    syscall2(SYS_KILL, self(), 50);
    check(syscall4(SYS_SIGTIMEDWAIT, (uint64_t)&wait_set, 0, 0, 8) == 50, "D: sigtimedwait returns 50");
    pend = ~0ULL;
    syscall2(SYS_SIGPENDING, (uint64_t)&pend, 8);
    check((pend & wait_set) == 0, "D: and the signal is consumed");
    syscall4(SYS_SIGPROCMASK, SIG_UNBLOCK, (uint64_t)&wait_set, 0, 8);

    /* E: the lowest-numbered pending signal goes first */
    {
        uint64_t both = (1ULL << (35 - 1)) | (1ULL << (10 - 1)) | (1ULL << (33 - 1));
        sigact(10, (uint64_t)handler, 0, 0);
        sigact(33, (uint64_t)handler, 0, 0);
        sigact(35, (uint64_t)handler, 0, 0);
        syscall4(SYS_SIGPROCMASK, SIG_BLOCK, (uint64_t)&both, 0, 8);
        syscall2(SYS_KILL, self(), 35);
        syscall2(SYS_KILL, self(), 33);
        syscall2(SYS_KILL, self(), 10);
        got = 0;
        got_count = 0;
        syscall4(SYS_SIGPROCMASK, SIG_UNBLOCK, (uint64_t)&both, 0, 8);
        /* one signal is delivered before the call returns; the rest may wait for the next timer tick */
        for (volatile long i = 0; i < 200000000L && got_count < 3; i++) {}
        check(got_count == 3, "E: all three signals were delivered");
        check(order[0] == 10 && order[1] == 33 && order[2] == 35, "E: the lowest-numbered pending signal is delivered first");
    }

    /* F: a handler is inherited across fork, and a default action still applies */
    {
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            got = 0;
            syscall2(SYS_KILL, self(), 34);
            syscall1(SYS_EXIT, got == 34 ? 0 : 1);
            for (;;) {}
        }
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&st, 0);
        check(st == 0, "F: the child inherits the real-time handler");
    }
    {
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            sigact(45, 0, 0, 0);
            syscall2(SYS_KILL, self(), 45);
            sleep_ms(50);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&st, 0);
        check((st & 0x7f) == 45, "F: the default action of a real-time signal terminates the process");
    }
    {
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            sigact(46, 1, 0, 0);
            syscall2(SYS_KILL, self(), 46);
            sleep_ms(30);
            syscall1(SYS_EXIT, 9);
            for (;;) {}
        }
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&st, 0);
        check((st & 0x7f) == 0 && ((st >> 8) & 0xff) == 9, "F: SIG_IGN on a real-time signal drops it");
    }

    /* G: sa_mask and the running signal are blocked inside the handler */
    {
        sigact(37, (uint64_t)mask_probe, 0, 1ULL << (36 - 1));
        syscall2(SYS_KILL, self(), 37);
        check((mask_in_handler & (1ULL << (36 - 1))) != 0, "G: a real-time sa_mask bit is blocked inside the handler");
        check((mask_in_handler & (1ULL << (37 - 1))) != 0, "G: the delivered real-time signal is blocked inside its handler");
        uint64_t after = 0;
        syscall4(SYS_SIGPROCMASK, SIG_BLOCK, 0, (uint64_t)&after, 8);
        check((after & ((1ULL << 35) | (1ULL << 36))) == 0, "G: the mask is restored after the handler returns");
    }

    print(failures == 0 ? "hello136: PASS\n" : "hello136: FAIL\n");
    print("hello136 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
