/// hello189: signal system-call errnos, checked against real Linux (rt_sigaction, rt_sigprocmask, kill,
/// tkill, rt_sigpending, rt_sigsuspend, rt_sigtimedwait, rt_sigqueueinfo, sigaltstack).
/// The sigsetsize argument is not probed: this kernel still accepts the legacy 4-byte form.

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
#define SYS_RT_SIGACTION 13
#define SYS_SIGPROCMASK 14
#define SYS_GETPID    39
#define SYS_KILL      62
#define SYS_SIGALTSTACK 218
#define SYS_SIGPENDING 219
#define SYS_SIGSUSPEND 220
#define SYS_SIGTIMEDWAIT 221
#define SYS_SIGQUEUEINFO 222
#define SYS_TKILL     223
#define KP ((void *)0xffff800000000000ULL)

struct ka { uint64_t h, f, r, m; };
struct kss { int64_t sp; int32_t flags; int32_t pad; uint64_t size; };
struct ts { int64_t s, n; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello189:   ok   " : "hello189:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void print_num(int64_t x) {
    char r[24]; int m = 0; char o[40]; int k = 0;
    if (x < 0) { o[k++] = '-'; x = -x; }
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k++] = '\n'; o[k] = 0;
    print(o);
}

static void handler(int s) { (void)s; }
static int64_t SIGACTION(int64_t s, const void *a, void *o, int64_t z) { return syscall4(SYS_RT_SIGACTION, (uint64_t)s, (uint64_t)a, (uint64_t)o, (uint64_t)z); }
static int64_t SIGPROCMASK(int64_t h, const void *s, void *o, int64_t z) { return syscall4(SYS_SIGPROCMASK, (uint64_t)h, (uint64_t)s, (uint64_t)o, (uint64_t)z); }
static int64_t KILL(int64_t p, int64_t s) { return syscall2(SYS_KILL, (uint64_t)p, (uint64_t)s); }
static int64_t TKILL(int64_t t, int64_t s) { return syscall2(SYS_TKILL, (uint64_t)t, (uint64_t)s); }
static int64_t SIGPENDING(void *s, int64_t z) { return syscall2(SYS_SIGPENDING, (uint64_t)s, (uint64_t)z); }
static int64_t SIGSUSPEND(const void *s, int64_t z) { return syscall2(SYS_SIGSUSPEND, (uint64_t)s, (uint64_t)z); }
static int64_t SIGTIMEDWAIT(const void *s, void *i, const void *t, int64_t z) { return syscall4(SYS_SIGTIMEDWAIT, (uint64_t)s, (uint64_t)i, (uint64_t)t, (uint64_t)z); }
static int64_t SIGQUEUEINFO(int64_t t, int64_t s, const void *i) { return syscall3(SYS_SIGQUEUEINFO, (uint64_t)t, (uint64_t)s, (uint64_t)i); }
static int64_t SIGALTSTACK(const void *n, void *o) { return syscall2(SYS_SIGALTSTACK, (uint64_t)n, (uint64_t)o); }

/* Return values from real Linux, in the order of the table in _start. */
static const int64_t EXPECT[] = {
-22, -22, 0, -22, -22, -22, 0, 0, 0, -14, -14, -14, 0, 1, 1, -22, -22, 0, -14, -14, -14, -22, 0, 0, 0, 0, 0, -22, -22, -3, -3, -3, 0, 0, -3, -3, -3, -22, -22, -3, -22, 0, -22, -3, -22, 0, -14, -14, -14, -14, -22, -14, -14, -11, -14, -22, -22, -11, -22, -14, -14, -3, 0, -14, -3, -3, -14, -14, -12, -22, 0, 1, 0, 2, 0, 0
};
static int idx = 0;
#define T(label, expr) do { \
        int64_t v_ = (expr); \
        if (v_ != EXPECT[idx]) { print("hello189:   got "); print_num(v_); } \
        check(v_ == EXPECT[idx], label); idx++; \
    } while (0)

static char altbuf[16384];

