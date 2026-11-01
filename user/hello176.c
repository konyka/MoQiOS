/// hello176: a task that sleeps is not charged CPU time for the sleep (thread clock, RUSAGE_THREAD).

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
#define SYS_MMAP      8
#define SYS_SCHED_YIELD 24
#define SYS_NANOSLEEP 35
#define SYS_GETRUSAGE 98
#define SYS_CLOCK_GETTIME 228
#define SYS_CLONE     243
#define SYS_SETAFFINITY 273
#define CLOCK_MONOTONIC 1
#define CLOCK_THREAD_CPUTIME_ID 3
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
static void print_num(const char *label, int64_t x) {
    char r[24]; int m = 0; char o[40]; int k = 0;
    print(label);
    if (x < 0) { o[k++] = '-'; x = -x; }
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k++] = '\n'; o[k] = 0;
    print(o);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello176:   ok   " : "hello176:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t now_ms(void) {
    struct ts t;
    syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static int64_t thread_ms(void) {
    struct ts t;
    syscall2(SYS_CLOCK_GETTIME, CLOCK_THREAD_CPUTIME_ID, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static int64_t ru_thread_ms(void) {
    struct rusage ru;
    for (int i = 0; i < 18; i++) ((int64_t *)&ru)[i] = 0;
    syscall2(SYS_GETRUSAGE, RUSAGE_THREAD, (uint64_t)&ru);
    return (ru.ut_s + ru.st_s) * 1000 + (ru.ut_us + ru.st_us) / 1000;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static volatile int stop_spin, spin_started;
static __attribute__((noinline, noreturn)) void spin_main(void) {
    spin_started = 1;
    while (!stop_spin) {}
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

/* Sleep for `total` ms in `step` ms naps; return the thread CPU time charged meanwhile. */
static int64_t charged_while_sleeping(int total, int step) {
    int64_t c0 = thread_ms(), r0 = ru_thread_ms();
    int64_t t0 = now_ms();
    while (now_ms() - t0 < total) sleep_ms(step);
    int64_t c = thread_ms() - c0, r = ru_thread_ms() - r0;
    return c > r ? c : r;
}

void _start(void) {
    print("hello176: sleeping is not CPU time\n");
    int64_t a = charged_while_sleeping(300, 300);
    print_num("hello176: one 300 ms nap, charged ms: ", a);
    int64_t b = charged_while_sleeping(300, 20);
    print_num("hello176: 20 ms naps for 300 ms, charged ms: ", b);
    int64_t c = charged_while_sleeping(300, 1);
    print_num("hello176: 1 ms naps for 300 ms, charged ms: ", c);

    int64_t stack = syscall6(SYS_MMAP, 0, STACK_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    int64_t d = -1;
    if (stack > 0) {
        int64_t tid = syscall6(SYS_CLONE, CLONE_VM | CLONE_FILES | CLONE_THREAD, (uint64_t)(stack + STACK_SIZE - 16), 0, 0, 0, 0);
        if (tid == 0) spin_main();
        while (!spin_started) sleep_ms(5);
        d = charged_while_sleeping(300, 20);
        print_num("hello176: 20 ms naps with an unpinned spinner, charged ms: ", d);
        stop_spin = 1;
    }
    check(a < 60, "A: one long nap is charged almost nothing");
    check(b < 60, "B: repeated 20 ms naps are charged almost nothing");
    check(c < 150, "C: repeated 1 ms naps are charged little");
    check(d >= 0 && d < 60, "D: naps are not charged while another thread spins elsewhere");
    print(failures == 0 ? "hello176: PASS\n" : "hello176: FAIL\n");
    print("hello176 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
