// hello94 - timerfd acceptance: timerfd_create returns a real fd-table fd
// (dup-able, poll/close-able), settime/gettime resolve the fd, nonblocking
// read before expiry is EAGAIN, and read after expiry returns expirations.
#include <stdint.h>

static inline int64_t syscall1(uint64_t n, uint64_t a) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall2(uint64_t n, uint64_t a, uint64_t b) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall3(uint64_t n, uint64_t a, uint64_t b, uint64_t c) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "r"(x) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall4(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    register uint64_t y __asm__("r10") = d;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "r"(x), "r"(y) : "rcx", "r11", "memory");
    return r;
}

#define SYS_READ 10
#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_CLOSE 11
#define SYS_DUP 32
#define SYS_TIMERFD_CREATE 170
#define SYS_TIMERFD_SETTIME 171
#define SYS_TIMERFD_GETTIME 172
#define SYS_NANOSLEEP 199

#define CLOCK_MONOTONIC 1
#define TFD_NONBLOCK 0x800
#define EAGAIN 11
#define EBADF 9
#define EINVAL 22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello94: FAIL ");
        print(name);
        print("\n");
        return 1;
    }
    return 0;
}

__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(SYS_EXIT, (uint64_t)status);
    for (;;) {}
}

static void sleep_ms(uint64_t ms) {
    uint64_t req[2] = { (uint64_t)(ms / 1000), (uint64_t)((ms % 1000) * 1000 * 1000) };
    syscall2(SYS_NANOSLEEP, (uint64_t)req, 0);
}

void _start(void) {
    int failures = 0;
    uint64_t val = 0;
    /* itimerspec: { it_interval { sec, nsec }, it_value { sec, nsec } } */
    int64_t spec[4] = { 0, 0, 0, 100 * 1000 * 1000 }; /* one-shot, 100ms */
    int64_t cur[4] = { 0, 0, 0, 0 };
    print("hello94: start\n");

    failures += check(syscall2(SYS_TIMERFD_CREATE, 99, 0) == -EINVAL,
                      "invalid clock_id rejected");
    failures += check(syscall2(SYS_TIMERFD_CREATE, CLOCK_MONOTONIC, 0x1000) == -EINVAL,
                      "unknown timerfd flags rejected");

    int64_t fd = syscall2(SYS_TIMERFD_CREATE, CLOCK_MONOTONIC, TFD_NONBLOCK);
    failures += check(fd >= 3, "timerfd_create returns a real fd");

    /* Real-fd-ness: dup copies a fd-table entry (a raw pool index could not). */
    int64_t dupfd = syscall1(SYS_DUP, (uint64_t)fd);
    failures += check(dupfd > fd, "dup works on the timerfd fd");

    /* Nonblocking read before arming / before expiry → EAGAIN. */
    failures += check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&val, 8) == -EAGAIN,
                      "nonblocking read before expiry is EAGAIN");

    /* settime/gettime take the fd (resolved through the fd table). */
    failures += check(syscall4(SYS_TIMERFD_SETTIME, (uint64_t)fd, 0, (uint64_t)spec, 0) == 0,
                      "settime arms a 100ms one-shot");
    failures += check(syscall4(SYS_TIMERFD_GETTIME, (uint64_t)fd, (uint64_t)cur, 0, 0) == 0,
                      "gettime on the fd succeeds");
    failures += check(syscall4(SYS_TIMERFD_SETTIME, 9999, 0, (uint64_t)spec, 0) == -EBADF,
                      "settime rejects a non-timerfd fd");

    failures += check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&val, 8) == -EAGAIN,
                      "read before the 100ms expiry is still EAGAIN");

    /* Expiry is processed by the ~100Hz tick maintenance pass, so poll the
     * read with a bounded retry instead of assuming a fixed latency. */
    {
        int64_t n = -EAGAIN;
        int tries;
        for (tries = 0; tries < 40 && n == -EAGAIN; tries++) {
            sleep_ms(50);
            n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&val, 8);
        }
        failures += check(n == 8 && val >= 1, "read after expiry returns expirations");
    }

    failures += check(syscall1(SYS_CLOSE, (uint64_t)dupfd) == 0, "close dup fd succeeds");
    failures += check(syscall1(SYS_CLOSE, (uint64_t)fd) == 0, "close timerfd succeeds");

    if (failures != 0) exit_raw(1);
    print("hello94: PASS\n");
    print("hello94 done\n");
    exit_raw(0);
}
