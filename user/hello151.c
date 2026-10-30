/// hello151: read/write on TCP socket descriptors.

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
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SETSOCKOPT 132
#define SYS_FCNTL     142
#define SYS_CLOCK_GETTIME 228
#define AF_INET 2
#define SOCK_STREAM 1
#define SOL_SOCKET 1
#define SO_SNDTIMEO 21
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define EAGAIN_ 11
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
    print(ok ? "hello151:   ok   " : "hello151:   FAIL ");
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
static uint8_t big[BIG];
static uint8_t got[BIG];

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

void _start(void) {
    print("hello151: read/write on TCP socket descriptors\n");
    for (int i = 0; i < BIG; i++) big[i] = (uint8_t)(i * 13 + 5);

    /* A: write()/read() carry data like send()/recv() */
    {
        int c, s;
        check(make_pair(18151, &c, &s) == 0, "A: loopback connection");
        int64_t w = syscall3(SYS_WRITE, c, (uint64_t)"hello tcp", 9);
        check(w == 9, "A: write(2) on a TCP socket sends the bytes");
        char b[32];
        int64_t r = syscall3(SYS_READ, s, (uint64_t)b, 32);
        check(r == 9 && b[0] == 'h' && b[8] == 'p', "A: read(2) on the peer returns them");
        syscall3(SYS_FCNTL, (uint64_t)s, F_SETFL, O_NONBLOCK);
        check(syscall3(SYS_READ, s, (uint64_t)b, 32) == -EAGAIN_, "A: read on an O_NONBLOCK socket with no data is EAGAIN");
        syscall1(SYS_CLOSE, c);
        sleep_ms(30);
        syscall1(SYS_NETPOLL, 0);
        r = syscall3(SYS_READ, s, (uint64_t)b, 32);
        check(r == 0, "A: read after the peer closed is EOF (0)");
        syscall1(SYS_CLOSE, s);
    }

    /* B: a blocking write bigger than the send ring waits for the reader */
    {
        int c, s;
        check(make_pair(18152, &c, &s) == 0, "B: loopback connection");
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            syscall1(SYS_CLOSE, s);
            int64_t w = syscall3(SYS_WRITE, c, (uint64_t)big, BIG);
            syscall1(SYS_EXIT, w == BIG ? 0 : 1);
            for (;;) {}
        }
        syscall1(SYS_CLOSE, c);
        sleep_ms(60);
        int total = 0;
        int ok = 1;
        while (total < BIG) {
            int64_t n = syscall3(SYS_READ, s, (uint64_t)(got + total), (uint64_t)(BIG - total));
            if (n <= 0) { ok = 0; break; }
            total += (int)n;
        }
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        check(ok && total == BIG, "B: the reader receives all 300000 bytes");
        check(st == 0, "B: and the blocking write(300000) returned the full count");
        int same = 1;
        for (int i = 0; i < BIG && same; i++) if (got[i] != big[i]) same = 0;
        check(same, "B: with the bytes in order and intact");
        syscall1(SYS_CLOSE, s);
    }

    /* C: SO_SNDTIMEO bounds a write the peer never drains */
    {
        int c, s;
        check(make_pair(18153, &c, &s) == 0, "C: loopback connection");
        struct tv t = { 0, 200000 };
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)c, SOL_SOCKET, SO_SNDTIMEO, (uint64_t)&t, 16) == 0, "C: set SO_SNDTIMEO");
        int64_t t0 = now_ms();
        int64_t w = syscall3(SYS_WRITE, c, (uint64_t)big, BIG);
        int64_t dt = now_ms() - t0;
        check(w > 0 && w < BIG, "C: the write returns the bytes accepted so far");
        check(dt >= 150 && dt < 1500, "C: after about 200 ms");
        /* A write that finds only a little room reports those bytes after the
         * timeout; once nothing fits the next write is EAGAIN. */
        int64_t w2 = 0, dt2 = 0;
        for (int i = 0; i < 4000; i++) {
            t0 = now_ms();
            w2 = syscall3(SYS_WRITE, c, (uint64_t)big, 100);
            dt2 = now_ms() - t0;
            if (w2 <= 0) break;
        }
        check(w2 == -EAGAIN_ && dt2 >= 150 && dt2 < 1500, "C: with the buffers full a write is EAGAIN after the timeout");
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    print(failures == 0 ? "hello151: PASS\n" : "hello151: FAIL\n");
    print("hello151 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
