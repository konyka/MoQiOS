/// hello108: reaping a dead process never steals the CPU from an RT task.
///
/// Orphaned zombies used to be torn down (page tables, every user page,
/// kernel stack) inside the BSP timer interrupt, under the global task lock,
/// with IRQs off — several milliseconds during which no task on the BSP
/// could run, whatever its priority.
///
/// Setup: a middle child forks NCHILD grandchildren that each touch
/// CHILD_BYTES of anonymous memory, report "ready" and wait on a release
/// pipe; the middle child exits at once, so the grandchildren are orphans.
/// Releasing them together makes them exit within a moment of each other,
/// so one maintenance pass finds them all; the "ready" pipe reaches EOF once
/// all of them have closed their descriptors in exit.
///
/// Measurement: the main task, pinned to CPU 0 (the BSP, where orphan
/// reaping runs) and running SCHED_FIFO, spins reading the clock — once
/// before the release (baseline) and for WINDOW_NS after it. The largest gap
/// between two reads is time the CPU was taken from the highest-priority
/// task. Afterwards the freed memory must come back (the zombies really are
/// reaped, just not at the RT task's expense).
///
/// Thread phase: NTHREADS CLONE_THREAD threads are created and joined one
/// after another. Dead non-leader threads used to stay zombies until the
/// whole group exited (waitpid skips threads, the orphan scan skipped any
/// zombie with a living parent), so the 64-entry task table ran out.

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
#define SYS_WAITPID            6
#define SYS_MMAP               8
#define SYS_READ               10
#define SYS_CLOSE              11
#define SYS_PIPE               22
#define SYS_SCHED_YIELD        24
#define SYS_NANOSLEEP          35
#define SYS_FORK               57
#define SYS_SYSINFO            99
#define SYS_CLOCK_GETTIME      228
#define SYS_CLONE              243
#define SYS_SETAFFINITY        273
#define SYS_SCHED_SETSCHEDULER 473

#define CLOCK_MONOTONIC 1
#define SCHED_OTHER     0
#define SCHED_FIFO      1

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define CLONE_VM     0x100
#define CLONE_FILES  0x400
#define CLONE_THREAD 0x10000

#define PAGE        4096
#define NTHREADS    100
#define TSTACK      (4 * 4096)
#define NCHILD      8
#define CHILD_BYTES (16 * 1024 * 1024)
#define NS_PER_MS   1000000LL
#define NS_PER_SEC  1000000000LL
#define BASE_NS     (200 * NS_PER_MS)
#define WINDOW_NS   (400 * NS_PER_MS)
#define MAX_GAP_NS  (4 * NS_PER_MS)
#define STOLEN_MIN_NS (1 * NS_PER_MS)
#define MAX_STOLEN_NS (4 * NS_PER_MS)

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

static uint64_t sinfo_buf[16];

static uint64_t freeram_pages(void) {
    for (int i = 0; i < 16; i++) sinfo_buf[i] = 0;
    syscall1(SYS_SYSINFO, (uint64_t)sinfo_buf);
    return sinfo_buf[5] / PAGE;
}

static volatile int thread_done;

