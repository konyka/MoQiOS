/// hello182: poll()/select() wake-up latency when another process makes a descriptor ready (vs epoll).

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
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_SOCKETPAIR 53
#define SYS_POLL      162
#define SYS_SELECT    23
#define SYS_NANOSLEEP 35
#define SYS_PIPE      22
#define SYS_EPOLL_CREATE1 146
#define SYS_EPOLL_CTL 147
#define SYS_EPOLL_WAIT 148
#define SYS_CLOCK_GETTIME 228
#define AF_UNIX 1
#define SOCK_STREAM 1
#define POLLIN 1
#define EPOLLIN 1
#define EPOLL_CTL_ADD 1

struct pollfd { int32_t fd; int16_t events; int16_t revents; };
struct epev { uint32_t events; uint64_t data; } __attribute__((packed));
struct ts { int64_t s, n; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static void print_num(const char *label, int64_t x) {
    char r[24]; int m = 0; char o[40]; int k = 0;
    print(label);
    if (x < 0) { o[k++] = '-'; x = -x; }
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k++] = '\n'; o[k] = 0;
    print(o);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello182:   ok   " : "hello182:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t now_us(void) {
    struct ts t;
    syscall2(SYS_CLOCK_GETTIME, 1, (uint64_t)&t);
    return t.s * 1000000 + t.n / 1000;
}

#define ROUNDS 100

/* The child echoes every byte it reads; the parent waits for the echo with `wait_fn`. */
static int64_t pingpong(int use_epoll) {
    int sv[2];
    syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        char c;
        for (int i = 0; i < ROUNDS; i++) {
            if (syscall3(SYS_READ, sv[1], (uint64_t)&c, 1) != 1) break;
            syscall3(SYS_WRITE, sv[1], (uint64_t)&c, 1);
        }
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
    int ep = -1;
    if (use_epoll) {
        ep = (int)syscall1(SYS_EPOLL_CREATE1, 0);
        struct epev e = { EPOLLIN, 0 };
        syscall4(SYS_EPOLL_CTL, ep, EPOLL_CTL_ADD, sv[0], (uint64_t)&e);
    }
    int64_t t0 = now_us();
    for (int i = 0; i < ROUNDS; i++) {
        char c = 'x';
        syscall3(SYS_WRITE, sv[0], (uint64_t)&c, 1);
        if (use_epoll) {
            struct epev out;
            syscall4(SYS_EPOLL_WAIT, ep, (uint64_t)&out, 1, 2000);
        } else {
            struct pollfd p = { sv[0], POLLIN, 0 };
            syscall3(SYS_POLL, (uint64_t)&p, 1, 2000);
        }
        syscall3(SYS_READ, sv[0], (uint64_t)&c, 1);
    }
    int64_t dt = now_us() - t0;
    int st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    syscall1(SYS_CLOSE, sv[0]);
    syscall1(SYS_CLOSE, sv[1]);
    if (ep >= 0) syscall1(SYS_CLOSE, ep);
    return dt / ROUNDS;
}

struct tv { int64_t s, us; };
static void sleep_ms_(int ms) {
    struct ts t = { ms / 1000, (int64_t)(ms % 1000) * 1000000 }; /* tv_nsec must stay below one second */
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}

/* A delayed write from a child must end a LONG wait promptly: not at the end of the timeout. */
static int64_t delayed_wake(int use_select, int delay_ms, int timeout_ms, int *got) {
    int sv[2];
    syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        sleep_ms_(delay_ms);
        syscall3(SYS_WRITE, sv[1], (uint64_t)"x", 1);
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
    int64_t t0 = now_us();
    int64_t r;
    if (use_select) {
        uint64_t rfds[16];
        for (int i = 0; i < 16; i++) rfds[i] = 0;
        rfds[sv[0] / 64] |= 1ULL << (sv[0] % 64);
        struct tv tvv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
        r = syscall5(SYS_SELECT, (uint64_t)(sv[0] + 1), (uint64_t)rfds, 0, 0, (uint64_t)&tvv);
    } else {
        struct pollfd p = { sv[0], POLLIN, 0 };
        r = syscall3(SYS_POLL, (uint64_t)&p, 1, (uint64_t)timeout_ms);
    }
    int64_t dt = now_us() - t0;
    *got = (int)r;
    int st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    syscall1(SYS_CLOSE, sv[0]);
    syscall1(SYS_CLOSE, sv[1]);
    return dt;
}

void _start(void) {
    print("hello182: poll vs epoll wake-up latency\n");
    int64_t e = pingpong(1);
    int64_t p = pingpong(0);
    print_num("hello182: epoll round trip, us: ", e);
    print_num("hello182: poll  round trip, us: ", p);
    check(e < 5000, "A: an epoll round trip over a socketpair stays under 5 ms");
    check(p < 5000, "A: and so does a poll round trip");

    /* B: a long timeout is cut short by the event (the 5 ms slice alone could not tell these apart from a short wait) */
    {
        int g;
        int64_t dt = delayed_wake(0, 60, 3000, &g);
        print_num("hello182: poll woke after, us: ", dt);
        check(g == 1, "B: poll reports the descriptor ready");
        check(dt < 300000, "B: and returns well before its 3 s timeout (the write came after 60 ms)");
        dt = delayed_wake(1, 60, 3000, &g);
        print_num("hello182: select woke after, us: ", dt);
        check(g == 1, "B: select reports the descriptor ready");
        check(dt < 300000, "B: and returns well before its 3 s timeout");
    }

    /* C: a wait with nothing happening still times out on schedule */
    {
        int g;
        int64_t dt = delayed_wake(0, 1000, 120, &g);
        check(g == 0, "C: poll with no event returns 0 at its timeout");
        check(dt >= 100000 && dt < 600000, "C: after about the requested 120 ms (not early, not much late)");
        dt = delayed_wake(1, 1000, 120, &g);
        check(g == 0, "C: select with no event returns 0 at its timeout");
        check(dt >= 100000 && dt < 600000, "C: after about the requested 120 ms");
    }
    print(failures == 0 ? "hello182: PASS\n" : "hello182: FAIL\n");
    print("hello182 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
