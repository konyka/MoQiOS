/// hello117: prctl(2) process attributes.
///
///   A. PR_SET_PDEATHSIG: a process that asked for SIGKILL on parent death
///      dies when its parent exits (observed as EOF on a pipe only it holds).
///   B. PR_SET_PDEATHSIG rejects invalid signals; the setting is not
///      inherited by fork; PR_GET_PDEATHSIG reads it back.
///   C. PR_SET_NO_NEW_PRIVS / PR_GET_NO_NEW_PRIVS: one-way flag, inherited
///      by fork, strict argument checks.

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
static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_PIPE      22
#define SYS_NANOSLEEP 35
#define SYS_FORK      57
#define SYS_PRCTL     241
#define SYS_CLOCK_GETTIME 228
#define PR_SET_PDEATHSIG 1
#define PR_GET_PDEATHSIG 2
#define PR_SET_NO_NEW_PRIVS 38
#define PR_GET_NO_NEW_PRIVS 39
#define SIGKILL 9
#define EINVAL_ 22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello117:   ok   " : "hello117:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t prctl(uint64_t op, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    return syscall5(SYS_PRCTL, op, a2, a3, a4, a5);
}
struct timespec { int64_t sec, nsec; };
static int64_t now_ms(void) {
    struct timespec ts = { 0, 0 };
    syscall3(SYS_CLOCK_GETTIME, 1, (uint64_t)&ts, 0);
    return ts.sec * 1000 + ts.nsec / 1000000;
}
static void sleep_ms(int64_t ms) {
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000 };
    syscall3(SYS_NANOSLEEP, (uint64_t)&ts, 0, 0);
}

static void parent_death(void) {
    int32_t fds[2] = { -1, -1 };
    check(syscall1(SYS_PIPE, (uint64_t)fds) == 0, "A: pipe");
    int32_t ready[2] = { -1, -1 };
    check(syscall1(SYS_PIPE, (uint64_t)ready) == 0, "A: ready pipe");
    int64_t middle = syscall1(SYS_FORK, 0);
    if (middle == 0) {
        int64_t gc = syscall1(SYS_FORK, 0);
        if (gc == 0) {
            /* only the grandchild keeps the write end */
            syscall1(SYS_CLOSE, (uint64_t)fds[0]);
            syscall1(SYS_CLOSE, (uint64_t)ready[0]);
            prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0);
            syscall3(SYS_WRITE, (uint64_t)ready[1], (uint64_t)"r", 1);
            syscall1(SYS_CLOSE, (uint64_t)ready[1]);
            for (int i = 0; i < 400; i++) sleep_ms(25); /* ~10 s unless killed */
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        syscall1(SYS_CLOSE, (uint64_t)fds[1]);
        syscall1(SYS_CLOSE, (uint64_t)ready[1]);
        char b;
        syscall3(SYS_READ, (uint64_t)ready[0], (uint64_t)&b, 1); /* PDEATHSIG is armed */
        syscall1(SYS_EXIT, 0); /* the grandchild's parent dies now */
        for (;;) {}
    }
    syscall1(SYS_CLOSE, (uint64_t)fds[1]);
    syscall1(SYS_CLOSE, (uint64_t)ready[0]);
    syscall1(SYS_CLOSE, (uint64_t)ready[1]);
    int32_t st = 0;
    syscall3(SYS_WAITPID, (uint64_t)middle, (uint64_t)&st, 0);
    /* EOF on the pipe means the grandchild is gone; it would otherwise sleep ~10 s */
    char b;
    const int64_t t0 = now_ms();
    int64_t n = syscall3(SYS_READ, (uint64_t)fds[0], (uint64_t)&b, 1);
    const int64_t waited = now_ms() - t0;
    check(n == 0, "A: the pipe reaches EOF");
    /* the orphan sleeps ~10 s unless the death signal kills it at once */
    check(waited < 3000, "A: the orphan with PDEATHSIG=SIGKILL died with its parent (not after its 10 s sleep)");
    syscall1(SYS_CLOSE, (uint64_t)fds[0]);
}

void _start(void) {
    print("hello117: prctl process attributes\n");
    uint32_t sig = 0xDEAD;

    /* B */
    check(prctl(PR_SET_PDEATHSIG, 65, 0, 0, 0) == -EINVAL_, "B: PDEATHSIG 65 is EINVAL");
    check(prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) == 0, "B: PDEATHSIG SIGKILL accepted");
    check(prctl(PR_GET_PDEATHSIG, (uint64_t)&sig, 0, 0, 0) == 0 && sig == SIGKILL, "B: PR_GET_PDEATHSIG reads it back");
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        uint32_t s2 = 0xDEAD;
        prctl(PR_GET_PDEATHSIG, (uint64_t)&s2, 0, 0, 0);
        syscall1(SYS_EXIT, s2 == 0 ? 0 : 1);
        for (;;) {}
    }
    int32_t st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    check(kid > 0 && st == 0, "B: fork does not inherit PDEATHSIG");
    check(prctl(PR_SET_PDEATHSIG, 0, 0, 0, 0) == 0, "B: PDEATHSIG cleared");

    /* C */
    check(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 0, "C: NO_NEW_PRIVS starts clear");
    check(prctl(PR_SET_NO_NEW_PRIVS, 0, 0, 0, 0) == -EINVAL_, "C: SET_NO_NEW_PRIVS(0) is EINVAL (cannot clear)");
    check(prctl(PR_SET_NO_NEW_PRIVS, 1, 1, 0, 0) == -EINVAL_, "C: extra arguments are EINVAL");
    kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        int ok = prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0 && prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1;
        int64_t gk = syscall1(SYS_FORK, 0);
        if (gk == 0) syscall1(SYS_EXIT, prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1 ? 0 : 1);
        int32_t gs = -1;
        syscall3(SYS_WAITPID, (uint64_t)gk, (uint64_t)&gs, 0);
        syscall1(SYS_EXIT, ok && gs == 0 ? 0 : 1);
        for (;;) {}
    }
    st = -1;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    check(kid > 0 && st == 0, "C: SET_NO_NEW_PRIVS(1) sticks and is inherited by fork");
    check(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 0, "C: the parent's flag is unaffected");

    /* A */
    parent_death();

    print(failures == 0 ? "hello117: PASS\n" : "hello117: FAIL\n");
    print("hello117 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
