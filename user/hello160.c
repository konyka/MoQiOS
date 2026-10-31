/// hello160: TCP connect to a closed port.

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
#define SYS_EPOLL_CREATE1 146
#define SYS_EPOLL_CTL 147
#define SYS_EPOLL_WAIT 148
#define SYS_POLL      162
#define SYS_FCNTL     142
#define SYS_CLOCK_GETTIME 228
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define AF_INET 2
#define SOCK_STREAM 1
#define SHUT_RD 0
#define SHUT_WR 1
#define POLLIN  0x001
#define POLLOUT 0x004
#define POLLERR 0x008
#define POLLRDHUP 0x2000
#define POLLHUP 0x010
#define EPOLLIN  0x001
#define EPOLLOUT 0x004
#define EPOLLERR 0x008
#define EPOLLRDHUP 0x2000
#define EPOLLHUP 0x010

struct pollfd { int32_t fd; int16_t events; int16_t revents; };
struct epev { uint32_t events; uint64_t data; } __attribute__((packed));

struct ts { int64_t s, n; };
struct tv { int64_t s, us; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello160:   ok   " : "hello160:   FAIL ");
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

#define SYS_GETSOCKOPT 133
#define SOL_SOCKET 1
#define SO_ERROR 4
#define ECONNREFUSED_ 111
#define EINPROGRESS_ 115

static void pump(int ms) {
    for (int i = 0; i < ms; i += 10) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); }
}
static int revents_of(int fd, int events) {
    struct pollfd p = { fd, (int16_t)events, 0 };
    syscall3(SYS_POLL, (uint64_t)&p, 1, 0);
    return p.revents;
}
static int so_error(int fd) {
    int v = -1;
    uint32_t len = 4;
    if (syscall5(SYS_GETSOCKOPT, (uint64_t)fd, SOL_SOCKET, SO_ERROR, (uint64_t)&v, (uint64_t)&len) != 0) return -999;
    return v;
}

void _start(void) {
    print("hello160: TCP connect to a closed port\n");
    uint8_t sa[16];
    mk_addr(sa, 18199); /* nobody listens here */

    /* A: blocking connect to a closed port fails fast with ECONNREFUSED */
    {
        int64_t c = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
        int64_t t0 = now_ms();
        int64_t r = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, 16);
        for (int i = 0; i < 100 && r < 0 && r != -ECONNREFUSED_ && now_ms() - t0 < 3000; i++) {
            pump(20);
            r = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, 16);
        }
        check(r == -ECONNREFUSED_, "A: connect() to a closed port reports ECONNREFUSED");
        check(now_ms() - t0 < 3000, "A: and does so promptly (no SYN retransmission timeout)");
        syscall1(SYS_CLOSE, c);
    }

    /* B: non-blocking connect: poll reports the failure, SO_ERROR says why */
    {
        int64_t c = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
        syscall3(SYS_FCNTL, (uint64_t)c, F_SETFL, O_NONBLOCK);
        int64_t r = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, 16);
        check(r == -EINPROGRESS_ || r == -ECONNREFUSED_, "B: non-blocking connect returns EINPROGRESS (or the error at once)");
        int ev = 0;
        for (int i = 0; i < 100; i++) {
            pump(20);
            ev = revents_of((int)c, POLLOUT | POLLIN);
            if (ev & (POLLERR | POLLHUP)) break;
        }
        check((ev & (POLLERR | POLLHUP)) != 0, "B: poll reports POLLERR/POLLHUP for the refused connection");
        check((ev & POLLERR) != 0, "B: specifically POLLERR");
        check(so_error((int)c) == ECONNREFUSED_, "B: SO_ERROR is ECONNREFUSED");
        check(so_error((int)c) == 0, "B: and reading SO_ERROR clears it");
        syscall1(SYS_CLOSE, c);
    }

    print(failures == 0 ? "hello160: PASS\n" : "hello160: FAIL\n");
    print("hello160 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
