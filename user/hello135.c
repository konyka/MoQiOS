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
#define SYS_SIGRETURN 15
#define SYS_SIGPENDING 219
#define SYS_SIGSUSPEND 220
#define SYS_TKILL     223
#define SYS_NANOSLEEP 35

#define SIGHUP 1
#define SIGINT 2
#define SIGKILL 9
#define SIGUSR1 10
#define SIGSEGV 11
#define SIGUSR2 12
#define SIGTERM 15
#define SIGCHLD 17
#define SIGSTOP 19
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2

#define EPERM_  1
#define ESRCH_  3
#define EINTR_  4
#define EFAULT_ 14
#define EINVAL_ 22

struct ksigaction { uint64_t handler, flags, restorer, mask; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello135:   ok   " : "hello135:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static volatile int got;
static void handler(int s) { got = s; }
/* the kernel returns through a restorer the program supplies; a tiny one is enough */
__attribute__((naked)) static void restorer(void) { __asm__ volatile ("movq $15, %rax\n syscall"); }
static int64_t sigact(int sig, uint64_t h, uint64_t flags, uint64_t mask) {
    struct ksigaction a = { h, flags | 0x04000000 /* SA_RESTORER */, (uint64_t)restorer, mask };
    return syscall4(SYS_SIGACTION, (uint64_t)sig, (uint64_t)&a, 0, 8);
}
static void sleep_ms(int ms) {
    struct { int64_t s, n; } t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}

void _start(void) {
    print("hello135: signals\n");
    uint64_t one = 1;
    struct ksigaction q;

    /* A: sigaction arguments */
    check(syscall4(SYS_SIGACTION, 0, 0, 0, 8) == -EINVAL_, "A: signal 0 is EINVAL");
    check(syscall4(SYS_SIGACTION, 65, 0, 0, 8) == -EINVAL_, "A: signal 65 is EINVAL");
    check(sigact(SIGKILL, (uint64_t)handler, 0, 0) == -EINVAL_, "A: SIGKILL cannot be caught");
    check(sigact(SIGSTOP, 1, 0, 0) == -EINVAL_, "A: SIGSTOP cannot be ignored");
    check(syscall4(SYS_SIGACTION, SIGKILL, 0, (uint64_t)&q, 8) == 0, "A: SIGKILL can be queried");
    check(sigact(SIGUSR1, (uint64_t)handler, 0, 0) == 0, "A: install a SIGUSR1 handler");
    check(syscall4(SYS_SIGACTION, SIGUSR1, 0, (uint64_t)&q, 8) == 0 && q.handler == (uint64_t)handler, "A: the old action is reported");
    check(syscall4(SYS_SIGACTION, SIGUSR1, 0, 1, 8) == -EFAULT_, "A: a bad oldact pointer is EFAULT");

    /* B: delivery to self */
    got = 0;
    check(syscall2(SYS_KILL, (uint64_t)syscall1(SYS_GETPID, 0), SIGUSR1) == 0 && got == SIGUSR1, "B: kill(self, SIGUSR1) runs the handler before returning");
    check(syscall2(SYS_KILL, (uint64_t)syscall1(SYS_GETPID, 0), 0) == 0, "B: kill(pid, 0) only checks the target");
    check(syscall2(SYS_KILL, 999999, SIGUSR1) == -ESRCH_, "B: kill of a missing pid is ESRCH");
    check(syscall2(SYS_KILL, 999999, 0) == -ESRCH_, "B: kill(missing, 0) is ESRCH");
    check(syscall2(SYS_KILL, (uint64_t)syscall1(SYS_GETPID, 0), 99) == -EINVAL_, "B: an invalid signal number is EINVAL");
    check(syscall2(SYS_TKILL, (uint64_t)syscall1(SYS_GETPID, 0), 0) == 0, "B: tkill(self, 0) is a probe");
    check(syscall2(SYS_TKILL, 999999, SIGUSR1) == -ESRCH_, "B: tkill of a missing tid is ESRCH");
    check(syscall2(SYS_TKILL, (uint64_t)-5, SIGUSR1) == -EINVAL_, "B: tkill with a non-positive tid is EINVAL");

    /* C: sigprocmask */
    uint64_t old = 0, set = 0;
    set = 1ULL << (SIGUSR1 - 1);
    check(syscall4(SYS_SIGPROCMASK, SIG_BLOCK, (uint64_t)&set, (uint64_t)&old, 8) == 0, "C: block SIGUSR1");
    got = 0;
    syscall2(SYS_KILL, (uint64_t)syscall1(SYS_GETPID, 0), SIGUSR1);
    check(got == 0, "C: a blocked signal is not delivered");
    uint64_t pend = 0;
    check(syscall2(SYS_SIGPENDING, (uint64_t)&pend, 8) == 0 && (pend & (1ULL << (SIGUSR1 - 1))) != 0, "C: and shows up as pending");
    check(syscall4(SYS_SIGPROCMASK, SIG_UNBLOCK, (uint64_t)&set, 0, 8) == 0 && got == SIGUSR1, "C: unblocking delivers it before the call returns");
    pend = ~0ULL;
    syscall2(SYS_SIGPENDING, (uint64_t)&pend, 8);
    check((pend & (1ULL << (SIGUSR1 - 1))) == 0, "C: and it is no longer pending");
    check(syscall4(SYS_SIGPROCMASK, 77, (uint64_t)&set, 0, 8) == -EINVAL_, "C: an unknown 'how' is EINVAL");
    uint64_t killset = (1ULL << (SIGKILL - 1)) | (1ULL << (SIGSTOP - 1));
    uint64_t cur = 0;
    syscall4(SYS_SIGPROCMASK, SIG_SETMASK, (uint64_t)&killset, 0, 8);
    syscall4(SYS_SIGPROCMASK, SIG_BLOCK, 0, (uint64_t)&cur, 8);
    check((cur & killset) == 0, "C: SIGKILL and SIGSTOP cannot be blocked");
    uint64_t zero = 0;
    syscall4(SYS_SIGPROCMASK, SIG_SETMASK, (uint64_t)&zero, 0, 8);

    /* D: SIGCHLD and ignored signals */
    check(sigact(SIGUSR2, 1 /* SIG_IGN */, 0, 0) == 0, "D: ignore SIGUSR2");
    check(syscall2(SYS_KILL, (uint64_t)syscall1(SYS_GETPID, 0), SIGUSR2) == 0, "D: an ignored signal is accepted and dropped");
    check(sigact(SIGUSR2, 0 /* SIG_DFL */, 0, 0) == 0, "D: restore the default action");

    /* E: default actions (in a child so we survive) */
    {
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            sigact(SIGUSR1, 0, 0, 0);
            syscall2(SYS_KILL, (uint64_t)syscall1(SYS_GETPID, 0), SIGUSR1);
            sleep_ms(50);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&st, 0);
        check((st & 0x7f) == SIGUSR1, "E: the default action of SIGUSR1 terminates the process");
    }
    {
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            sigact(SIGCHLD, 0, 0, 0);
            syscall2(SYS_KILL, (uint64_t)syscall1(SYS_GETPID, 0), SIGCHLD);
            sleep_ms(30);
            syscall1(SYS_EXIT, 7);
            for (;;) {}
        }
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&st, 0);
        check((st & 0x7f) == 0 && ((st >> 8) & 0xff) == 7, "E: the default action of SIGCHLD is to ignore it");
    }

    /* F: handler mask and SA_RESETHAND/SA_NODEFER-style flags */
    {
        static volatile int order;
        (void)order;
        got = 0;
        check(sigact(SIGUSR1, (uint64_t)handler, 0x80000000ULL /* SA_RESETHAND */, 0) == 0, "F: install with SA_RESETHAND");
        syscall2(SYS_KILL, (uint64_t)syscall1(SYS_GETPID, 0), SIGUSR1);
        check(got == SIGUSR1, "F: the first delivery runs the handler");
        syscall4(SYS_SIGACTION, SIGUSR1, 0, (uint64_t)&q, 8);
        check(q.handler == 0, "F: and the action is back to the default afterwards");
    }

    print(failures == 0 ? "hello135: PASS\n" : "hello135: FAIL\n");
    print("hello135 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
