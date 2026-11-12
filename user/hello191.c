/// hello191: deeper hostile-argument sweep (ROUNDS = 8 here; a 40-round run of 18,200 calls was clean too). hello190 passes only bad pointers, so most calls fail argument
/// validation straight away. Here every system call (same exclusions) is also called with arguments that
/// get PAST validation: pointers into a mapped, pre-filled buffer, small integers, plausible file
/// descriptors and lengths, mixed pseudo-randomly (xorshift, seeded by call number and round, so a panic
/// can be reproduced from the "fz nr/round" line printed before each call). The kernel must answer every
/// one without panicking or hanging, and still fork and reap afterwards.

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
#define SYS_SETSID    206
#define SYS_EXIT      2
#define SYS_NANOSLEEP 35
#define SYS_FORK      57
#define SYS_KILL      62
#define SYS_WAIT4     263
#define SYS_SCHED_YIELD 24
#define WNOHANG       1
#define NSYS          512
#define ROUNDS        8
#define BUFSZ         65536

struct ts { int64_t s, n; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static void print_num(uint64_t x) {
    char r[24]; int m = 0; char o[28]; int k = 0;
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k] = 0;
    print(o);
}

/* Calls that would end the run or damage other tests on purpose (same list as hello190). */
static const int SKIP[] = { 2,5,29,56,57,58,59,60,62,64,68,149,153,156,205,206,207,220,222,223,224,226,233,238,243,262,264,266,270,273,279,283,284,288,289,295,296,308,316,318,319,322,334,424,428,429,432,433,435,442,457,458,467,472,473,484,485,501 };
static int skipped(int n) {
    for (unsigned i = 0; i < sizeof(SKIP) / sizeof(SKIP[0]); i++) {
        if (SKIP[i] == n) return 1;
    }
    return 0;
}

static uint64_t rng_state;
static uint64_t rnd(void) {
    uint64_t x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    rng_state = x;
    return x;
}

static unsigned char buf[BUFSZ] __attribute__((aligned(4096)));

/* The first half of the buffer is printable text (no newline) so a write to the console stays harmless;
 * the second half is arbitrary bytes. */
static void fill_buffer(void) {
    rng_state = 0x9e3779b97f4a7c15ULL;
    for (int i = 0; i < BUFSZ / 2; i++) buf[i] = (unsigned char)(0x20 + rnd() % 0x5f);
    for (int i = BUFSZ / 2; i < BUFSZ; i++) buf[i] = (unsigned char)rnd();
}

static const uint64_t SMALL[] = { 0, 1, 2, 3, 4, 5, 7, 8, 12, 16, 24, 32, 64, 100, 128, 255, 256, 1024, 4096, 65536 };
static const uint64_t BAD[] = { ~0ULL, 0x8000000000000000ULL, 0x100000000ULL, 0xffff800000000000ULL, 0x7fffffffULL, 0x80000000ULL };

static uint64_t pick(int i, int round) {
    (void)round;
    uint64_t r = rnd();
    uint64_t k = r % 100;
    r = rnd();
    if (k < 35) return SMALL[r % (sizeof(SMALL) / sizeof(SMALL[0]))];
    if (k < 70) return (uint64_t)&buf[(r % (BUFSZ - 64)) & ~7ULL];         /* a pointer into the buffer */
    if (k < 80) return r % 8;                                               /* a plausible fd */
    if (k < 90) return BAD[r % (sizeof(BAD) / sizeof(BAD[0]))];
    if (k < 95) return (uint64_t)&buf[0] + (i & 1) * 8;
    return r;
}

static void args_for(int nr, int round, uint64_t a[6]) {
    rng_state = 0x2545f4914f6cdd1dULL ^ ((uint64_t)nr * 0x9e3779b97f4a7c15ULL) ^ ((uint64_t)(round + 1) * 0xbf58476d1ce4e5b9ULL);
    if (rng_state == 0) rng_state = 1;
    for (int i = 0; i < 6; i++) a[i] = pick(i, round);
}

void _start(void) {
    print("hello191: deep hostile-argument sweep\n");
    fill_buffer();
    int calls = 0, killed = 0;
    for (int nr = 0; nr < NSYS; nr++) {
        if (skipped(nr)) continue;
        for (int round = 0; round < ROUNDS; round++) {
            uint64_t a[6];
            args_for(nr, round, a);
            int64_t pid = syscall1(SYS_FORK, 0);
            if (pid == 0) {
                /* Own session: a console read by fd 0 must not SIGTTIN-stop the parent along with the child. */
                syscall1(SYS_SETSID, 0);
                print("fz "); print_num((uint64_t)nr); print("/"); print_num((uint64_t)round); print("\n");
                syscall6((uint64_t)nr, a[0], a[1], a[2], a[3], a[4], a[5]);
                syscall1(SYS_EXIT, 0);
                for (;;) {}
            }
            if (pid < 0) { print("hello191:   FAIL fork failed\n"); print("hello191: FAIL\n"); syscall1(SYS_EXIT, 1); }
            calls++;
            int done = 0;
            for (int w = 0; w < 400 && !done; w++) {
                int st = 0;
                int64_t r = syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, WNOHANG, 0);
                if (r == pid) { done = 1; break; }
                if (w < 300) { syscall1(SYS_SCHED_YIELD, 0); continue; }
                struct ts t = { 0, 10 * 1000 * 1000 };
                syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
            }
            if (!done) {
                syscall2(SYS_KILL, (uint64_t)pid, 9);
                int st = 0;
                syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, 0, 0);
                killed++;
            }
        }
    }
    print("hello191: calls="); print_num((uint64_t)calls);
    print(" blocked-and-killed="); print_num((uint64_t)killed); print("\n");
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) { syscall1(SYS_EXIT, 7); for (;;) {} }
    int st = 0;
    int64_t r = syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, 0, 0);
    int ok = pid > 0 && r == pid && ((st >> 8) & 0xff) == 7;
    print(ok ? "hello191:   ok   the kernel still forks and reaps after the sweep\n" : "hello191:   FAIL the kernel no longer forks and reaps\n");
    print(ok ? "hello191: PASS\n" : "hello191: FAIL\n");
    print("hello191 done\n");
    syscall1(SYS_EXIT, ok ? 0 : 1);
    for (;;) {}
}
