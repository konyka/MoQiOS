/// hello47: /dev/kmsg kernel log ring (G4).
///
/// (a) opening /dev/kmsg read-only succeeds and reading starts at the
///     oldest available byte of the kernel log ring;
/// (b) the accumulated output contains boot-time klog lines: the "[INF] "
///     level prefix and the "=== MoQiOS scheduler active ===" banner that
///     kernel/main.zig logs right before userspace starts;
/// (c) a second open gets an independent cursor (per-fd offset semantics):
///     its first bytes match the first bytes of the first open;
/// (d) write() on /dev/kmsg fails (read-only).

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_EXIT  2
#define SYS_OPEN  9
#define SYS_READ  10
#define SYS_CLOSE 11

#define O_RDONLY 0
#define O_NONBLOCK 0x800
#define O_WRONLY 1

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello47: FAIL (");
    print(why);
    print(")\nhello47 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static int contains(const char *hay, uint64_t hay_len, const char *needle) {
    uint64_t nl = 0;
    while (needle[nl]) nl++;
    if (nl == 0 || hay_len < nl) return 0;
    for (uint64_t i = 0; i + nl <= hay_len; i++) {
        uint64_t j = 0;
        while (j < nl && hay[i + j] == needle[j]) j++;
        if (j == nl) return 1;
    }
    return 0;
}

static char log_buf[80 * 1024];

void _start(void) {
    /* (a) open + drain the ring from the oldest available byte. */
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/dev/kmsg", O_RDONLY | O_NONBLOCK, 0);
    if (fd < 0) fail("open /dev/kmsg");

    uint64_t total = 0;
    for (;;) {
        int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)(log_buf + total),
                             (uint64_t)(sizeof(log_buf) - total));
        if (n < 0) fail("read /dev/kmsg");
        if (n == 0) break; /* EOF at the newest byte */
        total += (uint64_t)n;
        if (total >= sizeof(log_buf)) break;
    }
    if (total == 0) fail("kmsg ring is empty");

    /* (b) boot-time lines must be present. */
    if (!contains(log_buf, total, "[INF] ")) fail("no [INF] level prefix in kmsg");
    if (!contains(log_buf, total, "=== MoQiOS scheduler active ==="))
        fail("boot banner missing from kmsg");

    /* (c) second open: independent cursor starting at the oldest byte. */
    {
        int64_t fd2 = syscall3(SYS_OPEN, (uint64_t)"/dev/kmsg", O_RDONLY | O_NONBLOCK, 0);
        if (fd2 < 0) fail("reopen /dev/kmsg");
        char first2[64];
        int64_t n2 = syscall3(SYS_READ, (uint64_t)fd2, (uint64_t)first2, sizeof(first2));
        if (n2 <= 0) fail("second open read");
        if ((uint64_t)n2 > total) fail("second open longer than first");
        for (int64_t i = 0; i < n2; i++)
            if (first2[i] != log_buf[i]) fail("second open cursor not at oldest byte");
        syscall1(SYS_CLOSE, (uint64_t)fd2);
    }

    /* (d) read-only. */
    if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"x", 1) >= 0)
        fail("write to /dev/kmsg succeeded");

    syscall1(SYS_CLOSE, (uint64_t)fd);
    print("hello47: PASS\nhello47 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
