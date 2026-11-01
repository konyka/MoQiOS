/// hello170: process CPU time covers threads and waited-for children (getrusage, wait4, CLOCK_PROCESS_CPUTIME_ID).

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
#define SYS_MMAP      8
#define SYS_NANOSLEEP 35
#define SYS_FORK      57
#define SYS_GETRUSAGE 98
#define SYS_CLOCK_GETTIME 228
#define SYS_CLONE     243
#define SYS_WAIT4     263
#define CLOCK_MONOTONIC 1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define CLOCK_THREAD_CPUTIME_ID 3
#define RUSAGE_SELF 0
#define RUSAGE_CHILDREN (-1)
#define RUSAGE_THREAD 1
#define CLONE_VM     0x100
#define CLONE_FILES  0x400
#define CLONE_THREAD 0x10000
#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20
#define STACK_SIZE (16 * 4096)

struct ts { int64_t s, n; };
struct rusage { int64_t ut_s, ut_us, st_s, st_us; int64_t rest[14]; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello170:   ok   " : "hello170:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t now_ms(void) {
    struct ts t;
    syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static int64_t clock_ms(int clk) {
    struct ts t;
    syscall2(SYS_CLOCK_GETTIME, clk, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static int64_t ru_ms(int who) {
    struct rusage ru;
    for (int i = 0; i < 18; i++) ((int64_t *)&ru)[i] = 0;
    syscall2(SYS_GETRUSAGE, (uint64_t)(int64_t)who, (uint64_t)&ru);
    return (ru.ut_s + ru.st_s) * 1000 + (ru.ut_us + ru.st_us) / 1000;
}
static void spin_ms(int ms) {
    int64_t end = now_ms() + ms;
    while (now_ms() < end) {}
}

static volatile int thread_done;
static volatile int64_t thread_clk_before, thread_clk_after, thread_ru_before, thread_ru_after;
static __attribute__((noinline, noreturn)) void thread_main(void) {
    thread_clk_before = clock_ms(CLOCK_THREAD_CPUTIME_ID);
    thread_ru_before = ru_ms(RUSAGE_THREAD);
    spin_ms(250);
    thread_clk_after = clock_ms(CLOCK_THREAD_CPUTIME_ID);
    thread_ru_after = ru_ms(RUSAGE_THREAD);
    thread_done = 1;
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

void _start(void) {
    print("hello170: process CPU time\n");

    /* A: a waited-for child's time is reported by wait4 and accumulates in RUSAGE_CHILDREN */
    check(ru_ms(RUSAGE_CHILDREN) == 0, "A: RUSAGE_CHILDREN starts at zero");
    int64_t c = syscall1(SYS_FORK, 0);
    if (c == 0) {
        spin_ms(250);
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
    sleep_ms(500);
    check(ru_ms(RUSAGE_CHILDREN) == 0, "A: an exited child that has not been waited for is not counted yet");
    struct rusage cru;
    for (int i = 0; i < 18; i++) ((int64_t *)&cru)[i] = 0;
    int st = -1;
    int64_t self_before = ru_ms(RUSAGE_SELF);
    check(syscall4(SYS_WAIT4, (uint64_t)c, (uint64_t)&st, 0, (uint64_t)&cru) == c, "A: wait4 reaps the child");
    int64_t child_ms = (cru.ut_s + cru.st_s) * 1000 + (cru.ut_us + cru.st_us) / 1000;
    check(child_ms >= 180, "A: wait4 fills ru_utime/ru_stime with the child's CPU time (>= 180 ms)");
    int64_t kids = ru_ms(RUSAGE_CHILDREN);
    check(kids >= 180, "A: RUSAGE_CHILDREN now includes the waited-for child (>= 180 ms)");
    check(kids >= child_ms - 5 && kids <= child_ms + 50, "A: and matches what wait4 reported");
    /* Not an absolute bound: a task that sleeps while it is alone on its CPU is charged for the sleep. */
    check(ru_ms(RUSAGE_SELF) - self_before < 100, "A: reaping the child does not add its time to RUSAGE_SELF");

    /* B: a grandchild's time reaches the grandparent through the child's own waited children */
    int64_t before = ru_ms(RUSAGE_CHILDREN);
    c = syscall1(SYS_FORK, 0);
    if (c == 0) {
        int64_t g = syscall1(SYS_FORK, 0);
        if (g == 0) {
            spin_ms(250);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        int gs = 0;
        syscall4(SYS_WAIT4, (uint64_t)g, (uint64_t)&gs, 0, 0);
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
    for (int i = 0; i < 18; i++) ((int64_t *)&cru)[i] = 0;
    check(syscall4(SYS_WAIT4, (uint64_t)c, (uint64_t)&st, 0, (uint64_t)&cru) == c, "B: wait4 reaps the middle process");
    int64_t mid_ms = (cru.ut_s + cru.st_s) * 1000 + (cru.ut_us + cru.st_us) / 1000;
    check(mid_ms >= 180, "B: its rusage includes the grandchild it waited for (>= 180 ms)");
    check(ru_ms(RUSAGE_CHILDREN) - before >= 180, "B: RUSAGE_CHILDREN grows by the grandchild's time too");

    /* C: wait4 without a rusage buffer still works */
    c = syscall1(SYS_FORK, 0);
    if (c == 0) {
        syscall1(SYS_EXIT, 3);
        for (;;) {}
    }
    check(syscall4(SYS_WAIT4, (uint64_t)c, (uint64_t)&st, 0, 0) == c && ((st >> 8) & 0xff) == 3, "C: wait4 with a NULL rusage still reaps");

    /* D: the process clock covers every thread; the thread clock only the caller */
    int64_t stack = syscall6(SYS_MMAP, 0, STACK_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    check(stack > 0, "D: thread stack");
    if (stack > 0) {
        int64_t proc0 = clock_ms(CLOCK_PROCESS_CPUTIME_ID);
        int64_t self0 = ru_ms(RUSAGE_SELF);
        int64_t tid = syscall6(SYS_CLONE, CLONE_VM | CLONE_FILES | CLONE_THREAD, (uint64_t)(stack + STACK_SIZE - 16), 0, 0, 0, 0);
        if (tid == 0) thread_main();
        check(tid > 0, "D: clone(CLONE_THREAD)");
        while (!thread_done) sleep_ms(20);
        check(clock_ms(CLOCK_PROCESS_CPUTIME_ID) - proc0 >= 180, "D: CLOCK_PROCESS_CPUTIME_ID includes the thread's spin (>= 180 ms)");
        check(ru_ms(RUSAGE_SELF) - self0 >= 180, "D: getrusage(RUSAGE_SELF) includes the thread's spin (>= 180 ms)");
        /* Measured inside the new thread: it starts at zero (the process had already used 100+ ms)
         * and its own spin is all it accrues. */
        check(thread_clk_before < 50, "D: a new thread's CLOCK_THREAD_CPUTIME_ID starts near zero, not at the process total");
        check(thread_clk_after - thread_clk_before >= 180 && thread_clk_after - thread_clk_before <= 450, "D: and counts the thread's own 250 ms spin");
        check(thread_ru_before < 50, "D: RUSAGE_THREAD of a new thread starts near zero");
        check(thread_ru_after - thread_ru_before >= 180 && thread_ru_after - thread_ru_before <= 450, "D: and counts the thread's own spin");

        /* E: once the exited thread's slot is reclaimed its time is not lost */
        sleep_ms(300);
        check(clock_ms(CLOCK_PROCESS_CPUTIME_ID) - proc0 >= 180, "E: the process clock keeps the exited thread's time");
        check(ru_ms(RUSAGE_SELF) - self0 >= 180, "E: so does RUSAGE_SELF");
    }

    print(failures == 0 ? "hello170: PASS\n" : "hello170: FAIL\n");
    print("hello170 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