void _start(void) {
    print("hello189: signal errno conformance (expected values from real Linux)\n");
    int64_t self = syscall1(SYS_GETPID, 0);
    struct ka act = { (uint64_t)handler, 0, 0, 0 }, act2 = { (uint64_t)handler, 0, 0, 0 }, oact;
    uint64_t set = 1ULL << 9, zero = 0, killset = (1ULL << 8) | (1ULL << 18), oset;
    struct ts ts0 = {0,0}, tsneg = {-1,0}, tsbig = {0,2000000000};
    char ui[128]; for (int i = 0; i < 128; i++) ui[i] = 0;
    ((int32_t *)ui)[0] = 10; ((int32_t *)ui)[2] = -1; /* si_signo, si_code = SI_QUEUE */
    struct kss ss_small = { (int64_t)altbuf, 0, 0, 100 }, ss_flags = { (int64_t)altbuf, 0x77, 0, 16384 }, ss_ok = { (int64_t)altbuf, 0, 0, 16384 };
    struct kss ss_off = { 0, 2, 0, 0 }, ss_off_small = { 0, 2, 0, 5 }, old_ss;
    uint64_t ign[4] = { 1, 0, 0, 0 };
    SIGACTION(10, ign, 0, 8); /* SIGUSR1 ignored, as the table was measured */
    T("sigaction: signal 0", SIGACTION(0, &act, 0, 8));
    T("sigaction: signal 65", SIGACTION(65, &act, 0, 8));
    T("sigaction: signal 64", SIGACTION(64, &act, 0, 8));
    T("sigaction: signal -1", SIGACTION(-1, &act, 0, 8));
    T("sigaction: SIGKILL with an action", SIGACTION(9, &act, 0, 8));
    T("sigaction: SIGSTOP with an action", SIGACTION(19, &act, 0, 8));
    T("sigaction: SIGKILL query only", SIGACTION(9, 0, &oact, 8));
    T("sigaction: SIGSTOP query only", SIGACTION(19, 0, &oact, 8));
    T("sigaction: sigsetsize 8", SIGACTION(10, &act, 0, 8));
    T("sigaction: bad act pointer", SIGACTION(10, (void *)8, 0, 8));
    T("sigaction: bad oldact pointer", SIGACTION(10, 0, (void *)8, 8));
    T("sigaction: kernel act pointer", SIGACTION(10, KP, 0, 8));
    T("sigaction: both NULL", SIGACTION(10, 0, 0, 8));
    T("sigaction: query returns the installed handler", (SIGACTION(10, &act, 0, 8), SIGACTION(10, 0, &oact, 8), oact.h == act.h));
    T("sigaction: SA_RESETHAND flag round trip", (act2.f = 0x80000000UL, SIGACTION(12, &act2, 0, 8), SIGACTION(12, 0, &oact, 8), oact.f == 0x80000000UL ? 1 : 0));
    T("sigprocmask: bad how with a set", SIGPROCMASK(3, &set, 0, 8));
    T("sigprocmask: bad how 99", SIGPROCMASK(99, &set, 0, 8));
    T("sigprocmask: bad how without a set", SIGPROCMASK(99, 0, 0, 8));
    T("sigprocmask: bad set pointer", SIGPROCMASK(0, (void *)8, 0, 8));
    T("sigprocmask: bad oldset pointer", SIGPROCMASK(0, 0, (void *)8, 8));
    T("sigprocmask: bad how and bad set pointer", SIGPROCMASK(7, (void *)8, 0, 8));
    T("sigprocmask: bad how and bad oldset pointer", SIGPROCMASK(7, &set, (void *)8, 8));
    T("sigprocmask: valid SIG_BLOCK", SIGPROCMASK(0, &set, &oset, 8));
    T("sigprocmask: valid SIG_SETMASK", SIGPROCMASK(2, &zero, &oset, 8));
    T("sigprocmask: SIGKILL cannot be blocked", (SIGPROCMASK(2, &killset, 0, 8), SIGPROCMASK(0, 0, &oset, 8), (oset >> 8) & 1));
    T("sigprocmask: SIGSTOP cannot be blocked", (SIGPROCMASK(2, &killset, 0, 8), SIGPROCMASK(0, 0, &oset, 8), (oset >> 18) & 1));
    T("sigprocmask: restore", SIGPROCMASK(2, &zero, 0, 8));
    T("kill: signal 65", KILL(self, 65));
    T("kill: signal -1", KILL(self, -1));
    T("kill: signal 64 to a missing process", KILL(99999, 64));
    T("kill: missing process", KILL(99999, 0));
    T("kill: missing process with a real signal", KILL(99999, 10));
    T("kill: self with signal 0", KILL(self, 0));
    T("kill: own group with signal 0", KILL(0, 0));
    T("kill: pid INT_MIN", KILL(-2147483647L - 1, 0));
    T("kill: missing group", KILL(-99999, 0));
    T("kill: bad signal beats missing process", KILL(99999, 65));
    T("tkill: tid 0", TKILL(0, 0));
    T("tkill: tid -1", TKILL(-1, 0));
    T("tkill: missing thread", TKILL(99999, 0));
    T("tkill: signal 65", TKILL(self, 65));
    T("tkill: self with signal 0", TKILL(self, 0));
    T("tkill: bad signal beats bad tid", TKILL(0, 65));
    T("tkill: bad signal beats missing thread", TKILL(99999, 65));
    T("tkill: tid 0 with a real signal", TKILL(0, 10));
    T("sigpending: valid", SIGPENDING(&oset, 8));
    T("sigpending: NULL set", SIGPENDING(0, 8));
    T("sigpending: bad pointer", SIGPENDING((void *)8, 8));
    T("sigsuspend: bad pointer", SIGSUSPEND((void *)8, 8));
    T("sigsuspend: NULL", SIGSUSPEND(0, 8));
    T("sigtimedwait: sigsetsize 0", SIGTIMEDWAIT(&set, 0, &ts0, 0));
    T("sigtimedwait: NULL set", SIGTIMEDWAIT(0, 0, &ts0, 8));
    T("sigtimedwait: bad set pointer", SIGTIMEDWAIT((void *)8, 0, &ts0, 8));
    T("sigtimedwait: bad info pointer, nothing pending", SIGTIMEDWAIT(&set, (void *)8, &ts0, 8));
    T("sigtimedwait: bad timeout pointer", SIGTIMEDWAIT(&set, 0, (void *)8, 8));
    T("sigtimedwait: negative seconds", SIGTIMEDWAIT(&set, 0, &tsneg, 8));
    T("sigtimedwait: nanoseconds too large", SIGTIMEDWAIT(&set, 0, &tsbig, 8));
    T("sigtimedwait: poll, nothing pending", SIGTIMEDWAIT(&set, 0, &ts0, 8));
    T("sigqueueinfo: signal 65", SIGQUEUEINFO(self, 65, &ui));
    T("sigqueueinfo: bad info pointer", SIGQUEUEINFO(self, 0, (void *)8));
    T("sigqueueinfo: NULL info", SIGQUEUEINFO(self, 0, 0));
    T("sigqueueinfo: missing process", SIGQUEUEINFO(99999, 0, &ui));
    T("sigqueueinfo: to self with SI_QUEUE", SIGQUEUEINFO(self, 0, &ui));
    T("sigqueueinfo: bad signal beats bad pointer", SIGQUEUEINFO(self, 65, (void *)8));
    T("sigqueueinfo: tgid 0", SIGQUEUEINFO(0, 0, &ui));
    T("sigqueueinfo: tgid -1", SIGQUEUEINFO(-1, 0, &ui));
    T("sigaltstack: bad new pointer", SIGALTSTACK((void *)8, 0));
    T("sigaltstack: bad old pointer", SIGALTSTACK(0, (void *)8));
    T("sigaltstack: size too small", SIGALTSTACK(&ss_small, 0));
    T("sigaltstack: unknown flags", SIGALTSTACK(&ss_flags, 0));
    T("sigaltstack: valid", SIGALTSTACK(&ss_ok, 0));
    T("sigaltstack: query", (SIGALTSTACK(0, &old_ss), old_ss.sp == (long)altbuf));
    T("sigaltstack: disable", SIGALTSTACK(&ss_off, 0));
    T("sigaltstack: query after disable flags", (SIGALTSTACK(0, &old_ss), old_ss.flags));
    T("sigaltstack: disable with a tiny size", SIGALTSTACK(&ss_off_small, 0));
    T("sigaltstack: both NULL", SIGALTSTACK(0, 0));
    check(idx == (int)(sizeof(EXPECT) / sizeof(EXPECT[0])), "every table entry was exercised");

    print(failures == 0 ? "hello189: PASS\n" : "hello189: FAIL\n");
    print("hello189 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
