/// hello135: signal call argument and errno rules.

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
#define SYS_SOCKETPAIR 53
#define SYS_NANOSLEEP 35
#define SYS_CLOCK_GETTIME 228
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_RECVFROM  122
#define SYS_SENDMSG   129
#define SYS_RECVMSG   130
#define SYS_SETSOCKOPT 132
#define SYS_NETPOLL   104
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_RCVTIMEO 20
#define MSG_TRUNC 0x20
#define MSG_DONTWAIT 0x40
#define EAGAIN_ 11
#define EDESTADDRREQ_ 89

struct iov { void *base; uint64_t len; };
struct msghdr { void *name; uint32_t namelen, pad0; struct iov *iov; uint64_t iovlen; void *ctl; uint64_t ctllen; uint32_t flags, pad1; };
struct ts { int64_t s, n; };
struct tv { int64_t s, us; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello145:   ok   " : "hello145:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void zero(void *p, unsigned n) { volatile char *c = p; for (unsigned i = 0; i < n; i++) c[i] = 0; }
static int64_t now_ms(void) {
    struct ts t;
    syscall2(SYS_CLOCK_GETTIME, 1, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static void mk_addr(uint8_t *a, uint16_t port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = 0x00; a[1] = AF_INET;
    a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)(port & 0xff);
    a[4] = 127; a[7] = 1;
}
static int64_t udp_socket(uint16_t port) {
    int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
    uint8_t a[16];
    mk_addr(a, port);
    syscall3(SYS_BIND, (uint64_t)u, (uint64_t)a, 16);
    return u;
}

void _start(void) {
    print("hello145: UDP sendmsg/recvmsg and the AF_UNIX receive timeout\n");

    /* A: sendmsg gathers the iovecs into one datagram, recvmsg scatters it */
    {
        int64_t rx = udp_socket(24201);
        int64_t tx = udp_socket(24202);
        uint8_t dst[16];
        mk_addr(dst, 24201);
        struct iov v[2] = { { "hello, ", 7 }, { "world", 5 } };
        struct msghdr m;
        zero(&m, sizeof m);
        m.name = dst; m.namelen = 16; m.iov = v; m.iovlen = 2;
        check(syscall3(SYS_SENDMSG, (uint64_t)tx, (uint64_t)&m, 0) == 12, "A: sendmsg of two iovecs sends 12 bytes");
        syscall1(SYS_NETPOLL, 0);

        char a[5], b[16];
        zero(a, 5); zero(b, 16);
        struct iov rv[2] = { { a, 5 }, { b, 16 } };
        uint8_t src[16];
        zero(src, 16);
        struct msghdr r;
        zero(&r, sizeof r);
        r.name = src; r.namelen = 16; r.iov = rv; r.iovlen = 2;
        int64_t n = syscall3(SYS_RECVMSG, (uint64_t)rx, (uint64_t)&r, 0);
        check(n == 12, "A: recvmsg returns 12 bytes");
        check(a[0] == 'h' && a[4] == 'o' && b[0] == ',' && b[6] == 'd', "A: scattered across both iovecs in order");
        check(src[0] == AF_INET && src[1] == 0 && src[2] == (24202 >> 8) && src[3] == (24202 & 0xff), "A: msg_name carries the sender's address and port");
        check(src[4] == 127 && src[7] == 1, "A: from 127.0.0.1");
        check(r.namelen == 16, "A: and msg_namelen is sizeof(sockaddr_in)");
        check((r.flags & MSG_TRUNC) == 0, "A: msg_flags has no MSG_TRUNC");
        check(r.ctllen == 0, "A: msg_controllen is 0");
        syscall1(SYS_CLOSE, rx);
        syscall1(SYS_CLOSE, tx);
    }

    /* B: a short buffer truncates and says so */
    {
        int64_t rx = udp_socket(24203);
        int64_t tx = udp_socket(24204);
        uint8_t dst[16];
        mk_addr(dst, 24203);
        struct iov v = { "0123456789", 10 };
        struct msghdr m;
        zero(&m, sizeof m);
        m.name = dst; m.namelen = 16; m.iov = &v; m.iovlen = 1;
        syscall3(SYS_SENDMSG, (uint64_t)tx, (uint64_t)&m, 0);
        syscall1(SYS_NETPOLL, 0);
        char small[4];
        struct iov rv = { small, 4 };
        struct msghdr r;
        zero(&r, sizeof r);
        r.iov = &rv; r.iovlen = 1;
        int64_t n = syscall3(SYS_RECVMSG, (uint64_t)rx, (uint64_t)&r, 0);
        check(n == 4 && small[0] == '0' && small[3] == '3', "B: a 4-byte buffer gets the first 4 bytes");
        check((r.flags & MSG_TRUNC) != 0, "B: and msg_flags has MSG_TRUNC");
        syscall3(SYS_SENDMSG, (uint64_t)tx, (uint64_t)&m, 0);
        syscall1(SYS_NETPOLL, 0);
        zero(&r, sizeof r);
        r.iov = &rv; r.iovlen = 1;
        n = syscall3(SYS_RECVMSG, (uint64_t)rx, (uint64_t)&r, MSG_TRUNC);
        check(n == 10, "B: with MSG_TRUNC the return value is the full datagram length");
        syscall1(SYS_CLOSE, rx);
        syscall1(SYS_CLOSE, tx);
    }

    /* C: errors */
    {
        int64_t tx = udp_socket(24205);
        struct iov v = { "x", 1 };
        struct msghdr m;
        zero(&m, sizeof m);
        m.iov = &v; m.iovlen = 1;
        check(syscall3(SYS_SENDMSG, (uint64_t)tx, (uint64_t)&m, 0) == -EDESTADDRREQ_, "C: sendmsg with no destination on an unconnected socket is EDESTADDRREQ");
        char b[8];
        struct iov rv = { b, 8 };
        struct msghdr r;
        zero(&r, sizeof r);
        r.iov = &rv; r.iovlen = 1;
        check(syscall3(SYS_RECVMSG, (uint64_t)tx, (uint64_t)&r, MSG_DONTWAIT) == -EAGAIN_, "C: recvmsg(MSG_DONTWAIT) on an empty queue is EAGAIN");
        struct tv t = { 0, 120000 };
        syscall5(SYS_SETSOCKOPT, (uint64_t)tx, SOL_SOCKET, SO_RCVTIMEO, (uint64_t)&t, 16);
        int64_t t0 = now_ms();
        int64_t n = syscall3(SYS_RECVMSG, (uint64_t)tx, (uint64_t)&r, 0);
        int64_t dt = now_ms() - t0;
        check(n == -EAGAIN_ && dt >= 90 && dt < 600, "C: recvmsg honours SO_RCVTIMEO");
        syscall1(SYS_CLOSE, tx);
    }

    /* D: AF_UNIX receive timeout and non-blocking mode */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        struct tv t = { 0, 150000 };
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)sv[0], SOL_SOCKET, SO_RCVTIMEO, (uint64_t)&t, 16) == 0, "D: set SO_RCVTIMEO on a socketpair end");
        char b[8];
        int64_t t0 = now_ms();
        int64_t n = syscall6(SYS_RECVFROM, (uint64_t)sv[0], (uint64_t)b, 8, 0, 0, 0);
        int64_t dt = now_ms() - t0;
        check(n == -EAGAIN_, "D: a timed-out AF_UNIX receive is EAGAIN");
        check(dt >= 120 && dt < 600, "D: after about 150 ms");
        syscall3(SYS_WRITE, sv[1], (uint64_t)"ok", 2);
        t0 = now_ms();
        n = syscall6(SYS_RECVFROM, (uint64_t)sv[0], (uint64_t)b, 8, 0, 0, 0);
        check(n == 2 && now_ms() - t0 < 100, "D: data that is already queued returns at once");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    print(failures == 0 ? "hello145: PASS\n" : "hello145: FAIL\n");
    print("hello145 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
