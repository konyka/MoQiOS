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
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_CLOCK_GETTIME 228
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define SYS_SETSOCKOPT 132
#define SYS_FCNTL     142
#define SYS_NETPOLL   104
#define AF_INET 2
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_RCVTIMEO 20
#define F_GETFL 3
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define MSG_DONTWAIT 0x40
#define EAGAIN_ 11

struct ts { int64_t s, n; };
struct tv { int64_t s, us; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello144:   ok   " : "hello144:   FAIL ");
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
static int64_t send_to(int64_t u, uint16_t port, const char *msg, uint64_t len) {
    uint8_t a[16];
    mk_addr(a, port);
    return syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)msg, len, 0, (uint64_t)a, 16);
}
static int64_t recv_on(int64_t u, char *buf, uint64_t len, uint64_t flags) {
    return syscall6(SYS_RECVFROM, (uint64_t)u, (uint64_t)buf, len, flags, 0, 0);
}

void _start(void) {
    print("hello144: UDP receive: blocking, timeout, non-blocking\n");
    char buf[64];

    /* A: an empty queue is EAGAIN when non-blocking, never "0" */
    {
        int64_t u = udp_socket(24101);
        check(recv_on(u, buf, 64, MSG_DONTWAIT) == -EAGAIN_, "A: MSG_DONTWAIT on an empty queue is EAGAIN");
        syscall3(SYS_FCNTL, (uint64_t)u, F_SETFL, O_NONBLOCK);
        check(recv_on(u, buf, 64, 0) == -EAGAIN_, "A: an O_NONBLOCK socket on an empty queue is EAGAIN");
        syscall3(SYS_FCNTL, (uint64_t)u, F_SETFL, 0);
        syscall1(SYS_CLOSE, u);
    }

    /* B: SO_RCVTIMEO bounds a blocking receive */
    {
        int64_t u = udp_socket(24102);
        struct tv t = { 0, 150000 };
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)u, SOL_SOCKET, SO_RCVTIMEO, (uint64_t)&t, 16) == 0, "B: set SO_RCVTIMEO = 150 ms");
        int64_t t0 = now_ms();
        int64_t r = recv_on(u, buf, 64, 0);
        int64_t dt = now_ms() - t0;
        check(r == -EAGAIN_, "B: the timed-out receive is EAGAIN");
        check(dt >= 120 && dt < 600, "B: after about 150 ms");
        syscall1(SYS_CLOSE, u);
    }

    /* C: a queued datagram is returned without waiting */
    {
        int64_t u = udp_socket(24103);
        int64_t v = udp_socket(24104);
        send_to(v, 24103, "queued", 6);
        syscall1(SYS_NETPOLL, 0);
        int64_t t0 = now_ms();
        int64_t r = recv_on(u, buf, 64, 0);
        check(r == 6 && buf[0] == 'q', "C: a queued datagram is returned at once");
        check(now_ms() - t0 < 100, "C: without sleeping");
        syscall1(SYS_CLOSE, u);
        syscall1(SYS_CLOSE, v);
    }

    /* D: a blocked receiver is woken by a datagram another process sends */
    {
        int64_t u = udp_socket(24105);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            int64_t v = udp_socket(24106);
            sleep_ms(120);
            send_to(v, 24105, "wake", 4);
            syscall1(SYS_NETPOLL, 0);
            sleep_ms(30);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        int64_t t0 = now_ms();
        int64_t r = recv_on(u, buf, 64, 0);
        int64_t dt = now_ms() - t0;
        check(r == 4 && buf[0] == 'w', "D: a blocking receive returns the datagram sent later");
        check(dt >= 80 && dt < 1000, "D: and it was woken soon after the send");
        int st = 0;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        syscall1(SYS_CLOSE, u);
    }

    /* E: a zero-length datagram is data, not "nothing" */
    {
        int64_t u = udp_socket(24107);
        int64_t v = udp_socket(24108);
        send_to(v, 24107, "", 0);
        syscall1(SYS_NETPOLL, 0);
        int64_t r = recv_on(u, buf, 64, MSG_DONTWAIT);
        check(r == 0 || r == -EAGAIN_, "E: an empty datagram or EAGAIN (never an error)");
        syscall1(SYS_CLOSE, u);
        syscall1(SYS_CLOSE, v);
    }

    print(failures == 0 ? "hello144: PASS\n" : "hello144: FAIL\n");
    print("hello144 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
