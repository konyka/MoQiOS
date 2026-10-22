/// hello111: POSIX kill(2) semantics and SIGCHLD.
///
///   A. kill(pid, 0) probes: 0 for a live child, -ESRCH for a bogus pid;
///      kill(-1, 0) reaches the other processes.
///   B. kill(0, sig) reaches the caller's own process group.
///   C. a child's exit raises SIGCHLD in the parent (handler runs).
///   D. with SIGCHLD set to SIG_IGN, exited children are reaped
///      automatically: waitpid then reports ECHILD instead of a zombie.

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

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_SIGACTION 13
#define SYS_NANOSLEEP 35
#define SYS_GETPID    39
#define SYS_FORK      57
#define SYS_KILL      62
#define SYS_WAIT4     61

#define SIGUSR1  10
#define SIGCHLD  17
#define WNOHANG  1
#define ESRCH    3
#define ECHILD   10

struct ksigaction { uint64_t handler, flags, restorer, mask; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello111:   ok   " : "hello111:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void nap_ms(int64_t ms) {
    int64_t ts[2] = { ms / 1000, (ms % 1000) * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)ts, 0);
}

static volatile int usr1_hits = 0;
static void on_usr1(int s) { (void)s; usr1_hits++; }
static volatile int chld_hits = 0;
static void on_chld(int s) { (void)s; chld_hits++; }

static long install(int sig, uint64_t handler) {
    struct ksigaction a = { handler, 0, 0, 0 };
    return syscall3(SYS_SIGACTION, sig, (uint64_t)&a, 0);
}

void _start(void) {
    print("hello111: kill(2) semantics and SIGCHLD\n");

    /* A. kill(pid, 0) */
    int64_t child = syscall1(SYS_FORK, 0);
    if (child == 0) { nap_ms(300); syscall1(SYS_EXIT, 0); for (;;) {} }
    check(syscall2(SYS_KILL, (uint64_t)child, 0) == 0, "A: kill(child, 0) == 0 for a live child");
    check(syscall2(SYS_KILL, 999999, 0) == -ESRCH, "A: kill(bogus, 0) == -ESRCH");
    check(syscall2(SYS_KILL, (uint64_t)-1, 0) == 0, "A: kill(-1, 0) finds other processes");
    int32_t st = 0;
    syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);

    /* B. kill(0, sig) hits our own process group (including ourselves). */
    install(SIGUSR1, (uint64_t)on_usr1);
    check(syscall2(SYS_KILL, 0, SIGUSR1) == 0, "B: kill(0, SIGUSR1) accepted");
    check(usr1_hits == 1, "B: own process group received the signal");

    /* C. SIGCHLD on child exit */
    install(SIGCHLD, (uint64_t)on_chld);
    child = syscall1(SYS_FORK, 0);
    if (child == 0) { syscall1(SYS_EXIT, 7); for (;;) {} }
    st = 0;
    check(syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0) == child, "C: waitpid reaps the child");
    for (int i = 0; i < 50 && chld_hits == 0; i++) nap_ms(10);
    check(chld_hits >= 1, "C: SIGCHLD delivered to the parent");
    check(((st >> 8) & 0xff) == 7 && (st & 0x7f) == 0, "C: wait status is WIFEXITED/WEXITSTATUS 7");

    /* D. SIGCHLD = SIG_IGN auto-reaps */
    install(SIGCHLD, 1);
    child = syscall1(SYS_FORK, 0);
    if (child == 0) { syscall1(SYS_EXIT, 0); for (;;) {} }
    int64_t r = 0;
    for (int i = 0; i < 100; i++) {
        nap_ms(10);
        r = syscall4(SYS_WAIT4, (uint64_t)-1, (uint64_t)&st, WNOHANG, 0);
        if (r == -ECHILD) break;
    }
    check(r == -ECHILD, "D: SIG_IGN SIGCHLD child is auto-reaped (ECHILD)");
    install(SIGCHLD, 0);

    print(failures == 0 ? "hello111: PASS\n" : "hello111: FAIL\n");
    print("hello111 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
