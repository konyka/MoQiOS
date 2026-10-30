/// hello132: clocks and sleeping: clock ids, resolution, monotonicity, sleep errors.

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
#define SYS_NANOSLEEP 35
#define SYS_GETTIMEOFDAY 96
#define SYS_CLOCK_GETTIME 228
#define SYS_CLOCK_GETRES 269
#define SYS_CLOCK_NANOSLEEP 247

#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define CLOCK_THREAD_CPUTIME_ID 3
#define CLOCK_MONOTONIC_RAW 4
#define CLOCK_REALTIME_COARSE 5
#define CLOCK_MONOTONIC_COARSE 6
#define CLOCK_BOOTTIME 7
#define TIMER_ABSTIME 1

#define EFAULT_ 14
#define EINVAL_ 22

struct ts { int64_t sec, nsec; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello132:   ok   " : "hello132:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t now_ns(uint64_t clk) {
    struct ts t;
    if (syscall2(SYS_CLOCK_GETTIME, clk, (uint64_t)&t) != 0) return -1;
    return t.sec * 1000000000LL + t.nsec;
}

void _start(void) {
    print("hello132: clocks and sleeping\n");
    struct ts t;

    /* A: clock ids */
    uint64_t ok_ids[] = { CLOCK_REALTIME, CLOCK_MONOTONIC, CLOCK_MONOTONIC_RAW, CLOCK_REALTIME_COARSE, CLOCK_MONOTONIC_COARSE, CLOCK_BOOTTIME };
    const char *names[] = { "REALTIME", "MONOTONIC", "MONOTONIC_RAW", "REALTIME_COARSE", "MONOTONIC_COARSE", "BOOTTIME" };
    for (int i = 0; i < 6; i++) {
        char msg[64]; int k = 0;
        const char *pre = "A: clock_gettime(CLOCK_";
        while (*pre) msg[k++] = *pre++;
        for (const char *p = names[i]; *p; p++) msg[k++] = *p;
        msg[k++] = ')'; msg[k] = 0;
        check(syscall2(SYS_CLOCK_GETTIME, ok_ids[i], (uint64_t)&t) == 0 && t.nsec >= 0 && t.nsec < 1000000000, msg);
    }
    check(syscall2(SYS_CLOCK_GETTIME, CLOCK_PROCESS_CPUTIME_ID, (uint64_t)&t) == 0, "A: CLOCK_PROCESS_CPUTIME_ID is readable");
    check(syscall2(SYS_CLOCK_GETTIME, CLOCK_THREAD_CPUTIME_ID, (uint64_t)&t) == 0, "A: CLOCK_THREAD_CPUTIME_ID is readable");
    check(syscall2(SYS_CLOCK_GETTIME, 99, (uint64_t)&t) == -EINVAL_, "A: an unknown clock id is EINVAL");
    check(syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, 0) == -EFAULT_, "A: a NULL result pointer is EFAULT");

    /* B: monotonic never goes backwards, realtime is a plausible epoch time */
    int64_t a = now_ns(CLOCK_MONOTONIC), b = now_ns(CLOCK_MONOTONIC);
    check(a > 0 && b >= a, "B: CLOCK_MONOTONIC does not go backwards");
    int64_t r1 = now_ns(CLOCK_MONOTONIC_RAW), r2 = now_ns(CLOCK_MONOTONIC_RAW);
    check(r1 > 0 && r2 >= r1, "B: CLOCK_MONOTONIC_RAW does not go backwards");
    check(now_ns(CLOCK_REALTIME) > 1500000000LL * 1000000000LL, "B: CLOCK_REALTIME is after 2017 (RTC-based)");
    struct ts rt;
    syscall2(SYS_CLOCK_GETTIME, CLOCK_REALTIME, (uint64_t)&rt);
    int64_t tv[2] = { 0, 0 };
    check(syscall2(SYS_GETTIMEOFDAY, (uint64_t)tv, 0) == 0 && tv[0] >= rt.sec - 1 && tv[0] <= rt.sec + 2, "B: gettimeofday agrees with CLOCK_REALTIME");
    check(syscall2(SYS_GETTIMEOFDAY, (uint64_t)tv, (uint64_t)tv) == 0, "B: gettimeofday accepts a timezone pointer");
    check(syscall2(SYS_GETTIMEOFDAY, 0, 0) == 0, "B: gettimeofday(NULL, NULL) succeeds (nothing to write)");

