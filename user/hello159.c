/// hello159: AF_UNIX EPOLLRDHUP and POLLRDHUP.

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
#define SYS_SOCKETPAIR 53
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
#define AF_UNIX 1
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
    print(ok ? "hello159:   ok   " : "hello159:   FAIL ");
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

static void pump(int ms) {
    for (int i = 0; i < ms; i += 10) sleep_ms(10);
}
static int revents_of(int fd, int events) {
    struct pollfd p = { fd, (int16_t)events, 0 };
    syscall3(SYS_POLL, (uint64_t)&p, 1, 0);
    return p.revents;
}
static int ep_events(int fd, int events) {
    int64_t ep = syscall1(SYS_EPOLL_CREATE1, 0);
    struct epev ev = { (uint32_t)events, 1 }, out = { 0, 0 };
    syscall4(SYS_EPOLL_CTL, (uint64_t)ep, 1, (uint64_t)fd, (uint64_t)&ev);
    int64_t n = syscall4(SYS_EPOLL_WAIT, (uint64_t)ep, (uint64_t)&out, 1, 0);
    syscall1(SYS_CLOSE, (uint64_t)ep);
    return n == 1 ? (int)out.events : 0;
}

void _start(void) {
    print("hello159: AF_UNIX EPOLLRDHUP and POLLRDHUP\n");

    /* A: an idle pair reports no RDHUP */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        check((ep_events(sv[0], EPOLLIN | EPOLLRDHUP) & (EPOLLIN | EPOLLRDHUP)) == 0, "A: an idle pair reports neither EPOLLIN nor EPOLLRDHUP");
        check((revents_of(sv[0], POLLIN | POLLRDHUP) & POLLRDHUP) == 0, "A: and no POLLRDHUP");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* B: the peer's SHUT_WR */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        syscall2(SYS_SHUTDOWN, sv[1], SHUT_WR);
        int e = ep_events(sv[0], EPOLLIN | EPOLLRDHUP);
        check((e & EPOLLRDHUP) != 0, "B: after the peer's SHUT_WR epoll reports EPOLLRDHUP");
        check((e & EPOLLIN) != 0, "B: with EPOLLIN (the EOF is readable)");
        check((revents_of(sv[0], POLLIN | POLLRDHUP) & POLLRDHUP) != 0, "B: poll reports POLLRDHUP");
        check((ep_events(sv[0], EPOLLIN) & EPOLLRDHUP) == 0, "B: RDHUP is only reported when requested");
        /* our own SHUT_WR does not make *us* see RDHUP */
        check((ep_events(sv[1], EPOLLIN | EPOLLRDHUP) & EPOLLRDHUP) == 0, "B: the end that shut down does not see RDHUP itself");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* C: the peer closed */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        syscall1(SYS_CLOSE, sv[1]);
        int e = ep_events(sv[0], EPOLLIN | EPOLLRDHUP);
        check((e & EPOLLRDHUP) != 0, "C: after the peer closed epoll reports EPOLLRDHUP");
        check((revents_of(sv[0], POLLRDHUP) & POLLRDHUP) != 0, "C: and poll POLLRDHUP");
        syscall1(SYS_CLOSE, sv[0]);
    }

    print(failures == 0 ? "hello159: PASS\n" : "hello159: FAIL\n");
    print("hello159 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
