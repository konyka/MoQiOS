/// hello274: real-time signals queue: each send is its own delivery with its own siginfo (Linux, measured).

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
#define SYS_GETPID    39
#define SYS_KILL      62
#define SYS_SIGACTION 13
#define SYS_SIGPROCMASK 14
#define SYS_SIGPENDING 219
#define SYS_SIGTIMEDWAIT 221
#define SYS_RT_SIGQUEUEINFO 222
#define SYS_TKILL     223
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SA_SIGINFO 0x4
#define SIGUSR1 10
#define SIGRTMIN 34

struct ksigaction { uint64_t handler, flags, restorer, mask; };
struct kinfo {
    int32_t signo, err, code, pad;
    struct { int32_t pid; uint32_t uid; uint64_t value; } kill;
    char rest[128 - 32];
};

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static void print_num(int64_t v) {
    char b[24]; int i = 23; b[i] = 0;
    int neg = v < 0; uint64_t u = neg ? (uint64_t)(-v) : (uint64_t)v;
    do { b[--i] = (char)('0' + u % 10); u /= 10; } while (u);
    if (neg) b[--i] = '-';
    print(&b[i]);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello274:   ok   " : "hello274:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
__attribute__((naked)) static void restorer(void) { __asm__ volatile ("movq $15, %rax\n syscall"); }
static int64_t sigact(int sig, uint64_t h, uint64_t flags) {
    struct ksigaction a = { h, flags | 0x04000000, (uint64_t)restorer, 0 };
    return syscall4(SYS_SIGACTION, (uint64_t)sig, (uint64_t)&a, 0, 8);
}
static uint64_t self(void) { return (uint64_t)syscall1(SYS_GETPID, 0); }
static uint64_t bit(int sig) { return 1ULL << (sig - 1); }
static void block(uint64_t set) { syscall4(SYS_SIGPROCMASK, SIG_BLOCK, (uint64_t)&set, 0, 8); }
static void unblock(uint64_t set) { syscall4(SYS_SIGPROCMASK, SIG_UNBLOCK, (uint64_t)&set, 0, 8); }
static int64_t queue(int sig, uint64_t value) {
    struct kinfo qi;
    volatile char *p = (volatile char *)&qi;
    for (unsigned k = 0; k < sizeof qi; k++) p[k] = 0;
    qi.signo = sig;
    qi.code = -1; /* SI_QUEUE */
    qi.kill.pid = (int32_t)self();
    qi.kill.value = value;
    return syscall3(SYS_RT_SIGQUEUEINFO, self(), (uint64_t)sig, (uint64_t)&qi);
}
/* Poll once: returns the signal number taken, or a negative errno (-11 when nothing is pending). */
static int64_t take(uint64_t set, struct kinfo *wi) {
    struct { int64_t s, n; } zero = { 0, 0 };
    return syscall4(SYS_SIGTIMEDWAIT, (uint64_t)&set, (uint64_t)wi, (uint64_t)&zero, 8);
}
static uint64_t pending(void) { uint64_t p = 0; syscall2(SYS_SIGPENDING, (uint64_t)&p, 8); return p; }

static volatile int seen[16];
static volatile int seen_n;
static void rt_handler(int s, struct kinfo *i, void *u) {
    (void)u;
    if (seen_n < 16) seen[seen_n] = s * 100 + (int)i->kill.value;
    seen_n++;
}

void _start(void) {
    print("hello274: real-time signals queue\n");
    const int RT = SIGRTMIN, RT1 = SIGRTMIN + 1;
    const uint64_t set = bit(RT) | bit(RT1) | bit(SIGUSR1);
    block(set);

    /* A: three sigqueue()s of one real-time signal are three deliveries, in order, each with its own value */
    {
        int ok = 1;
        for (int i = 1; i <= 3; i++) ok &= queue(RT, (uint64_t)i) == 0;
        check(ok, "A: three rt_sigqueueinfo calls succeed");
        check((pending() & bit(RT)) != 0, "A: the signal is pending");
        struct kinfo wi;
        int vals[4] = { 0, 0, 0, 0 }, got = 0;
        int64_t r;
        while (got < 4 && (r = take(bit(RT), &wi)) == RT) vals[got++] = (int)wi.kill.value;
        print("hello274:        taken "); print_num(got); print(" values"); for (int i = 0; i < got; i++) { print(" "); print_num(vals[i]); } print("\n");
        check(got == 3, "A: sigtimedwait takes it three times");
        check(got == 3 && vals[0] == 1 && vals[1] == 2 && vals[2] == 3, "A: in send order, each with its own value");
        check((pending() & bit(RT)) == 0, "A: and then it is no longer pending");
    }

    /* B: a standard signal sent three times is still one delivery */
    {
        for (int i = 0; i < 3; i++) syscall2(SYS_KILL, self(), SIGUSR1);
        struct kinfo wi;
        int got = 0;
        while (got < 4 && take(bit(SIGUSR1), &wi) == SIGUSR1) got++;
        check(got == 1, "B: SIGUSR1 sent three times is taken once");
    }

    /* C: kill() and tkill() queue real-time signals too */
    {
        syscall2(SYS_KILL, self(), (uint64_t)RT1);
        syscall2(SYS_KILL, self(), (uint64_t)RT1);
        syscall2(SYS_TKILL, self(), (uint64_t)RT1);
        struct kinfo wi;
        int got = 0;
        while (got < 4 && take(bit(RT1), &wi) == RT1) got++;
        check(got == 3, "C: two kill()s and a tkill() of SIGRTMIN+1 are three deliveries");
    }

    /* D: with several pending, the lowest-numbered signal comes first; queued instances keep FIFO order */
    {
        queue(RT1, 7);
        queue(RT, 8);
        queue(RT, 9);
        syscall2(SYS_KILL, self(), SIGUSR1);
        struct kinfo wi;
        int order[6], n = 0;
        int64_t r;
        while (n < 6 && (r = take(set, &wi)) > 0) order[n++] = (int)r * 100 + (int)wi.kill.value;
        check(n == 4 && order[0] / 100 == SIGUSR1 && order[1] == RT * 100 + 8 && order[2] == RT * 100 + 9 && order[3] == RT1 * 100 + 7,
              "D: SIGUSR1, then SIGRTMIN (8, 9), then SIGRTMIN+1 (7)");
    }

    /* E: a handler runs once per queued instance when the signal is unblocked */
    {
        check(sigact(RT, (uint64_t)rt_handler, SA_SIGINFO) == 0, "E: install an SA_SIGINFO handler");
        seen_n = 0;
        for (int i = 1; i <= 4; i++) queue(RT, (uint64_t)i);
        unblock(bit(RT));
        const int ran_at_unblock = seen_n;
        print("hello274:        handler ran "); print_num(ran_at_unblock); print(" times before sigprocmask returned\n");
        check(ran_at_unblock == 4, "E: the handler ran four times before sigprocmask returned");
        check(seen_n == 4 && seen[0] == RT * 100 + 1 && seen[1] == RT * 100 + 2 && seen[2] == RT * 100 + 3 && seen[3] == RT * 100 + 4,
              "E: with the values 1, 2, 3, 4 in order");
        block(bit(RT));
    }

    /* F: setting SIG_IGN discards every queued instance */
    {
        sigact(RT, 0, 0);
        for (int i = 1; i <= 3; i++) queue(RT, (uint64_t)i);
        sigact(RT, 1, 0); /* SIG_IGN */
        sigact(RT, 0, 0);
        struct kinfo wi;
        check(take(bit(RT), &wi) == -11, "F: SIG_IGN discards all queued instances");
    }

    unblock(set);
    print(failures == 0 ? "hello274: PASS\n" : "hello274: FAIL\n");
    syscall1(SYS_EXIT, failures ? 1 : 0);
    for (;;) {}
}
