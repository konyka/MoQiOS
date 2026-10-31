/// hello153: AF_UNIX shutdown(2) half-close semantics.

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
#define SYS_SHUTDOWN  48
#define SYS_SENDTO    121
#define SYS_SOCKETPAIR 53
#define SYS_FCNTL     142
#define SYS_CLOCK_GETTIME 228
#define AF_UNIX 1
#define SOCK_STREAM 1
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2
#define EAGAIN_ 11
#define EPIPE_ 32

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello153:   ok   " : "hello153:   FAIL ");
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
static void pair(int *sv, int nonblock) {
    syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
    if (nonblock) {
        syscall3(SYS_FCNTL, (uint64_t)sv[0], F_SETFL, O_NONBLOCK);
        syscall3(SYS_FCNTL, (uint64_t)sv[1], F_SETFL, O_NONBLOCK);
    }
}

void _start(void) {
    print("hello153: AF_UNIX shutdown(2) half-close semantics\n");
    char b[16];

    /* A: SHUT_WR - the peer drains what was sent, then reads EOF; the other
     * direction keeps working */
    {
        int sv[2];
        pair(sv, 1);
        syscall3(SYS_WRITE, sv[0], (uint64_t)"abc", 3);
        check(syscall2(SYS_SHUTDOWN, sv[0], SHUT_WR) == 0, "A: shutdown(SHUT_WR) succeeds");
        check(syscall3(SYS_READ, sv[1], (uint64_t)b, 16) == 3, "A: the peer still reads the bytes sent before the shutdown");
        check(syscall3(SYS_READ, sv[1], (uint64_t)b, 16) == 0, "A: and then reads EOF (0), not EAGAIN");
        check(syscall6(SYS_SENDTO, (uint64_t)sv[0], (uint64_t)"x", 1, 0x4000 /* MSG_NOSIGNAL */, 0, 0) == -EPIPE_, "A: writing after SHUT_WR is EPIPE");
        check(syscall3(SYS_WRITE, sv[1], (uint64_t)"hi", 2) == 2, "A: the other direction still accepts data");
        check(syscall3(SYS_READ, sv[0], (uint64_t)b, 16) == 2, "A: and the half-closed end still reads it");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* B: SHUT_RD - local reads see EOF, the peer's writes fail with EPIPE */
    {
        int sv[2];
        pair(sv, 1);
        check(syscall2(SYS_SHUTDOWN, sv[0], SHUT_RD) == 0, "B: shutdown(SHUT_RD) succeeds");
        check(syscall3(SYS_READ, sv[0], (uint64_t)b, 16) == 0, "B: a read after SHUT_RD is EOF (0)");
        check(syscall6(SYS_SENDTO, (uint64_t)sv[1], (uint64_t)"x", 1, 0x4000 /* MSG_NOSIGNAL */, 0, 0) == -EPIPE_, "B: the peer's write is EPIPE");
        check(syscall3(SYS_WRITE, sv[0], (uint64_t)"y", 1) == 1, "B: the shut-down end can still send");
        check(syscall3(SYS_READ, sv[1], (uint64_t)b, 16) == 1, "B: and the peer receives it");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* C: SHUT_RDWR */
    {
        int sv[2];
        pair(sv, 1);
        check(syscall2(SYS_SHUTDOWN, sv[0], SHUT_RDWR) == 0, "C: shutdown(SHUT_RDWR) succeeds");
        check(syscall3(SYS_READ, sv[0], (uint64_t)b, 16) == 0, "C: local read is EOF");
        check(syscall6(SYS_SENDTO, (uint64_t)sv[0], (uint64_t)"x", 1, 0x4000 /* MSG_NOSIGNAL */, 0, 0) == -EPIPE_, "C: local write is EPIPE");
        check(syscall3(SYS_READ, sv[1], (uint64_t)b, 16) == 0, "C: the peer reads EOF");
        check(syscall6(SYS_SENDTO, (uint64_t)sv[1], (uint64_t)"x", 1, 0x4000 /* MSG_NOSIGNAL */, 0, 0) == -EPIPE_, "C: the peer's write is EPIPE");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* D: a reader blocked in read() is woken by the peer's SHUT_WR and sees EOF */
    {
        int sv[2];
        pair(sv, 0);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            syscall1(SYS_CLOSE, sv[0]);
            int64_t r = syscall3(SYS_READ, sv[1], (uint64_t)b, 16);
            syscall1(SYS_EXIT, r == 0 ? 0 : 1);
            for (;;) {}
        }
        sleep_ms(100);
        syscall2(SYS_SHUTDOWN, sv[0], SHUT_WR);
        int st = -1;
        int64_t t0 = now_ms();
        int done = 0;
        while (now_ms() - t0 < 1500) {
            if (syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 1) == child) { done = 1; break; }
            sleep_ms(10);
        }
        if (!done) {
            syscall1(SYS_CLOSE, sv[0]);
            syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
        }
        check(done && st == 0, "D: a blocked reader is woken by the peer's SHUT_WR and reads EOF");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    print(failures == 0 ? "hello153: PASS\n" : "hello153: FAIL\n");
    print("hello153 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
