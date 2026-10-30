/// hello135: signal call argument and errno rules.

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
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_SOCKETPAIR 53
#define SYS_POLL      162
#define SYS_SELECT    163
#define SYS_CLOCK_GETTIME 228
#define SYS_EVENTFD2  169
#define POLLIN  0x001
#define POLLOUT 0x004
#define POLLERR 0x008
#define POLLHUP 0x010
#define POLLNVAL 0x020
#define EINVAL_ 22
#define EFAULT_ 14

struct pfd { int32_t fd; int16_t events, revents; };
struct ts { int64_t s, n; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello139:   ok   " : "hello139:   FAIL ");
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
static int64_t do_poll(int fd, int16_t ev, int timeout_ms, int16_t *rev) {
    struct pfd p = { fd, ev, 0 };
    int64_t r = syscall3(SYS_POLL, (uint64_t)&p, 1, (uint64_t)(int64_t)timeout_ms);
    *rev = p.revents;
    return r;
}
static int64_t do_select_r(int fd, int timeout_ms) {
    uint64_t set[16];
    volatile uint64_t *v = set;
    for (int i = 0; i < 16; i++) v[i] = 0;
    set[fd / 64] |= 1ULL << (fd % 64);
    struct ts t = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
    int64_t r = syscall5(SYS_SELECT, (uint64_t)(fd + 1), (uint64_t)set, 0, 0, (uint64_t)&t);
    return r;
}
static int64_t do_select_w(int fd) {
    uint64_t set[16];
    volatile uint64_t *v = set;
    for (int i = 0; i < 16; i++) v[i] = 0;
    set[fd / 64] |= 1ULL << (fd % 64);
    struct ts t = { 0, 0 };
    return syscall5(SYS_SELECT, (uint64_t)(fd + 1), 0, (uint64_t)set, 0, (uint64_t)&t);
}

void _start(void) {
    print("hello139: poll and select readiness and timeouts\n");
    int16_t rev;

    /* A: an empty pipe is not readable, a written one is, a closed writer is HUP */
    int pfd[2];
    syscall1(SYS_PIPE, (uint64_t)pfd);
    check(do_poll(pfd[0], POLLIN, 0, &rev) == 0 && rev == 0, "A: poll(empty pipe, 0) reports nothing");
    {
        int64_t t0 = now_ms();
        int64_t r = do_poll(pfd[0], POLLIN, 120, &rev);
        int64_t dt = now_ms() - t0;
        check(r == 0, "A: poll(empty pipe, 120 ms) times out with 0");
        check(dt >= 100 && dt < 400, "A: and takes about the requested time");
    }
    syscall3(SYS_WRITE, pfd[1], (uint64_t)"x", 1);
    check(do_poll(pfd[0], POLLIN, 0, &rev) == 1 && rev == POLLIN, "A: a written pipe is POLLIN");
    check(do_poll(pfd[1], POLLOUT, 0, &rev) == 1 && (rev & POLLOUT), "A: the write end is POLLOUT");
    check(do_select_r(pfd[0], 0) == 1, "A: select reports the readable pipe");
    char c;
    syscall3(SYS_READ, pfd[0], (uint64_t)&c, 1);
    check(do_select_r(pfd[0], 0) == 0, "A: select reports nothing once drained");
    syscall1(SYS_CLOSE, pfd[1]);
    check(do_poll(pfd[0], POLLIN, 0, &rev) == 1 && (rev & POLLHUP), "A: a drained pipe whose writer closed is POLLHUP");
    check(do_select_r(pfd[0], 0) == 1, "A: and select calls it readable (EOF)");
    syscall1(SYS_CLOSE, pfd[0]);

    /* B: a pipe whose reader closed makes the write end POLLERR */
    {
        int q[2];
        syscall1(SYS_PIPE, (uint64_t)q);
        syscall1(SYS_CLOSE, q[0]);
        check(do_poll(q[1], POLLOUT, 0, &rev) == 1 && (rev & POLLERR), "B: a write end with no reader is POLLERR");
        syscall1(SYS_CLOSE, q[1]);
    }

    /* C: AF_UNIX socketpair */
    {
        int sv[2];
        check(syscall4(SYS_SOCKETPAIR, 1, 1, 0, (uint64_t)sv) == 0, "C: socketpair");
        check(do_poll(sv[0], POLLIN, 0, &rev) == 0 && rev == 0, "C: an idle socket is not POLLIN");
        check(do_poll(sv[0], POLLOUT, 0, &rev) == 1 && (rev & POLLOUT), "C: and is POLLOUT");
        check(do_select_r(sv[0], 0) == 0, "C: select reports an idle socket as not readable");
        syscall3(SYS_WRITE, sv[1], (uint64_t)"hi", 2);
        check(do_poll(sv[0], POLLIN, 0, &rev) == 1 && (rev & POLLIN), "C: data makes it POLLIN");
        check(do_select_r(sv[0], 0) == 1, "C: and select readable");
        char b[8];
        syscall3(SYS_READ, sv[0], (uint64_t)b, 8);
        syscall1(SYS_CLOSE, sv[1]);
        check(do_poll(sv[0], POLLIN, 0, &rev) == 1 && (rev & (POLLIN | POLLHUP)), "C: a closed peer wakes POLLIN/POLLHUP");
        syscall1(SYS_CLOSE, sv[0]);
    }

    /* D: eventfd */
    {
        int64_t e = syscall2(SYS_EVENTFD2, 0, 0);
        check(e >= 0 && do_poll((int)e, POLLIN, 0, &rev) == 0, "D: a zero eventfd is not readable");
        uint64_t one = 1;
        syscall3(SYS_WRITE, (uint64_t)e, (uint64_t)&one, 8);
        check(do_poll((int)e, POLLIN, 0, &rev) == 1 && (rev & POLLIN), "D: a non-zero eventfd is readable");
        check(do_select_r((int)e, 0) == 1, "D: and select agrees");
        syscall1(SYS_CLOSE, e);
    }

    /* E: argument rules */
    {
        struct pfd p = { 99, POLLIN, 0 };
        check(syscall3(SYS_POLL, (uint64_t)&p, 1, 0) == 1 && p.revents == POLLNVAL, "E: a closed fd is POLLNVAL");
        struct pfd neg = { -1, POLLIN, 0x55 };
        check(syscall3(SYS_POLL, (uint64_t)&neg, 1, 0) == 0 && neg.revents == 0, "E: a negative fd is ignored and revents cleared");
        check(syscall3(SYS_POLL, 0, 1, 0) == -EFAULT_, "E: poll(NULL, 1) is EFAULT");
        check(syscall3(SYS_POLL, 0, 0, 0) == 0, "E: poll(NULL, 0, 0) is a valid empty poll");
        int64_t t0 = now_ms();
        check(syscall3(SYS_POLL, 0, 0, 80) == 0, "E: poll(NULL, 0, 80) sleeps and returns 0");
        int64_t dt = now_ms() - t0;
        check(dt >= 60 && dt < 400, "E: and the sleep lasted about 80 ms");
        struct pfd many[200];
        volatile char *mp = (volatile char *)many;
        for (unsigned i = 0; i < sizeof many; i++) mp[i] = 0;
        for (int i = 0; i < 200; i++) many[i].fd = -1;
        check(syscall3(SYS_POLL, (uint64_t)many, 64, 0) == 0, "E: nfds up to RLIMIT_NOFILE is accepted");
        check(syscall3(SYS_POLL, (uint64_t)many, 200, 0) == -EINVAL_, "E: nfds above RLIMIT_NOFILE is EINVAL");
    }

    /* F: a blocked poll is woken by a writer, and timeout -1 waits */
    {
        int q[2];
        syscall1(SYS_PIPE, (uint64_t)q);
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            sleep_ms(150);
            syscall3(SYS_WRITE, q[1], (uint64_t)"w", 1);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        int64_t t0 = now_ms();
        int64_t r = do_poll(q[0], POLLIN, -1, &rev);
        int64_t dt = now_ms() - t0;
        check(r == 1 && (rev & POLLIN), "F: poll(-1) waits until the writer writes");
        check(dt >= 100 && dt < 600, "F: and wakes promptly after it");
        int st = 0;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&st, 0);
        syscall1(SYS_CLOSE, q[0]);
        syscall1(SYS_CLOSE, q[1]);
    }

