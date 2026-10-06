/// hello104: wakeup preemption for a realtime thread on the same CPU.
///
/// A SCHED_FIFO thread blocked in FUTEX_WAIT is woken by a SCHED_OTHER thread
/// pinned to the same CPU, which then keeps computing without blocking.
/// Without wakeup preemption the woken FIFO thread only ran once the waker's
/// timeslice ran out (up to TIMESLICE_TICKS ≈ 100 ms later). With it, the
/// wake raises a reschedule on the waker's own CPU and the FIFO thread runs
/// as soon as the wake syscall returns.
///
/// Each round measures wake → first instruction of the woken thread.

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

#define SYS_WRITE              1
#define SYS_EXIT               2
#define SYS_MMAP               8
#define SYS_SCHED_YIELD        24
#define SYS_FUTEX              143
#define SYS_CLOCK_GETTIME      228
#define SYS_CLONE              243
#define SYS_SETAFFINITY        273
#define SYS_SCHED_SETSCHEDULER 473

#define CLOCK_MONOTONIC 1
#define SCHED_FIFO      1

#define FUTEX_WAIT_PRIVATE (0 | 128)
#define FUTEX_WAKE_PRIVATE (1 | 128)
#define EAGAIN 11
#define EINTR  4

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

#define ROUNDS          8
#define WAKE_SPIN_NS    (200 * NS_PER_MS)
#define MAX_LATENCY_NS  (20 * NS_PER_MS)
#define MEAN_LATENCY_NS (5 * NS_PER_MS)

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

static uint64_t cpu0_mask = 1;
static volatile int32_t seq;
static volatile int rt_armed;   /* round the RT thread is about to wait for */
static volatile int rt_ready;   /* RT thread became SCHED_FIFO and pinned */
static volatile int rt_failed;
static volatile int rt_done;
static volatile int64_t woke_at[ROUNDS];

/// Runs on the clone stack: touches globals only, never returns.
static __attribute__((noinline, noreturn)) void rt_main(void) {
    int32_t param = 50;
    syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&cpu0_mask);
    if (syscall3(SYS_SCHED_SETSCHEDULER, 0, SCHED_FIFO, (uint64_t)&param) != 0) rt_failed = 1;
    syscall1(SYS_SCHED_YIELD, 0);
    rt_ready = 1;
    for (int r = 0; r < ROUNDS && !rt_failed; r++) {
        rt_armed = r + 1;
        while (seq == r) {
            const int64_t w = syscall6(SYS_FUTEX, (uint64_t)&seq, FUTEX_WAIT_PRIVATE, (uint64_t)r, 0, 0, 0);
            if (w != 0 && w != -EAGAIN && w != -EINTR) { rt_failed = 2; break; }
        }
        woke_at[r] = now_ns();
    }
    rt_done = 1;
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

void _start(void) {
    print("hello104: SCHED_FIFO wakeup preemption on the waker's CPU\n");
    int failures = 0;
    syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&cpu0_mask);

    const int64_t stack = syscall6(SYS_MMAP, 0, STACK_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (stack <= 0) { print("hello104: FAIL stack\nhello104 done\n"); syscall1(SYS_EXIT, 1); }
    const int64_t tid = syscall6(SYS_CLONE, CLONE_VM | CLONE_FILES | CLONE_THREAD,
                                 (uint64_t)(stack + STACK_SIZE - 16), 0, 0, 0, 0);
    if (tid == 0) rt_main();
    if (tid < 0) { print("hello104: FAIL clone\nhello104 done\n"); syscall1(SYS_EXIT, 1); }

    for (int i = 0; i < 100000 && !rt_ready && !rt_failed; i++) syscall1(SYS_SCHED_YIELD, 0);
    if (!rt_ready || rt_failed) {
        print("hello104: FAIL rt thread setup\nhello104 done\n");
        syscall1(SYS_EXIT, 1);
    }

    int64_t max_lat = 0, sum_lat = 0;
    for (int r = 0; r < ROUNDS; r++) {
        /* The FIFO thread outranks us on this CPU, so once we run again it is
         * blocked in FUTEX_WAIT for round r. */
        for (int i = 0; i < 100000 && rt_armed != r + 1; i++) syscall1(SYS_SCHED_YIELD, 0);
        const int64_t settle = now_ns() + 3 * NS_PER_MS * (r + 1);
        while (now_ns() < settle) {}

        const int64_t t0 = now_ns();
        seq = r + 1;
        syscall6(SYS_FUTEX, (uint64_t)&seq, FUTEX_WAKE_PRIVATE, 1, 0, 0, 0);
        /* Keep the CPU busy without blocking or yielding: only preemption
         * can hand it to the woken thread. */
        while (woke_at[r] == 0 && now_ns() - t0 < WAKE_SPIN_NS) {}
        const int64_t lat = woke_at[r] == 0 ? WAKE_SPIN_NS : woke_at[r] - t0;
        if (lat > max_lat) max_lat = lat;
        sum_lat += lat;
        print("hello104:   round ");
        print_dec(r);
        print(" latency_us=");
        print_dec(lat / 1000);
        print("\n");
    }

    for (int i = 0; i < 100000 && !rt_done; i++) syscall1(SYS_SCHED_YIELD, 0);
    if (rt_failed) { print("hello104: FAIL rt thread futex\n"); failures++; }
    if (!rt_done) { print("hello104: FAIL rt thread did not finish\n"); failures++; }

    const int64_t mean_lat = sum_lat / ROUNDS;
    print("hello104:   max_us=");
    print_dec(max_lat / 1000);
    print(" mean_us=");
    print_dec(mean_lat / 1000);
    print("\n");
    if (max_lat > MAX_LATENCY_NS) { print("hello104: FAIL max wake latency\n"); failures++; }
    if (mean_lat > MEAN_LATENCY_NS) { print("hello104: FAIL mean wake latency\n"); failures++; }

    print(failures == 0 ? "hello104: PASS\n" : "hello104: FAIL\n");
    print("hello104 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
