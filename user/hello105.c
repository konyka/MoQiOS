/// hello105: timed waits expire on the next tick, not the next 100 ms pass.
///
/// futex/epoll/timerfd/POSIX timer/alarm deadlines used to be checked only in
/// the BSP maintenance pass that runs every REAP_INTERVAL ticks (~100 ms), so
/// a 20 ms timeout returned anywhere between 20 and ~120 ms. They are now
/// checked on every hardware tick (~10 ms).
///
/// For a FUTEX_WAIT timeout and an epoll_wait timeout this samples the
/// overshoot past the requested 20 ms at varying tick phases and requires a
/// small mean and a bounded maximum. No sample may return early.

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

#define SYS_WRITE         1
#define SYS_EXIT          2
#define SYS_CLOSE         11
#define SYS_NANOSLEEP     35
#define SYS_FUTEX         143
#define SYS_EPOLL_CREATE1 146
#define SYS_EPOLL_WAIT    148
#define SYS_CLOCK_GETTIME 228

#define CLOCK_MONOTONIC 1
#define FUTEX_WAIT_PRIVATE (0 | 128)
#define ETIMEDOUT 110

#define NS_PER_MS  1000000LL
#define NS_PER_SEC 1000000000LL

#define SAMPLES          8
#define TIMEOUT_MS       20
#define MAX_OVERSHOOT_NS (60 * NS_PER_MS)
#define MEAN_OVERSHOOT_NS (25 * NS_PER_MS)

struct timespec { int64_t sec; int64_t nsec; };
struct epoll_event { uint32_t events; uint64_t data; } __attribute__((packed));

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

static void fail(const char *what) {
    failures++;
    print("hello105: FAIL ");
    print(what);
    print("\n");
}

static int64_t now_ns(void) {
    struct timespec ts = { 0, 0 };
    syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (uint64_t)&ts);
    return ts.sec * NS_PER_SEC + ts.nsec;
}

/// Shift the next sample to a different phase of the tick and of the old
/// 100 ms maintenance cadence.
static void shift_phase(int i) {
    struct timespec ts = { 0, (7 + 13 * i) % 50 * NS_PER_MS + 1 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&ts, 0);
}

static volatile int32_t never_woken;

static int64_t futex_sample(void) {
    struct timespec rel = { 0, TIMEOUT_MS * NS_PER_MS };
    const int64_t t0 = now_ns();
    const int64_t r = syscall4(SYS_FUTEX, (uint64_t)&never_woken, FUTEX_WAIT_PRIVATE, 0, (uint64_t)&rel);
    const int64_t elapsed = now_ns() - t0;
    if (r != -ETIMEDOUT) fail("futex timed wait did not time out");
    return elapsed;
}

static int64_t epoll_sample(int64_t epfd) {
    struct epoll_event ev[1];
    const int64_t t0 = now_ns();
    const int64_t r = syscall4(SYS_EPOLL_WAIT, (uint64_t)epfd, (uint64_t)ev, 1, TIMEOUT_MS);
    const int64_t elapsed = now_ns() - t0;
    if (r != 0) fail("epoll_wait on an empty set did not time out");
    return elapsed;
}

static void judge(const char *name, const int64_t *elapsed) {
    int64_t max_over = 0, sum_over = 0;
    for (int i = 0; i < SAMPLES; i++) {
        const int64_t over = elapsed[i] - TIMEOUT_MS * NS_PER_MS;
        if (over < -NS_PER_MS) fail("timed wait returned early");
        const int64_t clamped = over < 0 ? 0 : over;
        if (clamped > max_over) max_over = clamped;
        sum_over += clamped;
    }
    const int64_t mean_over = sum_over / SAMPLES;
    print("hello105:   ");
    print(name);
    print(" overshoot max_us=");
    print_dec(max_over / 1000);
    print(" mean_us=");
    print_dec(mean_over / 1000);
    print("\n");
    if (max_over > MAX_OVERSHOOT_NS) fail("max timeout overshoot");
    if (mean_over > MEAN_OVERSHOOT_NS) fail("mean timeout overshoot");
}

void _start(void) {
    print("hello105: timed-wait expiry precision\n");
    int64_t elapsed[SAMPLES];

    for (int i = 0; i < SAMPLES; i++) {
        shift_phase(i);
        elapsed[i] = futex_sample();
    }
    judge("futex", elapsed);

    const int64_t epfd = syscall1(SYS_EPOLL_CREATE1, 0);
    if (epfd < 0) {
        fail("epoll_create1");
    } else {
        for (int i = 0; i < SAMPLES; i++) {
            shift_phase(i);
            elapsed[i] = epoll_sample(epfd);
        }
        judge("epoll", elapsed);
        syscall1(SYS_CLOSE, (uint64_t)epfd);
    }

    print(failures == 0 ? "hello105: PASS\n" : "hello105: FAIL\n");
    print("hello105 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
