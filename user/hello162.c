/// hello162: remaining timeout is written back by ppoll/pselect6/select.

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
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_PIPE      22
#define SYS_SELECT    23
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_CLOCK_GETTIME 228
#define SYS_PPOLL     493
#define SYS_PSELECT6  494
#define POLLIN 0x001

struct pollfd { int32_t fd; int16_t events; int16_t revents; };
struct ts { int64_t s, n; };
struct tv { int64_t s, us; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello162:   ok   " : "hello162:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static int64_t now_ms(void) {
    struct ts t;
    syscall2(SYS_CLOCK_GETTIME, 1, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}

static void mk_addr(uint8_t *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[1] = 2; a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port; a[4] = 127; a[7] = 1;
}

/* Connected loopback pair: *cli is the client end, *srv the accepted end. */

void _start(void) {
    print("hello162: remaining timeout is written back\n");
    int p[2];
    syscall1(SYS_PIPE, (uint64_t)p);

    /* A: ppoll that times out leaves ~0 behind */
    {
        struct pollfd pf = { p[0], POLLIN, 0 };
        struct ts t = { 0, 150 * 1000000 };
        int64_t t0 = now_ms();
        int64_t r = syscall5(SYS_PPOLL, (uint64_t)&pf, 1, (uint64_t)&t, 0, 8);
        int64_t dt = now_ms() - t0;
        check(r == 0 && dt >= 120, "A: ppoll times out after about 150 ms");
        check(t.s == 0 && t.n < 30 * 1000000, "A: and the remaining time written back is about zero");
    }

    /* B: ppoll that is satisfied early reports what is left */
    {
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            sleep_ms(100);
            syscall3(SYS_WRITE, p[1], (uint64_t)"x", 1);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        struct pollfd pf = { p[0], POLLIN, 0 };
        struct ts t = { 1, 0 };
        int64_t r = syscall5(SYS_PPOLL, (uint64_t)&pf, 1, (uint64_t)&t, 0, 8);
        check(r == 1, "B: ppoll returns when the pipe becomes readable");
        int64_t left_ms = t.s * 1000 + t.n / 1000000;
        check(left_ms > 500 && left_ms < 950, "B: and about 900 ms remain in the timespec");
        char b[4];
        syscall3(SYS_READ, p[0], (uint64_t)b, 4);
        int st = 0;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
    }

    /* C: pselect6 */
    {
        uint64_t rfds[2] = { 1ull << p[0], 0 };
        struct ts t = { 0, 120 * 1000000 };
        uint64_t sig[2] = { 0, 8 };
        int64_t r = syscall6(SYS_PSELECT6, (uint64_t)(p[0] + 1), (uint64_t)rfds, 0, 0, (uint64_t)&t, 0);
        (void)sig;
        check(r == 0, "C: pselect6 times out");
        check(t.s == 0 && t.n < 30 * 1000000, "C: and writes back about zero remaining");
    }

    /* D: select updates its timeval too (Linux behaviour) */
    {
        uint64_t rfds[2] = { 1ull << p[0], 0 };
        struct { int64_t s, us; } tv = { 0, 120000 };
        int64_t r = syscall5(SYS_SELECT, (uint64_t)(p[0] + 1), (uint64_t)rfds, 0, 0, (uint64_t)&tv);
        check(r == 0, "D: select times out");
        check(tv.s == 0 && tv.us < 30000, "D: and the timeval holds about zero");
    }

    /* E: a null timeout is left alone and an untouched timeout is not corrupted on error */
    {
        struct ts t = { 0, 1000 };
        struct pollfd pf = { 999, POLLIN, 0 };
        int64_t r = syscall5(SYS_PPOLL, (uint64_t)&pf, 1, (uint64_t)&t, 0, 8);
        check(r == 1, "E: an invalid descriptor is reported as ready (POLLNVAL)");
        check(t.s == 0 && t.n <= 1000, "E: and the remaining time never exceeds the original");
    }

    print(failures == 0 ? "hello162: PASS\n" : "hello162: FAIL\n");
    print("hello162 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
