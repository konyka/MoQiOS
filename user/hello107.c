/// hello107: kernel lock contention stress (fair ticket spinlocks).
///
/// The main task and one CLONE_VM thread hammer the most contended kernel
/// locks at the same time for a fixed window: the shared mm's vm_lock
/// (mmap / page fault / mprotect / munmap), the TLB shootdown lock (munmap
/// of a page the sibling CPU may cache), the futex bucket locks and the run
/// queue locks (sched_yield). With SMP >= 2 the two threads are pinned to
/// different CPUs so every lock really is contended cross-CPU.
///
/// Checks:
///   * every page reads back the pattern its own thread wrote (no lost or
///     torn mapping update under contention);
///   * both threads make comparable progress (a fair lock never starves one
///     side: min/max iteration ratio >= 1/4);
///   * with SMP >= 2, no single iteration takes longer than MAX_ITER_NS
///     (bounded lock waiting — no unbounded spin starvation).

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

#define SYS_WRITE         1
#define SYS_EXIT          2
#define SYS_MMAP          8
#define SYS_MUNMAP        12
#define SYS_SCHED_YIELD   24
#define SYS_FUTEX         143
#define SYS_MPROTECT      164
#define SYS_CLOCK_GETTIME 228
#define SYS_CLONE         243
#define SYS_SETAFFINITY   273

#define CLOCK_MONOTONIC 1
#define FUTEX_WAKE_PRIVATE (1 | 128)

#define CLONE_VM     0x100
#define CLONE_FILES  0x400
#define CLONE_THREAD 0x10000

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define PAGE       4096
#define STACK_SIZE (16 * 4096)
#define NS_PER_MS  1000000LL
#define NS_PER_SEC 1000000000LL

#define WINDOW_NS   (400 * NS_PER_MS)
#define MAX_ITER_NS (30 * NS_PER_MS)

struct timespec { int64_t sec; int64_t nsec; };

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

static int64_t now_ns(void) {
    struct timespec ts = { 0, 0 };
    syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (uint64_t)&ts);
    return ts.sec * NS_PER_SEC + ts.nsec;
}

struct worker {
    int64_t iters;
    int64_t max_iter_ns;
    int failed;
    int done;
};

static struct worker workers[2];
static volatile int start_flag;
static volatile int64_t window_end;
static volatile int32_t futex_word;
static uint64_t cpu_mask[2] = { 1, 2 };

static void hammer(struct worker *w, uint64_t tag) {
    while (!start_flag) {}
    int64_t prev = now_ns();
    while (prev < window_end) {
        const int64_t p = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (p <= 0) { w->failed = 1; break; }
        volatile uint64_t *word = (volatile uint64_t *)p;
        const uint64_t pattern = (tag << 56) ^ (uint64_t)w->iters;
        word[0] = pattern;
        word[PAGE / 8 - 1] = ~pattern;
        if (syscall3(SYS_MPROTECT, (uint64_t)p, PAGE, PROT_READ) != 0) { w->failed = 2; break; }
        if (word[0] != pattern || word[PAGE / 8 - 1] != ~pattern) { w->failed = 3; break; }
        if (syscall2(SYS_MUNMAP, (uint64_t)p, PAGE) != 0) { w->failed = 4; break; }
        syscall6(SYS_FUTEX, (uint64_t)&futex_word, FUTEX_WAKE_PRIVATE, 1, 0, 0, 0);
        if ((w->iters & 7) == 0) syscall1(SYS_SCHED_YIELD, 0);
        w->iters++;
        const int64_t t = now_ns();
        if (t - prev > w->max_iter_ns) w->max_iter_ns = t - prev;
        prev = t;
    }
    w->done = 1;
}

static volatile int smp_pinned;

/// Runs on the clone stack: touches globals only, never returns.
static __attribute__((noinline, noreturn)) void thread_main(void) {
    if (syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&cpu_mask[1]) == 0) smp_pinned = 1;
    else smp_pinned = -1;
    hammer(&workers[1], 2);
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

void _start(void) {
    print("hello107: cross-CPU kernel lock contention stays fair and bounded\n");
    int failures = 0;
    syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&cpu_mask[0]);

    const int64_t stack = syscall6(SYS_MMAP, 0, STACK_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (stack <= 0) { print("hello107: FAIL stack\nhello107 done\n"); syscall1(SYS_EXIT, 1); }
    const int64_t tid = syscall6(SYS_CLONE, CLONE_VM | CLONE_FILES | CLONE_THREAD,
                                 (uint64_t)(stack + STACK_SIZE - 16), 0, 0, 0, 0);
    if (tid == 0) thread_main();
    if (tid < 0) { print("hello107: FAIL clone\nhello107 done\n"); syscall1(SYS_EXIT, 1); }

    for (int i = 0; i < 100000 && smp_pinned == 0; i++) syscall1(SYS_SCHED_YIELD, 0);
    const int smp = smp_pinned == 1;
    window_end = now_ns() + WINDOW_NS;
    start_flag = 1;
    hammer(&workers[0], 1);
    for (int i = 0; i < 1000000 && !workers[1].done; i++) syscall1(SYS_SCHED_YIELD, 0);

    for (int i = 0; i < 2; i++) {
        print("hello107:   thread ");
        print_dec(i);
        print(" iters=");
        print_dec(workers[i].iters);
        print(" max_iter_us=");
        print_dec(workers[i].max_iter_ns / 1000);
        print("\n");
        if (workers[i].failed) {
            print("hello107: FAIL thread ");
            print_dec(i);
            print(" step ");
            print_dec(workers[i].failed);
            print("\n");
            failures++;
        }
    }
    if (!workers[1].done) { print("hello107: FAIL sibling did not finish\n"); failures++; }

    const int64_t a = workers[0].iters, b = workers[1].iters;
    const int64_t lo = a < b ? a : b, hi = a < b ? b : a;
    if (lo == 0 || lo * 4 < hi) { print("hello107: FAIL starvation (unfair progress)\n"); failures++; }
    if (smp) {
        for (int i = 0; i < 2; i++) {
            if (workers[i].max_iter_ns > MAX_ITER_NS) {
                print("hello107: FAIL unbounded iteration latency\n");
                failures++;
                break;
            }
        }
    } else {
        print("hello107:   single CPU: latency bound not applicable\n");
    }

    print(failures == 0 ? "hello107: PASS\n" : "hello107: FAIL\n");
    print("hello107 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