static __attribute__((noinline, noreturn)) void thread_main(void) {
    thread_done = 1;
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

static void sleep_ms(int64_t ms) {
    struct timespec ts = { 0, ms * NS_PER_MS };
    syscall2(SYS_NANOSLEEP, (uint64_t)&ts, 0);
}

/// Create and join NTHREADS threads sequentially; returns how many ran.
static int thread_phase(void) {
    int created = 0;
    for (int i = 0; i < NTHREADS; i++) {
        const int64_t stack = syscall6(SYS_MMAP, 0, TSTACK, PROT_READ | PROT_WRITE,
                                       MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (stack <= 0) break;
        thread_done = 0;
        int64_t tid = -1;
        /* A just-exited thread's slot is freed by the next reap pass. */
        for (int tries = 0; tries < 100; tries++) {
            tid = syscall6(SYS_CLONE, CLONE_VM | CLONE_FILES | CLONE_THREAD,
                           (uint64_t)(stack + TSTACK - 16), 0, 0, 0, 0);
            if (tid >= 0) break;
            sleep_ms(10);
        }
        if (tid == 0) thread_main();
        if (tid < 0) break;
        while (!thread_done) syscall1(SYS_SCHED_YIELD, 0);
        created++;
    }
    return created;
}

static int32_t ready_fds[2] = { -1, -1 };
static int32_t go_fds[2] = { -1, -1 };

static void grandchild(void) {
    const int64_t p = syscall6(SYS_MMAP, 0, CHILD_BYTES, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (p > 0) {
        for (uint64_t off = 0; off < CHILD_BYTES; off += PAGE) *(volatile uint8_t *)(p + off) = 1;
    }
    char b = 'r';
    syscall3(SYS_WRITE, (uint64_t)ready_fds[1], (uint64_t)&b, 1);
    syscall3(SYS_READ, (uint64_t)go_fds[0], (uint64_t)&b, 1);
    syscall1(SYS_EXIT, 0);
}

struct gaps { int64_t max; int64_t stolen; };

/// Spin for `ns`: the largest gap between two clock reads, and the total
/// time lost in gaps of at least STOLEN_MIN_NS (reaping split over several
/// maintenance passes shows up there even when each piece is short).
static struct gaps spin_gaps(int64_t ns) {
    struct gaps g = { 0, 0 };
    const int64_t start = now_ns();
    int64_t prev = start;
    while (prev - start < ns) {
        const int64_t t = now_ns();
        const int64_t d = t - prev;
        if (d > g.max) g.max = d;
        if (d >= STOLEN_MIN_NS) g.stolen += d;
        prev = t;
    }
    return g;
}

void _start(void) {
    print("hello108: orphan reaping does not preempt a SCHED_FIFO task on the BSP\n");
    int failures = 0;
    uint64_t cpu0 = 1;
    syscall3(SYS_SETAFFINITY, 0, 8, (uint64_t)&cpu0);

    const uint64_t free_before = freeram_pages();
    if (syscall1(SYS_PIPE, (uint64_t)ready_fds) != 0 || syscall1(SYS_PIPE, (uint64_t)go_fds) != 0) {
        print("hello108: FAIL pipe\nhello108 done\n");
        syscall1(SYS_EXIT, 1);
    }

    const int64_t middle = syscall1(SYS_FORK, 0);
    if (middle == 0) {
        syscall1(SYS_CLOSE, (uint64_t)ready_fds[0]);
        syscall1(SYS_CLOSE, (uint64_t)go_fds[1]);
        for (int i = 0; i < NCHILD; i++) {
            if (syscall1(SYS_FORK, 0) == 0) grandchild();
        }
        syscall1(SYS_EXIT, 0); /* grandchildren become orphans */
    }
    if (middle < 0) { print("hello108: FAIL fork\nhello108 done\n"); syscall1(SYS_EXIT, 1); }
    syscall1(SYS_CLOSE, (uint64_t)ready_fds[1]);
    syscall1(SYS_CLOSE, (uint64_t)go_fds[0]);
    int32_t status = 0;
    syscall2(SYS_WAITPID, (uint64_t)middle, (uint64_t)&status);

    char byte;
    for (int got = 0; got < NCHILD;) {
        if (syscall3(SYS_READ, (uint64_t)ready_fds[0], (uint64_t)&byte, 1) <= 0) break;
        got++;
    }

    int32_t param = 50;
    if (syscall3(SYS_SCHED_SETSCHEDULER, 0, SCHED_FIFO, (uint64_t)&param) != 0) {
        print("hello108: FAIL sched_setscheduler\nhello108 done\n");
        syscall1(SYS_EXIT, 1);
    }
    const struct gaps base = spin_gaps(BASE_NS);
    /* Release every grandchild at once; EOF once all have closed their fds. */
    for (int i = 0; i < NCHILD; i++) syscall3(SYS_WRITE, (uint64_t)go_fds[1], (uint64_t)"g", 1);
    syscall1(SYS_CLOSE, (uint64_t)go_fds[1]);
    while (syscall3(SYS_READ, (uint64_t)ready_fds[0], (uint64_t)&byte, 1) > 0) {}
    syscall1(SYS_CLOSE, (uint64_t)ready_fds[0]);
    const struct gaps win = spin_gaps(WINDOW_NS);
    param = 0;
    syscall3(SYS_SCHED_SETSCHEDULER, 0, SCHED_OTHER, (uint64_t)&param);

    print("hello108:   baseline max_gap_us=");
    print_dec(base.max / 1000);
    print(" stolen_us=");
    print_dec(base.stolen / 1000);
    print("\n");
    print("hello108:   reaping  max_gap_us=");
    print_dec(win.max / 1000);
    print(" stolen_us=");
    print_dec(win.stolen / 1000);
    print("\n");
    if (win.max > MAX_GAP_NS || win.stolen > MAX_STOLEN_NS) {
        print("hello108: FAIL RT task lost the CPU to reaping\n");
        failures++;
    }

    /* The orphans must still be reaped promptly once the CPU is free. */
    const uint64_t need = free_before - (CHILD_BYTES / PAGE) / 2;
    uint64_t free_after = freeram_pages();
    const int64_t deadline = now_ns() + 2 * NS_PER_SEC;
    while (free_after < need && now_ns() < deadline) {
        syscall1(SYS_SCHED_YIELD, 0);
        free_after = freeram_pages();
    }
    print("hello108:   free_pages_before=");
    print_dec((int64_t)free_before);
    print(" after=");
    print_dec((int64_t)free_after);
    print("\n");
    if (free_after < need) { print("hello108: FAIL orphan memory not reclaimed\n"); failures++; }

    const int threads = thread_phase();
    print("hello108:   sequential threads created=");
    print_dec(threads);
    print("\n");
    if (threads != NTHREADS) { print("hello108: FAIL dead threads leak task slots\n"); failures++; }

    print(failures == 0 ? "hello108: PASS\n" : "hello108: FAIL\n");
    print("hello108 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
