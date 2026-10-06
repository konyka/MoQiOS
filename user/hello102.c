/// hello102: blocking clock_nanosleep, validated nanosleep, real getrusage.
///
/// clock_nanosleep used to spin with `pause` inside the syscall, where
/// interrupts are masked: for the whole sleep the CPU could not take a tick,
/// run another task or deliver a signal. nanosleep multiplied an unchecked
/// tv_sec by 1e9, which panics a Debug kernel. getrusage reported 70%/30% of
/// system uptime instead of the caller's CPU time.
///
///   A. getrusage(RUSAGE_SELF) after ~300 ms of spinning reports at least
///      150 ms and never more than the process has been alive; a bad `who`
///      is EINVAL.
///   B. a spinner thread pinned to the same CPU keeps running while the main
///      thread sleeps in clock_nanosleep.
///   C. TIMER_ABSTIME sleeps until the deadline and leaves `rem` untouched; a
///      deadline in the past returns at once.
///   D. invalid clocks, flags and timespecs are EINVAL for both syscalls.
///   E. alarm(1) interrupts a 5 s clock_nanosleep with EINTR and a sane `rem`.
///   F. an unrepresentably long nanosleep is interrupted by alarm(1) instead
///      of overflowing.

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

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE           1
#define SYS_EXIT            2
#define SYS_MMAP            8
#define SYS_SIGACTION       13
#define SYS_SCHED_YIELD     24
#define SYS_NANOSLEEP       35
#define SYS_ALARM           37
#define SYS_GETRUSAGE       98
#define SYS_CLOCK_GETTIME   228
#define SYS_CLONE           243
#define SYS_CLOCK_NANOSLEEP 247
#define SYS_SETAFFINITY     273

#define CLOCK_REALTIME  0
#define CLOCK_MONOTONIC 1
#define TIMER_ABSTIME   1

#define RUSAGE_SELF     0
#define RUSAGE_CHILDREN (-1)

#define SIGALRM 14

#define EINTR  4
#define EINVAL 22

#define CLONE_VM     0x100
#define CLONE_FILES  0x400
#define CLONE_THREAD 0x10000

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define STACK_SIZE (16 * 4096)
#define NS_PER_MS  1000000LL
#define NS_PER_SEC 1000000000LL

struct timespec { int64_t sec; int64_t nsec; };
struct timeval  { int64_t sec; int64_t usec; };
struct rusage   { struct timeval utime; struct timeval stime; int64_t rest[14]; };

struct ksigaction {
    void (*handler)(int);
    unsigned long mask;
    unsigned long flags;
    void *restorer;
};

static int failures;

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_dec(int64_t v) {
    char buf[24];
    int pos = 0;
    if (v < 0) { print("-"); v = -v; }
    if (v == 0) { print("0"); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char t = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = t; }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

static void check(int ok, const char *what) {
    if (ok) return;
    failures++;
    print("hello102: FAIL ");
    print(what);
    print("\n");
}

static void report(const char *label, int64_t value) {
    print("hello102:   ");
    print(label);
    print("=");
    print_dec(value);
    print("\n");
}

static int64_t now_ns(void) {
    struct timespec ts = { 0, 0 };
    syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (uint64_t)&ts);
    return ts.sec * NS_PER_SEC + ts.nsec;
}

static int64_t clock_sleep(int clock, int flags, int64_t sec, int64_t nsec, struct timespec *rem) {
    struct timespec req = { sec, nsec };
    return syscall4(SYS_CLOCK_NANOSLEEP, clock, flags, (uint64_t)&req, (uint64_t)rem);
}

static volatile int alarm_seen;

static void on_alarm(int sig) {
    (void)sig;
    alarm_seen = 1;
}

static uint64_t cpu0_mask = 1;
static volatile int stop_spinner;
static volatile int spinner_done;
static volatile uint64_t spinner_count;

/// Runs on the clone stack: touches globals only, never returns.
static __attribute__((noinline, noreturn)) void spinner_main(void) {
    syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&cpu0_mask);
    syscall1(SYS_SCHED_YIELD, 0);
    while (!stop_spinner) spinner_count++;
    spinner_done = 1;
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

static void probe_getrusage(int64_t start_ns) {
    const int64_t spin_until = now_ns() + 300 * NS_PER_MS;
    while (now_ns() < spin_until) {}

    struct rusage ru;
    for (int i = 0; i < (int)(sizeof(ru) / 8); i++) ((int64_t *)&ru)[i] = -1;
    check(syscall2(SYS_GETRUSAGE, RUSAGE_SELF, (uint64_t)&ru) == 0, "getrusage(SELF)");
    const int64_t cpu_us = ru.utime.sec * 1000000 + ru.utime.usec + ru.stime.sec * 1000000 + ru.stime.usec;
    const int64_t alive_us = (now_ns() - start_ns) / 1000;
    report("cpu_us", cpu_us);
    report("alive_us", alive_us);
    check(cpu_us >= 150000, "getrusage counts the spin");
    check(cpu_us <= alive_us + 50000, "getrusage exceeds the process lifetime");
    check(ru.utime.usec >= 0 && ru.utime.usec < 1000000, "getrusage utime.usec range");

    struct rusage kids;
    check(syscall2(SYS_GETRUSAGE, (uint64_t)(int64_t)RUSAGE_CHILDREN, (uint64_t)&kids) == 0,
          "getrusage(CHILDREN)");
    check(syscall2(SYS_GETRUSAGE, 5, (uint64_t)&ru) == -EINVAL, "getrusage(5) EINVAL");
}

