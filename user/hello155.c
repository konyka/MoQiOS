/// hello155: SIGPIPE on sockets.

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
#define SYS_NANOSLEEP 35
#define SYS_SHUTDOWN  48
#define SYS_SOCKETPAIR 53
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_CONNECT   124
#define SYS_SENDTO    121
#define SYS_ACCEPT4   131
#define SYS_CLOCK_GETTIME 228
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SHUT_WR 1
#define MSG_NOSIGNAL 0x4000
#define SIGPIPE_ 13
#define EPIPE_ 32

struct ts { int64_t s, n; };
struct tv { int64_t s, us; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello155:   ok   " : "hello155:   FAIL ");
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

/* Run the writer in a child and report how it ended: 0 = exited normally with
 * status 0 (it saw EPIPE and survived), 1 = killed by SIGPIPE, -1 = other. */
enum { SOCK_TCP, SOCK_UNIX };
static int run_writer(int kind, int use_write, int flags) {
    int c = -1, s = -1;
    if (kind == SOCK_TCP) {
        if (make_pair(18160 + use_write * 2 + (flags ? 1 : 0), &c, &s) != 0) return -1;
        syscall2(SYS_SHUTDOWN, c, SHUT_WR);
        pump(50);
    } else {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        c = sv[0]; s = sv[1];
        syscall1(SYS_CLOSE, s);
    }
    int64_t child = syscall1(SYS_FORK, 0);
    if (child == 0) {
        int64_t r = use_write ? syscall3(SYS_WRITE, c, (uint64_t)"x", 1)
                              : syscall6(SYS_SENDTO, (uint64_t)c, (uint64_t)"x", 1, (uint64_t)flags, 0, 0);
        syscall1(SYS_EXIT, r == -EPIPE_ ? 0 : 2);
        for (;;) {}
    }
    int st = -1;
    int done = 0;
    int64_t t0 = now_ms();
    while (now_ms() - t0 < 1500) {
        if (syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 1) == child) { done = 1; break; }
        sleep_ms(10);
    }
    syscall1(SYS_CLOSE, c);
    if (kind == SOCK_TCP) syscall1(SYS_CLOSE, s);
    if (!done) { syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0); return -1; }
    if ((st & 0x7f) == SIGPIPE_) return 1;
    if ((st & 0x7f) == 0 && ((st >> 8) & 0xff) == 0) return 0;
    return -1;
}

void _start(void) {
    print("hello155: SIGPIPE on sockets\n");
    check(run_writer(SOCK_TCP, 1, 0) == 1, "A: write() to a TCP socket after SHUT_WR raises SIGPIPE");
    check(run_writer(SOCK_TCP, 0, 0) == 1, "A: sendto() to a TCP socket after SHUT_WR raises SIGPIPE");
    check(run_writer(SOCK_TCP, 0, MSG_NOSIGNAL) == 0, "A: sendto(MSG_NOSIGNAL) gets EPIPE and survives");
    check(run_writer(SOCK_UNIX, 1, 0) == 1, "B: write() to an AF_UNIX socket whose peer closed raises SIGPIPE");
    check(run_writer(SOCK_UNIX, 0, 0) == 1, "B: sendto() to an AF_UNIX socket whose peer closed raises SIGPIPE");
    check(run_writer(SOCK_UNIX, 0, MSG_NOSIGNAL) == 0, "B: sendto(MSG_NOSIGNAL) gets EPIPE and survives");
    print(failures == 0 ? "hello155: PASS\n" : "hello155: FAIL\n");
    print("hello155 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
