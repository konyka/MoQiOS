/// hello152: read() returns what is available.

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
#define SYS_PIPE      22
#define SYS_NANOSLEEP 35
#define SYS_NETPOLL   104
#define SYS_IOCTL     165
#define FIONREAD      0x541B
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SOCKETPAIR 53
#define SYS_CLOCK_GETTIME 228
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello152:   ok   " : "hello152:   FAIL ");
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
static uint8_t out[20000];
static uint8_t in[20000];

static void mk_addr(uint8_t *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[1] = 2; a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port; a[4] = 127; a[7] = 1;
}
static int make_pair(int port, int *cli, int *srv) {
    uint8_t sa[16];
    mk_addr(sa, port);
    int64_t l = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    if (l < 0) return -1;
    if (syscall3(SYS_BIND, (uint64_t)l, (uint64_t)sa, 16) != 0) return -2;
    if (syscall2(SYS_LISTEN, (uint64_t)l, 4) != 0) return -3;
    int64_t c = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    if (c < 0) return -4;
    int64_t cr = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, 16);
    if (cr < 0) syscall1(SYS_NETPOLL, 0);
    for (int i = 0; i < 20 && cr < 0; i++) {
        cr = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, 16);
        if (cr < 0) syscall1(SYS_NETPOLL, 0);
    }
    if (cr != 0) return -5;
    int64_t a = -1;
    for (int i = 0; i < 20 && a < 0; i++) {
        syscall1(SYS_NETPOLL, 0);
        a = syscall4(SYS_ACCEPT4, (uint64_t)l, 0, 0, 0);
    }
    if (a < 0) return -6;
    syscall1(SYS_CLOSE, (uint64_t)l);
    *cli = (int)c;
    *srv = (int)a;
    return 0;
}

/* Reading more than is queued must return the queued bytes at once, not wait
 * for the rest of the buffer. A child does the read so a hang is bounded. */
static void probe(const char *name, int wfd, int rfd, int queued, int ask, int settle_ms) {
    for (int i = 0; i < queued; i++) out[i] = (uint8_t)(i * 3 + 1);
    int64_t w = syscall3(SYS_WRITE, wfd, (uint64_t)out, (uint64_t)queued);
    if (w != queued) { check(0, name); return; }
    for (int i = 0; i < settle_ms; i += 20) {
        int avail = 0;
        syscall1(SYS_NETPOLL, 0);
        if (syscall3(SYS_IOCTL, (uint64_t)rfd, FIONREAD, (uint64_t)&avail) == 0 && avail >= queued) break;
        sleep_ms(20);
    }
    int64_t child = syscall1(SYS_FORK, 0);
    if (child == 0) {
        int64_t r = syscall3(SYS_READ, rfd, (uint64_t)in, (uint64_t)ask);
        int ok = r == queued;
        for (int i = 0; ok && i < queued; i++) if (in[i] != out[i]) ok = 0;
        syscall1(SYS_EXIT, ok ? 0 : 1);
        for (;;) {}
    }
    int st = -1;
    int64_t t0 = now_ms();
    int done = 0;
    while (now_ms() - t0 < 1500) {
        int64_t r = syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 1);
        if (r == child) { done = 1; break; }
        sleep_ms(10);
    }
    if (!done) {
        /* reader is stuck waiting for more data: feed it so the child can finish */
        syscall3(SYS_WRITE, wfd, (uint64_t)out, 20000 - queued);
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        check(0, name);
        return;
    }
    check(st == 0, name);
}

void _start(void) {
    print("hello152: read() returns what is available\n");
    {
        int p[2];
        syscall1(SYS_PIPE, (uint64_t)p);
        probe("A: pipe: read(8192) with 3000 queued returns 3000", p[1], p[0], 3000, 8192, 0);
        syscall1(SYS_CLOSE, p[0]);
        syscall1(SYS_CLOSE, p[1]);
    }
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        probe("B: AF_UNIX: read(8192) with exactly 4096 queued returns 4096", sv[0], sv[1], 4096, 8192, 0);
        probe("B: AF_UNIX: read(20000) with 8192 queued returns 8192", sv[0], sv[1], 8192, 20000, 0);
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }
    {
        int c, s;
        if (make_pair(18152, &c, &s) == 0) {
            probe("C: TCP: read(8192) with exactly 4096 queued returns 4096", c, s, 4096, 8192, 3000);
            probe("C: TCP: read(20000) with 8192 queued returns 8192", c, s, 8192, 20000, 3000);
            syscall1(SYS_CLOSE, c);
            syscall1(SYS_CLOSE, s);
        } else {
            check(0, "C: loopback connection");
        }
    }
    print(failures == 0 ? "hello152: PASS\n" : "hello152: FAIL\n");
    print("hello152 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