static void probe_spinner_progress(void) {
    const int64_t stack = syscall6(SYS_MMAP, 0, STACK_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (stack <= 0) { check(0, "spinner stack"); return; }
    const int64_t tid = syscall6(SYS_CLONE, CLONE_VM | CLONE_FILES | CLONE_THREAD,
                                 (uint64_t)(stack + STACK_SIZE - 16), 0, 0, 0, 0);
    if (tid == 0) spinner_main();
    if (tid < 0) { check(0, "spinner clone"); return; }

    for (int i = 0; i < 2000 && spinner_count == 0; i++) syscall1(SYS_SCHED_YIELD, 0);
    check(spinner_count != 0, "spinner started");

    const uint64_t before = spinner_count;
    const int64_t t0 = now_ns();
    const int64_t r = clock_sleep(CLOCK_MONOTONIC, 0, 0, 200 * NS_PER_MS, 0);
    const int64_t slept = now_ns() - t0;
    const uint64_t after = spinner_count;
    report("relative_slept_ms", slept / NS_PER_MS);
    check(r == 0, "relative clock_nanosleep returns 0");
    check(slept >= 190 * NS_PER_MS, "relative clock_nanosleep slept the full interval");
    check(after != before, "same-CPU spinner progressed during clock_nanosleep");

    stop_spinner = 1;
    for (int i = 0; i < 2000 && !spinner_done; i++) syscall1(SYS_SCHED_YIELD, 0);
    check(spinner_done, "spinner exited");
}

static void probe_abstime(void) {
    struct timespec rem = { 77, 77 };
    const int64_t target = now_ns() + 100 * NS_PER_MS;
    const int64_t r = clock_sleep(CLOCK_MONOTONIC, TIMER_ABSTIME, target / NS_PER_SEC, target % NS_PER_SEC, &rem);
    const int64_t late = now_ns() - target;
    check(r == 0, "TIMER_ABSTIME returns 0");
    check(late >= 0, "TIMER_ABSTIME woke before the deadline");
    check(rem.sec == 77 && rem.nsec == 77, "TIMER_ABSTIME leaves rem untouched");

    const int64_t t0 = now_ns();
    check(clock_sleep(CLOCK_MONOTONIC, TIMER_ABSTIME, 0, 1, 0) == 0, "past TIMER_ABSTIME returns 0");
    check(now_ns() - t0 < 50 * NS_PER_MS, "past TIMER_ABSTIME returns at once");
}

static void probe_invalid(void) {
    check(clock_sleep(99, 0, 0, 1000, 0) == -EINVAL, "unknown clock EINVAL");
    check(clock_sleep(CLOCK_MONOTONIC, 2, 0, 1000, 0) == -EINVAL, "unknown flags EINVAL");
    check(clock_sleep(CLOCK_MONOTONIC, 0, 0, NS_PER_SEC, 0) == -EINVAL, "clock_nanosleep nsec>=1e9 EINVAL");
    check(clock_sleep(CLOCK_MONOTONIC, 0, -1, 0, 0) == -EINVAL, "clock_nanosleep negative sec EINVAL");

    struct timespec big_nsec = { 0, NS_PER_SEC };
    check(syscall2(SYS_NANOSLEEP, (uint64_t)&big_nsec, 0) == -EINVAL, "nanosleep nsec>=1e9 EINVAL");
    struct timespec neg = { -1, 0 };
    check(syscall2(SYS_NANOSLEEP, (uint64_t)&neg, 0) == -EINVAL, "nanosleep negative sec EINVAL");
}

static void probe_alarm_interrupts(void) {
    struct timespec rem = { 0, 0 };
    alarm_seen = 0;
    syscall1(SYS_ALARM, 1);
    const int64_t t0 = now_ns();
    const int64_t r = clock_sleep(CLOCK_MONOTONIC, 0, 5, 0, &rem);
    const int64_t slept = now_ns() - t0;
    report("eintr_slept_ms", slept / NS_PER_MS);
    report("eintr_rem_s", rem.sec);
    check(r == -EINTR, "alarm interrupts clock_nanosleep with EINTR");
    check(alarm_seen, "SIGALRM handler ran");
    check(slept < 3 * NS_PER_SEC, "clock_nanosleep interrupted early");
    check(rem.sec >= 2 && rem.sec <= 4 && rem.nsec >= 0 && rem.nsec < NS_PER_SEC, "clock_nanosleep rem");
}

static void probe_huge_nanosleep(void) {
    struct timespec huge = { INT64_MAX, NS_PER_SEC - 1 };
    struct timespec rem = { 0, 0 };
    alarm_seen = 0;
    syscall1(SYS_ALARM, 1);
    const int64_t r = syscall2(SYS_NANOSLEEP, (uint64_t)&huge, (uint64_t)&rem);
    for (int i = 0; i < 200 && !alarm_seen; i++) syscall1(SYS_SCHED_YIELD, 0);
    check(r == -EINTR, "huge nanosleep is interrupted with EINTR");
    check(alarm_seen, "huge nanosleep SIGALRM handler ran");
    check(rem.sec > 1000000, "huge nanosleep rem stays huge");
}

void _start(void) {
    print("hello102: blocking clock_nanosleep / nanosleep validation / getrusage\n");
    const int64_t start = now_ns();
    syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&cpu0_mask);

    struct ksigaction sa = { on_alarm, 0, 0, 0 };
    check(syscall3(SYS_SIGACTION, SIGALRM, (uint64_t)&sa, 0) == 0, "sigaction(SIGALRM)");

    probe_getrusage(start);
    probe_spinner_progress();
    probe_abstime();
    probe_invalid();
    probe_alarm_interrupts();
    probe_huge_nanosleep();

    if (failures == 0) {
        print("hello102: PASS\n");
    } else {
        print("hello102: FAIL count=");
        print_dec(failures);
        print("\n");
    }
    print("hello102 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
