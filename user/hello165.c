/// hello165: MSG_PEEK / MSG_WAITALL / MSG_TRUNC on stream and datagram sockets.

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
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_SOCKETPAIR 53
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_CLOCK_GETTIME 228
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define MSG_PEEK 0x2
#define MSG_TRUNC 0x20
#define MSG_DONTWAIT 0x40
#define MSG_WAITALL 0x100
struct ts { int64_t s, n; };
struct tv { int64_t s, us; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello165:   ok   " : "hello165:   FAIL ");
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
static int64_t rcv(int fd, char *b, int n, int flags) {
    return syscall6(SYS_RECVFROM, (uint64_t)fd, (uint64_t)b, (uint64_t)n, (uint64_t)flags, 0, 0);
}
static int64_t snd(int fd, const char *b, int n) {
    return syscall6(SYS_SENDTO, (uint64_t)fd, (uint64_t)b, (uint64_t)n, 0, 0, 0);
}

static void stream_peek(const char *tag, int rfd, int wfd, int net) {
    char b[32];
    char name[96];
    (void)name;
    snd(wfd, "peekdata", 8);
    if (net) pump(100);
    int64_t n = rcv(rfd, b, 4, MSG_PEEK | MSG_DONTWAIT);
    check(n == 4 && b[0] == 'p' && b[3] == 'k', tag);
    n = rcv(rfd, b, 32, MSG_PEEK | MSG_DONTWAIT);
    check(n == 8, "   a second peek still sees all 8 bytes (peek does not consume)");
    n = rcv(rfd, b, 32, MSG_DONTWAIT);
    check(n == 8 && b[0] == 'p', "   a normal read afterwards returns them");
    n = rcv(rfd, b, 32, MSG_DONTWAIT);
    check(n < 0, "   and then the queue is empty");
}

void _start(void) {
    print("hello165: MSG_PEEK / MSG_WAITALL / MSG_TRUNC\n");
    char b[64];

    /* A: AF_UNIX stream */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        stream_peek("A: AF_UNIX stream: MSG_PEEK returns data without consuming it", sv[1], sv[0], 0);
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* B: AF_UNIX datagram: peek, and MSG_TRUNC reports the real size */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_DGRAM, 0, (uint64_t)sv);
        snd(sv[0], "0123456789", 10);
        int64_t n = rcv(sv[1], b, 4, MSG_PEEK | MSG_DONTWAIT);
        check(n == 4 && b[0] == '0', "B: AF_UNIX datagram: MSG_PEEK returns the head of the message");
        n = rcv(sv[1], b, 4, MSG_TRUNC | MSG_DONTWAIT);
        check(n == 10, "B: MSG_TRUNC returns the real datagram length (10) although only 4 bytes fit");
        n = rcv(sv[1], b, 32, MSG_DONTWAIT);
        check(n < 0, "B: and the datagram was consumed by that read");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* C: TCP */
    {
        int c, s;
        check(make_pair(18165, &c, &s) == 0, "C: loopback connection");
        stream_peek("C: TCP: MSG_PEEK returns data without consuming it", s, c, 1);
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    /* D: MSG_WAITALL waits for the whole request (AF_UNIX stream and TCP) */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            syscall1(SYS_CLOSE, sv[1]);
            sleep_ms(60);
            snd(sv[0], "abc", 3);
            sleep_ms(60);
            snd(sv[0], "defgh", 5);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        syscall1(SYS_CLOSE, sv[0]);
        int64_t n = rcv(sv[1], b, 8, MSG_WAITALL);
        check(n == 8 && b[0] == 'a' && b[7] == 'h', "D: AF_UNIX stream: MSG_WAITALL returns all 8 bytes although they arrive in two pieces");
        int st;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        syscall1(SYS_CLOSE, sv[1]);
    }
    {
        int c, s;
        make_pair(18166, &c, &s);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            syscall1(SYS_CLOSE, s);
            sleep_ms(60);
            snd(c, "abc", 3);
            pump(80);
            snd(c, "defgh", 5);
            pump(100);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        syscall1(SYS_CLOSE, c);
        int64_t n = rcv(s, b, 8, MSG_WAITALL);
        check(n == 8 && b[0] == 'a' && b[7] == 'h', "D: TCP: MSG_WAITALL returns all 8 bytes although they arrive in two pieces");
        int st;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        syscall1(SYS_CLOSE, s);
    }

    /* E: MSG_WAITALL returns what it has when the peer closes early */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        snd(sv[0], "xy", 2);
        syscall1(SYS_CLOSE, sv[0]);
        int64_t n = rcv(sv[1], b, 8, MSG_WAITALL);
        check(n == 2, "E: MSG_WAITALL gives the 2 bytes there are once the peer has closed (no hang)");
        syscall1(SYS_CLOSE, sv[1]);
    }

    print(failures == 0 ? "hello165: PASS\n" : "hello165: FAIL\n");
    print("hello165 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
