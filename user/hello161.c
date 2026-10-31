/// hello161: UDP port unreachable on loopback.

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
#define SYS_CLOSE     11
#define SYS_NANOSLEEP 35
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_CONNECT   124
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define SYS_GETSOCKOPT 133
#define SYS_FCNTL     142
#define SYS_POLL      162
#define SYS_CLOCK_GETTIME 228
#define AF_INET 2
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_ERROR 4
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define MSG_DONTWAIT 0x40
#define POLLIN  0x001
#define POLLOUT 0x004
#define POLLERR 0x008
#define ECONNREFUSED_ 111
#define EAGAIN_ 11

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
    print(ok ? "hello161:   ok   " : "hello161:   FAIL ");
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
    for (int i = 0; i < ms; i += 10) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); }
}
static int so_error(int fd) {
    int v = -1;
    uint32_t len = 4;
    if (syscall5(SYS_GETSOCKOPT, (uint64_t)fd, SOL_SOCKET, SO_ERROR, (uint64_t)&v, (uint64_t)&len) != 0) return -999;
    return v;
}
static int revents_of(int fd, int events) {
    struct pollfd p = { fd, (int16_t)events, 0 };
    syscall3(SYS_POLL, (uint64_t)&p, 1, 0);
    return p.revents;
}

void _start(void) {
    print("hello161: UDP port unreachable on loopback\n");
    uint8_t dead[16];
    mk_addr(dead, 24999); /* nobody is bound here */
    char b[16];

    /* A: a connected UDP socket learns that the port is closed */
    {
        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        uint8_t me[16];
        mk_addr(me, 24990);
        syscall3(SYS_BIND, (uint64_t)u, (uint64_t)me, 16);
        check(syscall3(SYS_CONNECT, (uint64_t)u, (uint64_t)dead, 16) == 0, "A: connect() on a UDP socket succeeds");
        syscall3(SYS_FCNTL, (uint64_t)u, F_SETFL, O_NONBLOCK);
        check(syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)"ping", 4, 0, 0, 0) == 4, "A: the first send is accepted");
        pump(100);
        check((revents_of((int)u, POLLIN) & POLLERR) != 0, "A: poll reports POLLERR after the port-unreachable");
        int64_t r = syscall6(SYS_RECVFROM, (uint64_t)u, (uint64_t)b, 16, 0, 0, 0);
        check(r == -ECONNREFUSED_, "A: the next recv reports ECONNREFUSED");
        check(syscall6(SYS_RECVFROM, (uint64_t)u, (uint64_t)b, 16, 0, 0, 0) == -EAGAIN_, "A: and the error is delivered once");
        syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)"ping", 4, 0, 0, 0);
        pump(100);
        check(so_error((int)u) == ECONNREFUSED_, "A: SO_ERROR reports ECONNREFUSED");
        check(so_error((int)u) == 0, "A: and clears it");
        syscall1(SYS_CLOSE, u);
    }

    /* A2: the error also fails the next send, once */
    {
        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        uint8_t me[16];
        mk_addr(me, 24993);
        syscall3(SYS_BIND, (uint64_t)u, (uint64_t)me, 16);
        syscall3(SYS_CONNECT, (uint64_t)u, (uint64_t)dead, 16);
        syscall3(SYS_FCNTL, (uint64_t)u, F_SETFL, O_NONBLOCK);
        syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)"ping", 4, 0, 0, 0);
        pump(100);
        check(syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)"ping", 4, 0, 0, 0) == -ECONNREFUSED_, "A2: the next send reports ECONNREFUSED");
        check(syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)"ping", 4, 0, 0, 0) == 4, "A2: and the one after is accepted again");
        syscall1(SYS_CLOSE, u);
    }

    /* B: an unconnected socket is not told (Linux does not report it either) */
    {
        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        uint8_t me[16];
        mk_addr(me, 24991);
        syscall3(SYS_BIND, (uint64_t)u, (uint64_t)me, 16);
        syscall3(SYS_FCNTL, (uint64_t)u, F_SETFL, O_NONBLOCK);
        syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)"ping", 4, 0, (uint64_t)dead, 16);
        pump(100);
        check(syscall6(SYS_RECVFROM, (uint64_t)u, (uint64_t)b, 16, 0, 0, 0) == -EAGAIN_, "B: an unconnected socket just sees an empty queue (EAGAIN)");
        check(so_error((int)u) == 0, "B: and no SO_ERROR");
        syscall1(SYS_CLOSE, u);
    }

    /* C: a bound destination still works and clears nothing */
    {
        int64_t srv = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        uint8_t sa[16];
        mk_addr(sa, 24992);
        syscall3(SYS_BIND, (uint64_t)srv, (uint64_t)sa, 16);
        int64_t cli = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        syscall3(SYS_CONNECT, (uint64_t)cli, (uint64_t)sa, 16);
        syscall3(SYS_FCNTL, (uint64_t)srv, F_SETFL, O_NONBLOCK);
        check(syscall6(SYS_SENDTO, (uint64_t)cli, (uint64_t)"hi", 2, 0, 0, 0) == 2, "C: send to a bound port");
        pump(100);
        check(syscall6(SYS_RECVFROM, (uint64_t)srv, (uint64_t)b, 16, 0, 0, 0) == 2, "C: is delivered");
        check(so_error((int)cli) == 0, "C: and no error is recorded on the sender");
        syscall1(SYS_CLOSE, cli);
        syscall1(SYS_CLOSE, srv);
    }

    print(failures == 0 ? "hello161: PASS\n" : "hello161: FAIL\n");
    print("hello161 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
