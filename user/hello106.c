/// hello106: console writes stay cheap once the framebuffer console scrolls.
///
/// The fbcon mirror used to scroll by moving the whole framebuffer up one
/// text row inside the serial write path, with IRQs off: ~4 MB of video
/// memory read back and rewritten per newline (~100 ms under QEMU), paid by
/// every kernel log line and every write(1). Scrolls now only mark a repaint
/// that the idle loop performs row by row.
///
/// The screen is already full when this runs, so every line below scrolls.
/// Each newline-terminated write(1) must stay far below one scroll's cost.

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

#define SYS_WRITE         1
#define SYS_EXIT          2
#define SYS_CLOCK_GETTIME 228

#define CLOCK_MONOTONIC 1
#define NS_PER_MS  1000000LL
#define NS_PER_SEC 1000000000LL

#define LINES             24
#define MAX_WRITE_NS      (20 * NS_PER_MS)
#define MEAN_WRITE_NS     (3 * NS_PER_MS)

struct timespec { int64_t sec; int64_t nsec; };

static int failures;

static int64_t write_str(const char *s) {
    int len = 0;
    while (s[len]) len++;
    return syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_dec(int64_t v) {
    char buf[24];
    int pos = 0;
    if (v < 0) { write_str("-"); v = -v; }
    if (v == 0) { write_str("0"); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char t = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = t; }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

static void fail(const char *what) {
    failures++;
    write_str("hello106: FAIL ");
    write_str(what);
    write_str("\n");
}

static int64_t now_ns(void) {
    struct timespec ts = { 0, 0 };
    syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (uint64_t)&ts);
    return ts.sec * NS_PER_SEC + ts.nsec;
}

void _start(void) {
    write_str("hello106: console write latency while the screen scrolls\n");

    char line[] = "hello106:   line 00 ...................................................\n";
    int64_t max_ns = 0, sum_ns = 0;
    for (int i = 0; i < LINES; i++) {
        line[17] = '0' + i / 10;
        line[18] = '0' + i % 10;
        const int64_t t0 = now_ns();
        const int64_t n = write_str(line);
        const int64_t dt = now_ns() - t0;
        if (n != (int64_t)(sizeof(line) - 1)) fail("short console write");
        if (dt > max_ns) max_ns = dt;
        sum_ns += dt;
    }
    const int64_t mean_ns = sum_ns / LINES;

    write_str("hello106:   write max_us=");
    print_dec(max_ns / 1000);
    write_str(" mean_us=");
    print_dec(mean_ns / 1000);
    write_str("\n");
    if (max_ns > MAX_WRITE_NS) fail("max console write latency");
    if (mean_ns > MEAN_WRITE_NS) fail("mean console write latency");

    write_str(failures == 0 ? "hello106: PASS\n" : "hello106: FAIL\n");
    write_str("hello106 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
