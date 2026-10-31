/// hello163: socketpair(AF_UNIX, SOCK_DGRAM).

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
#define SYS_SOCKETPAIR 53
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define SYS_FCNTL     142
#define SYS_CLOCK_GETTIME 228
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_NONBLOCK 0x800
#define SOCK_CLOEXEC 0x80000
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define MSG_DONTWAIT 0x40
#define MSG_TRUNC 0x20
#define EAGAIN_ 11
#define EINVAL_ 22

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello163:   ok   " : "hello163:   FAIL ");
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

void _start(void) {
    print("hello163: socketpair(AF_UNIX, SOCK_DGRAM)\n");
    char b[64];

    int sv[2];
    int64_t r = syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_DGRAM, 0, (uint64_t)sv);
    check(r == 0, "A: socketpair(AF_UNIX, SOCK_DGRAM) succeeds");
    if (r != 0) goto done;

    /* B: message boundaries are preserved, in both directions */
    check(syscall3(SYS_WRITE, sv[0], (uint64_t)"one", 3) == 3, "B: write(\"one\") on end 0");
    check(syscall3(SYS_WRITE, sv[0], (uint64_t)"three", 5) == 5, "B: write(\"three\") on end 0");
    check(syscall3(SYS_READ, sv[1], (uint64_t)b, 64) == 3 && b[0] == 'o', "B: the first read returns exactly one message (3 bytes)");
    check(syscall3(SYS_READ, sv[1], (uint64_t)b, 64) == 5 && b[0] == 't', "B: the second read returns the next message (5 bytes)");
    check(syscall3(SYS_WRITE, sv[1], (uint64_t)"back", 4) == 4, "B: the other direction works");
    check(syscall3(SYS_READ, sv[0], (uint64_t)b, 64) == 4, "B: and is received on end 0");

    /* C: a short buffer truncates the message, the rest is dropped */
    syscall3(SYS_WRITE, sv[0], (uint64_t)"abcdefgh", 8);
    check(syscall3(SYS_READ, sv[1], (uint64_t)b, 3) == 3, "C: reading 3 bytes of an 8-byte message returns 3");
    syscall3(SYS_FCNTL, (uint64_t)sv[1], F_SETFL, O_NONBLOCK);
    check(syscall3(SYS_READ, sv[1], (uint64_t)b, 64) == -EAGAIN_, "C: the unread remainder is discarded, not delivered later");

    /* D: an empty queue is EAGAIN when non-blocking */
    check(syscall6(SYS_RECVFROM, (uint64_t)sv[1], (uint64_t)b, 64, MSG_DONTWAIT, 0, 0) == -EAGAIN_, "D: recv on an empty queue is EAGAIN");

    /* E: flags and a zero-length message */
    syscall1(SYS_CLOSE, sv[0]);
    syscall1(SYS_CLOSE, sv[1]);
    int64_t r2 = syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, (uint64_t)sv);
    check(r2 == 0, "E: SOCK_DGRAM|SOCK_NONBLOCK|SOCK_CLOEXEC is accepted");
    check(syscall3(SYS_READ, sv[0], (uint64_t)b, 64) == -EAGAIN_, "E: SOCK_NONBLOCK makes the new end non-blocking");
    check(syscall4(SYS_SOCKETPAIR, AF_UNIX, 3, 0, (uint64_t)sv) == -EINVAL_, "E: other socket types are still rejected (SOCK_RAW)");

    /* F: a blocked reader is woken by a datagram from the other end; a write
     * to a closed peer fails */
    {
        int pv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_DGRAM, 0, (uint64_t)pv);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            syscall1(SYS_CLOSE, pv[1]);
            char c[16];
            int64_t n = syscall3(SYS_READ, pv[0], (uint64_t)c, 16);
            syscall1(SYS_EXIT, (n == 4 && c[0] == 'w') ? 0 : 1);
            for (;;) {}
        }
        sleep_ms(80);
        syscall3(SYS_WRITE, pv[1], (uint64_t)"wake", 4);
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        check(st == 0, "F: a blocked read is woken by a datagram from the other end");
        syscall1(SYS_CLOSE, pv[0]);
        int64_t w = syscall6(SYS_SENDTO, (uint64_t)pv[1], (uint64_t)"x", 1, 0x4000, 0, 0);
        check(w < 0, "F: sending to a closed peer fails");
        syscall1(SYS_CLOSE, pv[1]);
    }

done:
    syscall1(SYS_CLOSE, sv[0]);
    syscall1(SYS_CLOSE, sv[1]);
    print(failures == 0 ? "hello163: PASS\n" : "hello163: FAIL\n");
    print("hello163 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
