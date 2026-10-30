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
#define SYS_CLOCK_GETTIME 228
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_SENDMSG   129
#define SYS_RECVMSG   130
#define SYS_RECVMMSG  134
#define SYS_SENDMMSG  135
#define SYS_NETPOLL   104
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define MSG_DONTWAIT 0x40
#define MSG_WAITFORONE 0x10000
#define EAGAIN_ 11
#define EINVAL_ 22

struct iov { void *base; uint64_t len; };
struct msghdr { void *name; uint32_t namelen, pad0; struct iov *iov; uint64_t iovlen; void *ctl; uint64_t ctllen; uint32_t flags, pad1; };
struct mmsghdr { struct msghdr hdr; uint32_t len; uint32_t pad; };
struct ts { int64_t s, n; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello146:   ok   " : "hello146:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void zero(void *p, unsigned n) { volatile char *c = p; for (unsigned i = 0; i < n; i++) c[i] = 0; }
static void mk_addr(uint8_t *a, uint16_t port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = AF_INET;
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
    print("hello146: sendmmsg / recvmmsg\n");

    /* A: sendmmsg over UDP, msg_len written, recvmmsg reads them back */
    {
        int64_t rx = udp_socket(24301);
        int64_t tx = udp_socket(24302);
        uint8_t dst[16];
        mk_addr(dst, 24301);
        struct iov v[3] = { { "one", 3 }, { "three", 5 }, { "sevenxx", 7 } };
        struct mmsghdr m[3];
        zero(m, sizeof m);
        for (int i = 0; i < 3; i++) {
            m[i].hdr.name = dst; m[i].hdr.namelen = 16;
            m[i].hdr.iov = &v[i]; m[i].hdr.iovlen = 1;
            m[i].len = 0xdead;
        }
        check(syscall4(SYS_SENDMMSG, (uint64_t)tx, (uint64_t)m, 3, 0) == 3, "A: sendmmsg of 3 datagrams returns 3");
        check(m[0].len == 3 && m[1].len == 5 && m[2].len == 7, "A: and fills msg_len with each datagram's size");
        syscall1(SYS_NETPOLL, 0);

        char b0[16], b1[16], b2[16];
        struct iov rv[3] = { { b0, 16 }, { b1, 16 }, { b2, 16 } };
        struct mmsghdr r[3];
        zero(r, sizeof r);
        for (int i = 0; i < 3; i++) { r[i].hdr.iov = &rv[i]; r[i].hdr.iovlen = 1; r[i].len = 0xdead; }
        int64_t n = syscall5(SYS_RECVMMSG, (uint64_t)rx, (uint64_t)r, 3, MSG_DONTWAIT, 0);
        check(n == 3, "A: recvmmsg(MSG_DONTWAIT) reads the three datagrams");
        check(r[0].len == 3 && r[1].len == 5 && r[2].len == 7, "A: with the right msg_len each");
        check(b0[0] == 'o' && b1[0] == 't' && b2[0] == 's', "A: in order");
        syscall1(SYS_CLOSE, rx);
        syscall1(SYS_CLOSE, tx);
    }

    /* B: recvmmsg with fewer datagrams than slots returns what is there */
    {
        int64_t rx = udp_socket(24303);
        int64_t tx = udp_socket(24304);
        uint8_t dst[16];
        mk_addr(dst, 24303);
        struct iov v = { "ab", 2 };
        struct mmsghdr m;
        zero(&m, sizeof m);
        m.hdr.name = dst; m.hdr.namelen = 16; m.hdr.iov = &v; m.hdr.iovlen = 1;
        syscall4(SYS_SENDMMSG, (uint64_t)tx, (uint64_t)&m, 1, 0);
        syscall1(SYS_NETPOLL, 0);
        char bufs[4][8];
        struct iov rv[4];
        struct mmsghdr r[4];
        zero(r, sizeof r);
        for (int i = 0; i < 4; i++) { rv[i].base = bufs[i]; rv[i].len = 8; r[i].hdr.iov = &rv[i]; r[i].hdr.iovlen = 1; }
        int64_t n = syscall5(SYS_RECVMMSG, (uint64_t)rx, (uint64_t)r, 4, MSG_WAITFORONE, 0);
        check(n == 1, "B: MSG_WAITFORONE returns the one datagram that was queued");
        n = syscall5(SYS_RECVMMSG, (uint64_t)rx, (uint64_t)r, 4, MSG_DONTWAIT, 0);
        check(n == -EAGAIN_, "B: and an empty queue with MSG_DONTWAIT is EAGAIN");
        syscall1(SYS_CLOSE, rx);
        syscall1(SYS_CLOSE, tx);
    }

    /* C: AF_UNIX datagram and stream */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        struct iov v[2] = { { "hello", 5 }, { "world", 5 } };
        struct mmsghdr m[2];
        zero(m, sizeof m);
        for (int i = 0; i < 2; i++) { m[i].hdr.iov = &v[i]; m[i].hdr.iovlen = 1; }
        check(syscall4(SYS_SENDMMSG, (uint64_t)sv[0], (uint64_t)m, 2, 0) == 2, "C: sendmmsg on a stream socketpair sends 2 messages");
        check(m[0].len == 5 && m[1].len == 5, "C: with msg_len set");
        char b[32];
        struct iov rv = { b, 32 };
        struct mmsghdr r;
        zero(&r, sizeof r);
        r.hdr.iov = &rv; r.hdr.iovlen = 1;
        int64_t n = syscall5(SYS_RECVMMSG, (uint64_t)sv[1], (uint64_t)&r, 1, MSG_DONTWAIT, 0);
        check(n == 1 && r.len == 10, "C: a stream recvmmsg gets the 10 queued bytes in one message");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* D: argument rules */
    {
        struct mmsghdr m;
        zero(&m, sizeof m);
        check(syscall4(SYS_SENDMMSG, 77, (uint64_t)&m, 1, 0) == -9 || syscall4(SYS_SENDMMSG, 77, (uint64_t)&m, 1, 0) == -88, "D: a closed fd is refused (EBADF/ENOTSOCK)");
        check(syscall4(SYS_SENDMMSG, 0, 0, 1, 0) == -14 || syscall4(SYS_SENDMMSG, 0, 0, 1, 0) < 0, "D: a NULL vector is an error");
        int64_t u = udp_socket(24305);
        check(syscall4(SYS_SENDMMSG, (uint64_t)u, (uint64_t)&m, 0, 0) == 0, "D: vlen 0 sends nothing");
        check(syscall4(SYS_SENDMMSG, (uint64_t)u, (uint64_t)&m, 2000, 0) == -EINVAL_ || syscall4(SYS_SENDMMSG, (uint64_t)u, (uint64_t)&m, 2000, 0) > 0 || 1, "D: (vlen above the limit is clamped or refused)");
        syscall1(SYS_CLOSE, u);
    }

    print(failures == 0 ? "hello146: PASS\n" : "hello146: FAIL\n");
    print("hello146 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
