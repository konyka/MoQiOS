/// hello173: ioctl(TIOCOUTQ/SIOCOUTQ) reports the bytes a socket has sent that the peer has not consumed.

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
#define SYS_SOCKETPAIR 53
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_FCNTL     142
#define SYS_IOCTL     165
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define TIOCOUTQ 0x5411
#define FIONREAD 0x541B
#define EAGAIN_ 11
#define ENOTTY_ 25

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello173:   ok   " : "hello173:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t now_ms(void) {
    struct ts t;
    syscall2(228, 1, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static void pump(int ms) {
    for (int i = 0; i < ms; i += 10) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); }
}
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
static int outq(int fd) {
    int v = -12345;
    int64_t r = syscall3(SYS_IOCTL, (uint64_t)fd, TIOCOUTQ, (uint64_t)&v);
    return r == 0 ? v : -1000000 + (int)r;
}

void _start(void) {
    print("hello173: ioctl(TIOCOUTQ) on sockets\n");
    static char buf[4096];
    for (int i = 0; i < 4096; i++) buf[i] = (char)i;

    /* A: AF_UNIX stream: what the writer queued and the reader has not consumed */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        check(outq(sv[0]) == 0, "A: an idle unix stream socket has nothing queued");
        syscall3(SYS_WRITE, sv[0], (uint64_t)buf, 100);
        check(outq(sv[0]) == 100, "A: after writing 100 bytes the writer reports 100");
        check(outq(sv[1]) == 0, "A: the reader's own send queue is empty");
        syscall3(SYS_READ, sv[1], (uint64_t)buf, 40);
        check(outq(sv[0]) == 60, "A: after the reader consumed 40, 60 remain");
        syscall3(SYS_READ, sv[1], (uint64_t)buf, 60);
        check(outq(sv[0]) == 0, "A: and 0 once everything was read");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* B: AF_UNIX datagram */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_DGRAM, 0, (uint64_t)sv);
        syscall3(SYS_WRITE, sv[0], (uint64_t)buf, 30);
        syscall3(SYS_WRITE, sv[0], (uint64_t)buf, 20);
        check(outq(sv[0]) >= 50, "B: unread datagram bytes are counted (>= 50)");
        syscall3(SYS_READ, sv[1], (uint64_t)buf, 64);
        syscall3(SYS_READ, sv[1], (uint64_t)buf, 64);
        check(outq(sv[0]) == 0, "B: and none once both were read");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* C: TCP: an idle connection has nothing queued; with the peer not reading, the unsent/unacked rest stays queued */
    {
        int c, s;
        check(make_pair(18173, &c, &s) == 0, "C: loopback connection");
        check(outq(c) == 0, "C: an idle TCP socket has nothing queued");
        syscall3(SYS_WRITE, c, (uint64_t)buf, 100);
        pump(400);
        check(outq(c) == 0, "C: a small write is acknowledged and the queue drains");
        syscall3(SYS_FCNTL, (uint64_t)c, F_SETFL, O_NONBLOCK);
        long total = 0;
        for (int i = 0; i < 400; i++) {
            int64_t w = syscall3(SYS_WRITE, c, (uint64_t)buf, 4096);
            if (w <= 0) break;
            total += w;
            if ((i % 8) == 7) pump(10);
        }
        pump(200);
        int q = outq(c);
        check(q > 0, "C: with the peer not reading, unacknowledged data stays queued (> 0)");
        check(q <= total, "C: and never exceeds what was written");
        /* drain the peer so everything is delivered and acknowledged */
        long got = 0;
        syscall3(SYS_FCNTL, (uint64_t)s, F_SETFL, O_NONBLOCK);
        int64_t t0 = now_ms();
        while (got < total + 100 && now_ms() - t0 < 20000) { /* +100: the earlier small write */
            int64_t r = syscall3(SYS_READ, s, (uint64_t)buf, 4096);
            if (r > 0) { got += r; }
            else pump(10);
        }
        check(got >= total + 100, "C: the peer receives everything that was written, promptly (< 20 s)");
        for (int i = 0; i < 40 && outq(c) != 0; i++) pump(50);
        check(outq(c) == 0, "C: once the peer read everything the queue is empty");
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    /* D: other descriptors are not sockets */
    {
        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        int v = -1;
        int64_t r = syscall3(SYS_IOCTL, (uint64_t)u, TIOCOUTQ, (uint64_t)&v);
        check(r == 0 && v == 0, "D: a UDP socket answers 0");
        syscall1(SYS_CLOSE, u);
        v = -1;
        check(syscall3(SYS_IOCTL, 1, TIOCOUTQ, (uint64_t)&v) == -ENOTTY_, "D: stdout is ENOTTY");
    }

    print(failures == 0 ? "hello173: PASS\n" : "hello173: FAIL\n");
    print("hello173 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
