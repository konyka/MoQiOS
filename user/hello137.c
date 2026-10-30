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
#define SYS_SIGTIMEDWAIT 221
#define SYS_RT_SIGQUEUEINFO 222
#define SYS_TKILL     223
#define SYS_NANOSLEEP 35
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SA_SIGINFO 0x4
#define SIGUSR1 10
#define SIGSEGV 11
#define SIGUSR2 12
#define SIGCHLD 17

struct ksigaction { uint64_t handler, flags, restorer, mask; };
struct kinfo {
    int32_t signo, err, code, pad;
    union {
        struct { int32_t pid; uint32_t uid; uint64_t value; } kill;
        struct { uint64_t addr; } fault;
        struct { int32_t pid; uint32_t uid; int32_t status; int32_t pad2; int64_t utime, stime; } chld;
    } u;
    char rest[128 - 48];
};
struct kuc {
    uint64_t flags, link;
    uint64_t ss_sp; int32_t ss_flags; int32_t ss_pad; uint64_t ss_size;
    uint64_t gregs[23];
    uint64_t fpregs;
    uint64_t reserved[8];
    uint64_t sigmask;
};
#define REG_RSP 15
#define REG_RIP 16

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello137:   ok   " : "hello137:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct { int64_t s, n; } t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
__attribute__((naked)) static void restorer(void) { __asm__ volatile ("movq $15, %rax\n syscall"); }
static int64_t sigact(int sig, uint64_t h, uint64_t flags, uint64_t mask) {
    struct ksigaction a = { h, flags | 0x04000000, (uint64_t)restorer, mask };
    return syscall4(SYS_SIGACTION, (uint64_t)sig, (uint64_t)&a, 0, 8);
}
static uint64_t self(void) { return (uint64_t)syscall1(SYS_GETPID, 0); }

static volatile struct kinfo seen;
static volatile struct kuc seen_uc;
static volatile int seen_n;
static volatile uint64_t seen_sp;
static void info_handler(int s, struct kinfo *i, struct kuc *u) {
    (void)s;
    seen.signo = i->signo; seen.err = i->err; seen.code = i->code;
    seen.u.kill.pid = i->u.kill.pid; seen.u.kill.uid = i->u.kill.uid; seen.u.kill.value = i->u.kill.value;
    seen.u.chld.status = i->u.chld.status;
    seen_uc.sigmask = u->sigmask;
    seen_uc.gregs[REG_RSP] = u->gregs[REG_RSP];
    seen_uc.gregs[REG_RIP] = u->gregs[REG_RIP];
    seen_n++;
}

extern char fault_insn[], fault_resume[];
__asm__(".text\n.globl fault_fn\nfault_fn:\n movq $0x10, %rax\n.globl fault_insn\nfault_insn:\n movb $1, (%rax)\n.globl fault_resume\nfault_resume:\n ret\n");
extern void fault_fn(void);
static volatile uint64_t fault_addr, fault_code, fault_uc_rip;
static void segv_handler(int s, struct kinfo *i, struct kuc *u) {
    (void)s;
    fault_addr = i->u.fault.addr;
    fault_code = (uint64_t)(int64_t)i->code;
    fault_uc_rip = u->gregs[REG_RIP];
    u->gregs[REG_RIP] = (uint64_t)fault_resume;
}