    /* G: select argument rules */
    {
        struct ts bad = { 0, 2000000 };
        uint64_t set[16];
        volatile uint64_t *v = set;
        for (int i = 0; i < 16; i++) v[i] = 0;
        check(syscall5(SYS_SELECT, 1, (uint64_t)set, 0, 0, (uint64_t)&bad) == -EINVAL_, "G: tv_usec >= 1e6 is EINVAL");
        int q[2];
        syscall1(SYS_PIPE, (uint64_t)q);
        set[q[0] / 64] |= 1ULL << (q[0] % 64);
        struct ts t = { 0, 100000 };
        int64_t t0 = now_ms();
        int64_t r = syscall5(SYS_SELECT, (uint64_t)(q[0] + 1), (uint64_t)set, 0, 0, (uint64_t)&t);
        int64_t dt = now_ms() - t0;
        check(r == 0 && dt >= 80 && dt < 400, "G: select with a 100 ms timeout returns 0 after about 100 ms");
        check(set[q[0] / 64] == 0, "G: and the set is cleared on timeout");
        check(do_select_w(q[1]) == 1, "G: select reports the write end writable");
        syscall1(SYS_CLOSE, q[0]);
        syscall1(SYS_CLOSE, q[1]);
    }

    print(failures == 0 ? "hello139: PASS\n" : "hello139: FAIL\n");
    print("hello139 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
