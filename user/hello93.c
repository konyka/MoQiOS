// hello93 - eventfd2 acceptance: drain vs EFD_SEMAPHORE reads, nonblocking
// EAGAIN boundaries, EINVAL cases, fork-shared counter, and a blocking read
// woken by a writer in the parent process.
#include <stdint.h>

static inline int64_t syscall0(uint64_t n) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n) : "rcx", "r11", "memory");
    return r;
}

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

#define SYS_READ 10
#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_CLOSE 11
#define SYS_FORK 57
#define SYS_WAITPID 6
#define SYS_EVENTFD 169
#define SYS_NANOSLEEP 199

#define EFD_SEMAPHORE 1
#define EFD_NONBLOCK 0x800
#define EAGAIN 11
#define EINVAL 22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello93: FAIL ");
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

static int64_t efd_write(int64_t fd, uint64_t val) {
    return syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)&val, 8);
}

static int64_t efd_read(int64_t fd, uint64_t *out) {
    return syscall3(SYS_READ, (uint64_t)fd, (uint64_t)out, 8);
}

void _start(void) {
    int failures = 0;
    uint64_t val = 0;
    print("hello93: start\n");

    /* Unknown creation flags are rejected. */
    failures += check(syscall2(SYS_EVENTFD, 0, 0x1000) == -EINVAL,
                      "unknown eventfd flags rejected");

    /* Default mode: write 3 → read drains and returns 3. */
    {
        int64_t fd = syscall2(SYS_EVENTFD, 0, EFD_NONBLOCK);
        failures += check(fd >= 0, "eventfd create");
        failures += check(efd_write(fd, 3) == 8, "write 3 succeeds");
        failures += check(efd_read(fd, &val) == 8 && val == 3, "drain read returns 3");
        failures += check(efd_read(fd, &val) == -EAGAIN, "empty nonblocking read is EAGAIN");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* EFD_SEMAPHORE: each read decrements by 1 and returns 1. */
    {
        int64_t fd = syscall2(SYS_EVENTFD, 0, EFD_SEMAPHORE | EFD_NONBLOCK);
        failures += check(fd >= 0, "semaphore eventfd create");
        failures += check(efd_write(fd, 3) == 8, "semaphore write 3 succeeds");
        failures += check(efd_read(fd, &val) == 8 && val == 1, "semaphore read returns 1");
        failures += check(efd_read(fd, &val) == 8 && val == 1, "semaphore second read returns 1");
        failures += check(efd_read(fd, &val) == 8 && val == 1, "semaphore third read returns 1");
        failures += check(efd_read(fd, &val) == -EAGAIN, "semaphore drained read is EAGAIN");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* Full counter: a further nonblocking write is EAGAIN, never a wrap. */
    {
        int64_t fd = syscall2(SYS_EVENTFD, 0, EFD_NONBLOCK);
        failures += check(fd >= 0, "full eventfd create");
        failures += check(efd_write(fd, 0xFFFFFFFFFFFFFFFEULL) == 8, "write up to 2^64-2 succeeds");
        failures += check(efd_write(fd, 1) == -EAGAIN, "overflowing nonblocking write is EAGAIN");
        failures += check(efd_read(fd, &val) == 8 && val == 0xFFFFFFFFFFFFFFFEULL,
                          "full counter drains intact");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* EINVAL: short buffers and the reserved value 2^64-1. */
    {
        int64_t fd = syscall2(SYS_EVENTFD, 0, EFD_NONBLOCK);
        failures += check(fd >= 0, "EINVAL eventfd create");
        failures += check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&val, 4) == -EINVAL,
                          "short read is EINVAL");
        failures += check(syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)&val, 4) == -EINVAL,
                          "short write is EINVAL");
        failures += check(efd_write(fd, 0xFFFFFFFFFFFFFFFFULL) == -EINVAL,
                          "write of 2^64-1 is EINVAL");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* Fork-shared instance: the child observes the parent's counter. */
    {
        int64_t fd = syscall2(SYS_EVENTFD, 0, EFD_NONBLOCK);
        int status = 0;
        failures += check(fd >= 0, "fork eventfd create");
        failures += check(efd_write(fd, 5) == 8, "parent writes 5 before fork");
        int64_t child = syscall0(SYS_FORK);
        failures += check(child >= 0, "fork succeeds");
        if (child == 0) {
            uint64_t cval = 0;
            int64_t n = efd_read(fd, &cval);
            exit_raw(n == 8 && cval == 5 ? 0 : 1);
        }
        failures += check(syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&status, 0) == child && status == 0,
                          "child reads shared counter value 5");
        failures += check(efd_read(fd, &val) == -EAGAIN, "parent sees child drained counter");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* Blocking read (no EFD_NONBLOCK) woken by the parent's write. */
    {
        int64_t fd = syscall2(SYS_EVENTFD, 0, 0);
        int status = 0;
        failures += check(fd >= 0, "blocking eventfd create");
        int64_t child = syscall0(SYS_FORK);
        failures += check(child >= 0, "blocking fork succeeds");
        if (child == 0) {
            uint64_t cval = 0;
            int64_t n = efd_read(fd, &cval); /* blocks until the parent writes */
            exit_raw(n == 8 && cval == 7 ? 0 : 1);
        }
        sleep_ms(100); /* let the child block first */
        failures += check(efd_write(fd, 7) == 8, "parent write wakes blocked reader");
        failures += check(syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&status, 0) == child && status == 0,
                          "blocked reader woke with value 7");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    if (failures != 0) exit_raw(1);
    print("hello93: PASS\n");
    print("hello93 done\n");
    exit_raw(0);
}