void _start(void) {
    print("hello137: siginfo and ucontext\n");

    /* A: kill() fills a SI_USER siginfo */
    check(sigact(SIGUSR1, (uint64_t)info_handler, SA_SIGINFO, 0) == 0, "A: install an SA_SIGINFO handler");
    seen_n = 0;
    syscall2(SYS_KILL, self(), SIGUSR1);
    check(seen_n == 1, "A: the handler ran once");
    check(seen.signo == SIGUSR1, "A: si_signo is the signal number");
    check(seen.code == 0, "A: kill() reports SI_USER (0)");
    check(seen.u.kill.pid == (int32_t)self(), "A: si_pid is the sender");
    check(seen.u.kill.uid == (uint32_t)syscall1(201, 0), "A: si_uid is the sender's uid");
    check(seen_uc.sigmask == 0, "A: uc_sigmask is the interrupted mask");
    check(seen_uc.gregs[REG_RSP] > 0x1000 && seen_uc.gregs[REG_RIP] > 0x1000, "A: uc_mcontext carries rsp and rip");

    /* B: tkill reports SI_TKILL */
    seen_n = 0;
    syscall2(SYS_TKILL, self(), SIGUSR1);
    check(seen_n == 1 && seen.code == -6, "B: tkill() reports SI_TKILL (-6)");
    check(seen.u.kill.pid == (int32_t)self(), "B: si_pid is the sender");

    /* C: rt_sigqueueinfo carries the value */
    {
        struct kinfo qi;
        volatile char *p = (volatile char *)&qi;
        for (unsigned k = 0; k < sizeof qi; k++) p[k] = 0;
        qi.signo = SIGUSR1;
        qi.code = -1; /* SI_QUEUE */
        qi.u.kill.pid = (int32_t)self();
        qi.u.kill.value = 0x1234abcdULL;
        seen_n = 0;
        check(syscall3(SYS_RT_SIGQUEUEINFO, self(), SIGUSR1, (uint64_t)&qi) == 0, "C: rt_sigqueueinfo succeeds");
        check(seen_n == 1 && seen.code == -1, "C: the handler sees SI_QUEUE");
        check(seen.u.kill.value == 0x1234abcdULL, "C: and the queued value");
    }

    /* D: a fault reports the address and code, and the handler may redirect rip */
    check(sigact(SIGSEGV, (uint64_t)segv_handler, SA_SIGINFO, 0) == 0, "D: install a SIGSEGV handler");
    fault_fn();
    check(fault_addr == 0x10, "D: si_addr is the faulting address");
    check(fault_code == 1, "D: an unmapped address reports SEGV_MAPERR (1)");
    check(fault_uc_rip == (uint64_t)fault_insn, "D: uc_mcontext rip is the faulting instruction");
    check(1, "D: and a handler that edits the context resumes at the new rip");

    /* E: rt_sigtimedwait fills the info */
    {
        uint64_t set = 1ULL << (SIGUSR2 - 1);
        struct kinfo wi;
        volatile char *p = (volatile char *)&wi;
        for (unsigned k = 0; k < sizeof wi; k++) p[k] = 0x55;
        syscall4(SYS_SIGPROCMASK, SIG_BLOCK, (uint64_t)&set, 0, 8);
        syscall2(SYS_KILL, self(), SIGUSR2);
        check(syscall4(SYS_SIGTIMEDWAIT, (uint64_t)&set, (uint64_t)&wi, 0, 8) == SIGUSR2, "E: sigtimedwait returns the number");
        check(wi.signo == SIGUSR2 && wi.code == 0 && wi.u.kill.pid == (int32_t)self(), "E: and fills siginfo");
        syscall4(SYS_SIGPROCMASK, SIG_UNBLOCK, (uint64_t)&set, 0, 8);
    }

    /* F: SIGCHLD carries the child's pid and exit status */
    {
        check(sigact(SIGCHLD, (uint64_t)info_handler, SA_SIGINFO, 0) == 0, "F: install a SIGCHLD handler");
        seen_n = 0;
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            syscall1(SYS_EXIT, 7);
            for (;;) {}
        }
        for (int k = 0; k < 100 && seen_n == 0; k++) sleep_ms(10);
        check(seen_n >= 1 && seen.signo == SIGCHLD, "F: SIGCHLD was delivered");
        check(seen.code == 1, "F: CLD_EXITED (1)");
        check(seen.u.chld.pid == (int32_t)p, "F: si_pid is the child");
        check(seen.u.chld.status == 7, "F: si_status is the exit status");
        int st = 0;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&st, 0);
    }

    print(failures == 0 ? "hello137: PASS\n" : "hello137: FAIL\n");
    print("hello137 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
