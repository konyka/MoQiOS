/// hello150: blocking AF_UNIX stream writes.

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
#define SYS_FCNTL     142
#define SYS_CLOCK_GETTIME 228
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define SYS_SETSOCKOPT 132
#define SOL_SOCKET 1
#define SO_SNDTIMEO 21
#define AF_UNIX 1
#define SOCK_STREAM 1
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define MSG_DONTWAIT 0x40
#define EAGAIN_ 11
#define EPIPE_ 32
#define BIG 30000

struct ts { int64_t s, n; };
struct tv { int64_t s, us; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello150:   ok   " : "hello150:   FAIL ");
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

void _start(void) {
    print("hello150: blocking AF_UNIX stream writes\n");
    for (int i = 0; i < BIG; i++) big[i] = (uint8_t)(i * 7 + 3);

    /* A: a write larger than the ring completes once the reader drains it */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            syscall1(SYS_CLOSE, sv[1]);
            int64_t w = syscall3(SYS_WRITE, sv[0], (uint64_t)big, BIG);
            syscall1(SYS_EXIT, w == BIG ? 0 : 1);
            for (;;) {}
        }
        syscall1(SYS_CLOSE, sv[0]);
        sleep_ms(60);
        int total = 0;
        int ok = 1;
        while (total < BIG) {
            int64_t n = syscall3(SYS_READ, sv[1], (uint64_t)(got + total), (uint64_t)(BIG - total));
            if (n <= 0) { ok = 0; break; }
            total += (int)n;
        }
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        check(ok && total == BIG, "A: the reader receives all 30000 bytes");
        check(st == 0, "A: and the blocking write(30000) returned the full count");
        int same = 1;
        for (int i = 0; i < BIG && same; i++) if (got[i] != big[i]) same = 0;
        check(same, "A: with the bytes in order and intact");
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* B: a non-blocking socket writes what fits, then reports EAGAIN */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        syscall3(SYS_FCNTL, (uint64_t)sv[0], F_SETFL, O_NONBLOCK);
        int64_t w1 = syscall3(SYS_WRITE, sv[0], (uint64_t)big, BIG);
        check(w1 > 0 && w1 < BIG, "B: a non-blocking write of 30000 is short (what fits in the ring)");
        int64_t w2 = syscall3(SYS_WRITE, sv[0], (uint64_t)big, 100);
        check(w2 == -EAGAIN_, "B: and the next write on the full ring is EAGAIN");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* C: MSG_DONTWAIT on a blocking socket does not wait */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        int64_t fill = syscall6(SYS_SENDTO, (uint64_t)sv[0], (uint64_t)big, BIG, MSG_DONTWAIT, 0, 0);
        check(fill > 0, "C: fill the ring with MSG_DONTWAIT");
        int64_t t0 = now_ms();
        int64_t r = syscall6(SYS_SENDTO, (uint64_t)sv[0], (uint64_t)big, 100, MSG_DONTWAIT, 0, 0);
        check(r == -EAGAIN_ && now_ms() - t0 < 100, "C: another MSG_DONTWAIT send is EAGAIN at once");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* D: a blocked writer gets EPIPE when the reader goes away */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            syscall1(SYS_CLOSE, sv[1]);
            /* the reader never reads: this write blocks, then the parent closes its end */
            /* sendto copies at most 8192 bytes: fill the ring, then the next send blocks */
            syscall6(SYS_SENDTO, (uint64_t)sv[0], (uint64_t)big, 8192, 0x4000 /* MSG_NOSIGNAL */, 0, 0);
            int64_t tw = now_ms();
            int64_t w = syscall6(SYS_SENDTO, (uint64_t)sv[0], (uint64_t)big, 8192, 0x4000 /* MSG_NOSIGNAL */, 0, 0);
            int blocked = now_ms() - tw >= 80;
            syscall1(SYS_EXIT, blocked && ((w < 0 && -w == EPIPE_) || (w > 0 && w < 8192)) ? 0 : 1);
            for (;;) {}
        }
        syscall1(SYS_CLOSE, sv[0]);
        sleep_ms(120);
        syscall1(SYS_CLOSE, sv[1]);
        int st = -1;
        int64_t t0 = now_ms();
        syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        check(st == 0 && now_ms() - t0 < 2000, "D: the writer really blocked, then was woken when the reader closed (EPIPE or a short count)");
    }

    /* E: SO_SNDTIMEO bounds a blocking write */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        struct tv t = { 0, 150000 };
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)sv[0], SOL_SOCKET, SO_SNDTIMEO, (uint64_t)&t, 16) == 0, "E: set SO_SNDTIMEO on a socketpair end");
        int64_t t0 = now_ms();
        int64_t w1 = syscall3(SYS_WRITE, sv[0], (uint64_t)big, BIG);
        int64_t dt1 = now_ms() - t0;
        check(w1 > 0 && w1 < BIG, "E: a write larger than the ring returns the bytes sent when the timeout expires");
        check(dt1 >= 120 && dt1 < 600, "E: after about 150 ms");
        t0 = now_ms();
        int64_t w2 = syscall3(SYS_WRITE, sv[0], (uint64_t)big, 100);
        int64_t dt2 = now_ms() - t0;
        check(w2 == -EAGAIN_ && dt2 >= 120 && dt2 < 600, "E: the next write on the full ring is EAGAIN after the timeout");
        char b[64];
        syscall3(SYS_READ, sv[1], (uint64_t)b, 64);
        t0 = now_ms();
        int64_t w3 = syscall3(SYS_WRITE, sv[0], (uint64_t)big, 50);
        check(w3 == 50 && now_ms() - t0 < 100, "E: once the reader made room the write completes at once");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    print(failures == 0 ? "hello150: PASS\n" : "hello150: FAIL\n");
    print("hello150 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
