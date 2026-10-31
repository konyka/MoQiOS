/// hello154: TCP write errors and half-close.

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
#define SYS_NANOSLEEP 35
#define SYS_SHUTDOWN  48
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SENDTO    121
#define SYS_FCNTL     142
#define SYS_CLOCK_GETTIME 228
#define AF_INET 2
#define SOCK_STREAM 1
#define SHUT_WR 1
#define MSG_NOSIGNAL 0x4000
#define EPIPE_ 32
#define ENOTCONN_ 107
#define ECONNRESET_ 104
#define BIG 300000

struct ts { int64_t s, n; };
struct tv { int64_t s, us; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello154:   ok   " : "hello154:   FAIL ");
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


static void pump(int ms) {
    for (int i = 0; i < ms; i += 10) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); }
}

void _start(void) {
    print("hello154: TCP write errors and half-close\n");
    char b[16];

    /* A: SHUT_WR - the peer reads EOF after the data, this end cannot write,
     * the other direction still works */
    {
        int c, s;
        check(make_pair(18154, &c, &s) == 0, "A: loopback connection");
        syscall3(SYS_WRITE, c, (uint64_t)"abc", 3);
        check(syscall2(SYS_SHUTDOWN, c, SHUT_WR) == 0, "A: shutdown(SHUT_WR) succeeds");
        pump(100);
        check(syscall3(SYS_READ, s, (uint64_t)b, 16) == 3, "A: the peer reads the bytes sent before the shutdown");
        check(syscall3(SYS_READ, s, (uint64_t)b, 16) == 0, "A: then reads EOF (0)");
        check(syscall3(SYS_WRITE, c, (uint64_t)"x", 1) == -EPIPE_, "A: write after SHUT_WR is EPIPE");
        check(syscall6(SYS_SENDTO, (uint64_t)c, (uint64_t)"x", 1, MSG_NOSIGNAL, 0, 0) == -EPIPE_, "A: sendto after SHUT_WR is EPIPE");
        check(syscall3(SYS_WRITE, s, (uint64_t)"hi", 2) == 2, "A: the peer can still send");
        pump(100);
        check(syscall3(SYS_READ, c, (uint64_t)b, 16) == 2, "A: and the half-closed end receives it");
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    /* B: writing to a connection whose peer is gone */
    {
        int c, s;
        check(make_pair(18155, &c, &s) == 0, "B: loopback connection");
        syscall1(SYS_CLOSE, s);
        pump(150);
        int64_t w = 0;
        for (int i = 0; i < 8 && w >= 0; i++) {
            w = syscall6(SYS_SENDTO, (uint64_t)c, (uint64_t)"x", 1, MSG_NOSIGNAL, 0, 0);
            pump(150);
        }
        check(w == -EPIPE_ || w == -ECONNRESET_, "B: sending to a closed peer ends in EPIPE or ECONNRESET");
        syscall1(SYS_CLOSE, c);
    }

    /* C: write on a socket that is not connected */
    {
        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
        int64_t w = syscall3(SYS_WRITE, u, (uint64_t)"x", 1);
        check(w == -ENOTCONN_ || w == -EPIPE_, "C: write on an unconnected TCP socket is ENOTCONN (or EPIPE)");
        char rb[4];
        int64_t r = syscall3(SYS_READ, u, (uint64_t)rb, 4);
        check(r == -ENOTCONN_, "C: read on an unconnected TCP socket is ENOTCONN");
        syscall1(SYS_CLOSE, u);
    }

    print(failures == 0 ? "hello154: PASS\n" : "hello154: FAIL\n");
    print("hello154 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
