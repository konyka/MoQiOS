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
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_PIPE      22
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_GETPID    39
#define SYS_KILL      62
#define SYS_SIGACTION 13
#define SYS_SIGPROCMASK 14
#define SYS_CLOCK_GETTIME 228
#define SYS_PPOLL     493
#define SYS_PSELECT6  494
#define SIGUSR1 10
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define POLLIN  0x001
#define EINTR_  4
#define EBADF_  9
#define EFAULT_ 14
#define EINVAL_ 22

struct pfd { int32_t fd; int16_t events, revents; };
struct ts { int64_t s, n; };
struct ksigaction { uint64_t handler, flags, restorer, mask; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello140:   ok   " : "hello140:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static int64_t now_ms(void) {
    struct ts t;
    syscall2(SYS_CLOCK_GETTIME, 1, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static volatile int got;
static void handler(int s) { got = s; }
__attribute__((naked)) static void restorer(void) { __asm__ volatile ("movq $15, %rax\n syscall"); }
static int64_t sigact(int sig, uint64_t h) {
    struct ksigaction a = { h, 0x04000000, (uint64_t)restorer, 0 };
    return syscall4(SYS_SIGACTION, (uint64_t)sig, (uint64_t)&a, 0, 8);
}
static uint64_t self(void) { return (uint64_t)syscall1(SYS_GETPID, 0); }
static uint64_t cur_mask(void) {
    uint64_t m = 0;
    syscall4(SYS_SIGPROCMASK, SIG_BLOCK, 0, (uint64_t)&m, 8);
    return m;
}
static int64_t do_ppoll(int fd, const struct ts *tmo, const uint64_t *mask, uint64_t masksz, int16_t *rev) {
    struct pfd p = { fd, POLLIN, 0 };
    int64_t r = syscall5(SYS_PPOLL, (uint64_t)&p, 1, (uint64_t)tmo, (uint64_t)mask, masksz);
    if (rev) *rev = p.revents;
    return r;
}
static int64_t do_pselect(int fd, const struct ts *tmo, const uint64_t *mask, uint64_t masksz) {
    uint64_t set[16];
    volatile uint64_t *v = set;
    for (int i = 0; i < 16; i++) v[i] = 0;
    set[fd / 64] |= 1ULL << (fd % 64);
    struct { uint64_t ss; uint64_t len; } sd = { (uint64_t)mask, masksz };
    return syscall6(SYS_PSELECT6, (uint64_t)(fd + 1), (uint64_t)set, 0, 0, (uint64_t)tmo, mask ? (uint64_t)&sd : 0);
}

void _start(void) {
    print("hello140: ppoll and pselect6\n");
    int16_t rev;
    int pp[2];
    syscall1(SYS_PIPE, (uint64_t)pp);

    /* A: ppoll readiness and timeout */
    {
        struct ts zero = { 0, 0 };
        check(do_ppoll(pp[0], &zero, 0, 0, &rev) == 0, "A: ppoll(empty pipe, {0,0}) reports nothing");
        struct ts t50 = { 0, 50000000 };
        int64_t t0 = now_ms();
        int64_t r = do_ppoll(pp[0], &t50, 0, 0, &rev);
        int64_t dt = now_ms() - t0;
        check(r == 0 && dt >= 40 && dt < 300, "A: a 50 ms timespec timeout takes about 50 ms");
        struct ts t1 = { 0, 1 };
        check(do_ppoll(pp[0], &t1, 0, 0, &rev) == 0, "A: a 1 ns timeout still returns 0");
        syscall3(SYS_WRITE, pp[1], (uint64_t)"x", 1);
        check(do_ppoll(pp[0], 0, 0, 0, &rev) == 1 && (rev & POLLIN), "A: ppoll with a NULL timeout returns at once when ready");
        char c;
        syscall3(SYS_READ, pp[0], (uint64_t)&c, 1);
    }

    /* B: argument rules */
    {
        struct ts bad = { 0, 1000000000 };
        check(do_ppoll(pp[0], &bad, 0, 0, &rev) == -EINVAL_, "B: tv_nsec >= 1e9 is EINVAL");
        struct ts neg = { -1, 0 };
        check(do_ppoll(pp[0], &neg, 0, 0, &rev) == -EINVAL_, "B: negative tv_sec is EINVAL");
        uint64_t m = 0;
        struct ts zero = { 0, 0 };
        check(do_ppoll(pp[0], &zero, &m, 4, &rev) == -EINVAL_, "B: sigsetsize other than 8 is EINVAL");
        check(syscall5(SYS_PPOLL, 0, 1, 0, 0, 0) == -EFAULT_, "B: ppoll(NULL, 1) is EFAULT");
        check(syscall5(SYS_PPOLL, 0, 0, (uint64_t)&zero, 0, 0) == 0, "B: ppoll(NULL, 0, {0,0}) is an empty poll");
    }

    /* A2: a temporary mask is undone when the call returns normally */
    {
        uint64_t before = cur_mask();
        uint64_t all = ~0ULL;
        struct ts zero = { 0, 0 };
        syscall3(SYS_WRITE, pp[1], (uint64_t)"x", 1);
        check(do_ppoll(pp[0], &zero, &all, 8, &rev) == 1, "A2: ppoll with a full temporary mask still reports readiness");
        check(cur_mask() == before, "A2: and the mask is unchanged after a normal return");
        check(do_pselect(pp[0], &zero, &all, 8) == 1, "A2: pselect6 with a full temporary mask reports readiness");
        check(cur_mask() == before, "A2: and its mask is unchanged too");
        char c;
        syscall3(SYS_READ, pp[0], (uint64_t)&c, 1);
    }

    /* C: ppoll's temporary mask lets a blocked signal in, and is undone afterwards */
    {
        sigact(SIGUSR1, (uint64_t)handler);
        uint64_t blk = 1ULL << (SIGUSR1 - 1);
        syscall4(SYS_SIGPROCMASK, SIG_BLOCK, (uint64_t)&blk, 0, 8);
        uint64_t parent = self();
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            sleep_ms(100);
            syscall2(SYS_KILL, parent, SIGUSR1);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        uint64_t empty = 0;
        got = 0;
        struct ts t2 = { 2, 0 };
        int64_t r = do_ppoll(pp[0], &t2, &empty, 8, &rev);
        check(r == -EINTR_, "C: ppoll with an empty mask is interrupted by the blocked signal");
        check(got == SIGUSR1, "C: and the handler ran before ppoll returned");
        check((cur_mask() & blk) != 0, "C: and the original mask is back afterwards");
        int st = 0;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);

        /* without a temporary mask the blocked signal only becomes pending */
        got = 0;
        child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            sleep_ms(50);
            syscall2(SYS_KILL, parent, SIGUSR1);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        struct ts t150 = { 0, 150000000 };
        r = do_ppoll(pp[0], &t150, 0, 0, &rev);
        check(r == 0 && got == 0, "C: with no mask argument the blocked signal does not interrupt ppoll");
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        syscall4(SYS_SIGPROCMASK, SIG_UNBLOCK, (uint64_t)&blk, 0, 8);
        got = 0;
    }

    /* D: pselect6 */
    {
        struct ts zero = { 0, 0 };
        check(do_pselect(pp[0], &zero, 0, 0) == 0, "D: pselect6(empty pipe, {0,0}) reports nothing");
        struct ts t50 = { 0, 50000000 };
        int64_t t0 = now_ms();
        int64_t r = do_pselect(pp[0], &t50, 0, 0);
        int64_t dt = now_ms() - t0;
        check(r == 0 && dt >= 40 && dt < 300, "D: a 50 ms timespec timeout takes about 50 ms");
        syscall3(SYS_WRITE, pp[1], (uint64_t)"x", 1);
        check(do_pselect(pp[0], &zero, 0, 0) == 1, "D: a readable pipe is reported");
        char c;
        syscall3(SYS_READ, pp[0], (uint64_t)&c, 1);
        struct ts bad = { 0, 1000000000 };
        check(do_pselect(pp[0], &bad, 0, 0) == -EINVAL_, "D: tv_nsec >= 1e9 is EINVAL");
        uint64_t m = 0;
        check(do_pselect(pp[0], &zero, &m, 4) == -EINVAL_, "D: a sigset size other than 8 is EINVAL");
        check(do_pselect(40, &zero, 0, 0) == -EBADF_, "D: a closed fd in the set is EBADF");

        uint64_t blk = 1ULL << (SIGUSR1 - 1);
        syscall4(SYS_SIGPROCMASK, SIG_BLOCK, (uint64_t)&blk, 0, 8);
        uint64_t parent = self();
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            sleep_ms(100);
            syscall2(SYS_KILL, parent, SIGUSR1);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        uint64_t empty = 0;
        got = 0;
        struct ts t2 = { 2, 0 };
        r = do_pselect(pp[0], &t2, &empty, 8);
        check(r == -EINTR_ && got == SIGUSR1, "D: an empty temporary mask lets the blocked signal interrupt pselect6");
        check((cur_mask() & blk) != 0, "D: and the original mask is restored");
        int st = 0;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        syscall4(SYS_SIGPROCMASK, SIG_UNBLOCK, (uint64_t)&blk, 0, 8);
    }

    print(failures == 0 ? "hello140: PASS\n" : "hello140: FAIL\n");
    print("hello140 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