    /* C: resolution */
    check(syscall2(SYS_CLOCK_GETRES, CLOCK_MONOTONIC, (uint64_t)&t) == 0 && t.sec == 0 && t.nsec >= 1, "C: clock_getres reports a resolution");
    check(syscall2(SYS_CLOCK_GETRES, CLOCK_MONOTONIC_RAW, (uint64_t)&t) == 0, "C: clock_getres(CLOCK_MONOTONIC_RAW)");
    check(syscall2(SYS_CLOCK_GETRES, 99, (uint64_t)&t) == -EINVAL_, "C: clock_getres of an unknown id is EINVAL");

    /* D: sleeping */
    struct ts req = { 0, 20000000 }; /* 20 ms */
    int64_t s0 = now_ns(CLOCK_MONOTONIC);
    check(syscall2(SYS_NANOSLEEP, (uint64_t)&req, 0) == 0, "D: nanosleep(20 ms) returns 0");
    int64_t s1 = now_ns(CLOCK_MONOTONIC);
    check(s1 - s0 >= 20000000, "D: and slept at least 20 ms");
    check(s1 - s0 < 2000000000LL, "D: and not absurdly long");
    struct ts bad1 = { 0, 1000000000 }, bad2 = { 0, -1 }, bad3 = { -1, 0 };
    check(syscall2(SYS_NANOSLEEP, (uint64_t)&bad1, 0) == -EINVAL_, "D: nanosleep with tv_nsec >= 1e9 is EINVAL");
    check(syscall2(SYS_NANOSLEEP, (uint64_t)&bad2, 0) == -EINVAL_, "D: nanosleep with a negative tv_nsec is EINVAL");
    check(syscall2(SYS_NANOSLEEP, (uint64_t)&bad3, 0) == -EINVAL_, "D: nanosleep with negative seconds is EINVAL");
    check(syscall2(SYS_NANOSLEEP, 0, 0) == -EFAULT_, "D: nanosleep with a NULL request is EFAULT");
    struct ts zero = { 0, 0 };
    check(syscall2(SYS_NANOSLEEP, (uint64_t)&zero, 0) == 0, "D: nanosleep(0) returns at once");
    /* absolute clock_nanosleep: a deadline in the past returns immediately */
    struct ts past = { 1, 0 };
    s0 = now_ns(CLOCK_MONOTONIC);
    check(syscall4(SYS_CLOCK_NANOSLEEP, CLOCK_MONOTONIC, TIMER_ABSTIME, (uint64_t)&past, 0) == 0, "D: an absolute deadline in the past returns 0");
    check(now_ns(CLOCK_MONOTONIC) - s0 < 500000000LL, "D: without sleeping");
    /* absolute deadline 20 ms ahead */
    struct ts fut; int64_t base = now_ns(CLOCK_MONOTONIC) + 20000000;
    fut.sec = base / 1000000000LL; fut.nsec = base % 1000000000LL;
    check(syscall4(SYS_CLOCK_NANOSLEEP, CLOCK_MONOTONIC, TIMER_ABSTIME, (uint64_t)&fut, 0) == 0 && now_ns(CLOCK_MONOTONIC) >= base, "D: an absolute deadline in the future is honoured");
    check(syscall4(SYS_CLOCK_NANOSLEEP, 99, 0, (uint64_t)&req, 0) == -EINVAL_, "D: clock_nanosleep with an unknown clock is EINVAL");
    check(syscall4(SYS_CLOCK_NANOSLEEP, CLOCK_MONOTONIC, 0x4, (uint64_t)&req, 0) == -EINVAL_, "D: clock_nanosleep with unknown flags is EINVAL");

    print(failures == 0 ? "hello132: PASS\n" : "hello132: FAIL\n");
    print("hello132 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
