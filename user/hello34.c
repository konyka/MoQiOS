/// hello34: a refused copy must not consume the data it failed to deliver
///
/// The guards that run before an irreversible read — `validateUserBuffer` and
/// the checks inside read() — only asked whether the destination was mapped,
/// never whether it could be written. A read-only destination therefore passed,
/// the data was taken off the pipe (or socket, or timer), and only then did the
/// copy refuse it. The bytes were gone with nothing to show for them.
///
/// Writing to a pipe and closing the write end makes this observable without
/// risking a block: if the refused read consumed the payload, the following
/// good read sees EOF instead of the data.

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

#define SYS_WRITE 1
#define SYS_EXIT  2
#define SYS_MMAP  8
#define SYS_READ  10
#define SYS_CLOSE 11
#define SYS_PIPE  22

#define EFAULT 14

#define PROT_READ     0x1
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20
#define PAGE          4096

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

void _start(void) {
    print("hello34: refused copy must not eat the data\n");

    int failures = 0;

    int32_t fds[2] = { -1, -1 };
    if (syscall1(SYS_PIPE, (uint64_t)fds) < 0 || fds[0] < 0) {
        print("hello34: SKIP (no pipe)\n");
        print("hello34 done\n");
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }

    syscall3(SYS_WRITE, (uint64_t)fds[1], (uint64_t)"payload", 7);
    /// Closed so the good read below reports EOF rather than blocking if the
    /// payload was already consumed.
    syscall1(SYS_CLOSE, (uint64_t)fds[1]);

    const int64_t ro = syscall6(SYS_MMAP, 0, PAGE, PROT_READ,
                                MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (ro <= 0) {
        print("hello34: SKIP (no mmap)\n");
        print("hello34 done\n");
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }

    const int64_t refused = syscall3(SYS_READ, (uint64_t)fds[0], (uint64_t)ro, 7);
    print("hello34:   read(ro)=");
    print_dec(refused);
    print(refused < 0 ? " (rejected)\n" : " (accepted)\n");
    if (refused >= 0) {
        print("hello34:   FAIL — read into a read-only page reported success\n");
        failures++;
    }

    char good[8] = { 0 };
    const int64_t n = syscall3(SYS_READ, (uint64_t)fds[0], (uint64_t)good, 7);
    print("hello34:   read(ok)=");
    print_dec(n);
    print("\n");
    syscall1(SYS_CLOSE, (uint64_t)fds[0]);

    if (n != 7) {
        print("hello34:   FAIL — payload was consumed by the refused read\n");
        failures++;
    } else {
        const char *want = "payload";
        for (int i = 0; i < 7; i++) {
            if (good[i] != want[i]) { failures++; break; }
        }
    }

    print(failures == 0 ? "hello34: PASS (data survived the refused read)\n"
                        : "hello34: FAIL\n");
    print("hello34 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
