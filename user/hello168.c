/// hello168: socketpair(AF_UNIX, SOCK_SEQPACKET).

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
#define SYS_GETSOCKOPT 133
#define SYS_FCNTL     142
#define SYS_POLL      162
#define SYS_CLOCK_GETTIME 228
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_SEQPACKET 5
#define SOCK_NONBLOCK 0x800
#define SOCK_CLOEXEC 0x80000
#define SOL_SOCKET 1
#define SO_TYPE 3
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define MSG_DONTWAIT 0x40
#define MSG_TRUNC 0x20
#define POLLIN 0x001
#define POLLOUT 0x004
#define POLLHUP 0x010
#define EAGAIN_ 11
#define EINVAL_ 22

struct pollfd { int32_t fd; int16_t events; int16_t revents; };
struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello168:   ok   " : "hello168:   FAIL ");
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
    print("hello168: socketpair(AF_UNIX, SOCK_SEQPACKET)\n");
    char b[64];
    int sv[2];
    int64_t r = syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_SEQPACKET, 0, (uint64_t)sv);
    check(r == 0, "A: socketpair(AF_UNIX, SOCK_SEQPACKET) succeeds");
    if (r != 0) goto done;

    int ty = 0;
    uint32_t len = 4;
    syscall5(SYS_GETSOCKOPT, (uint64_t)sv[0], SOL_SOCKET, SO_TYPE, (uint64_t)&ty, (uint64_t)&len);
    check(ty == SOCK_SEQPACKET, "A: SO_TYPE reports SOCK_SEQPACKET (5)");

    /* B: record boundaries, both directions */
    check(syscall3(SYS_WRITE, sv[0], (uint64_t)"one", 3) == 3, "B: write(\"one\")");
    check(syscall3(SYS_WRITE, sv[0], (uint64_t)"three", 5) == 5, "B: write(\"three\")");
    check(syscall3(SYS_READ, sv[1], (uint64_t)b, 64) == 3, "B: the first read returns exactly one record (3 bytes)");
    check(syscall3(SYS_READ, sv[1], (uint64_t)b, 64) == 5, "B: the second read returns the next record (5 bytes)");
    check(syscall3(SYS_WRITE, sv[1], (uint64_t)"back", 4) == 4 && syscall3(SYS_READ, sv[0], (uint64_t)b, 64) == 4, "B: the other direction works");

    /* C: a short buffer truncates the record and MSG_TRUNC reports its size */
    syscall3(SYS_WRITE, sv[0], (uint64_t)"abcdefgh", 8);
    check(syscall6(SYS_RECVFROM, (uint64_t)sv[1], (uint64_t)b, 3, MSG_TRUNC, 0, 0) == 8, "C: recv(MSG_TRUNC) with a 3-byte buffer returns the record size (8)");
    syscall3(SYS_FCNTL, (uint64_t)sv[1], F_SETFL, O_NONBLOCK);
    check(syscall3(SYS_READ, sv[1], (uint64_t)b, 64) == -EAGAIN_, "C: and the rest of the record was discarded");

    /* D: unlike a datagram socket, a closed peer is EOF, not EAGAIN */
    syscall1(SYS_CLOSE, sv[0]);
    check(syscall3(SYS_READ, sv[1], (uint64_t)b, 64) == 0, "D: reading after the peer closed returns 0 (EOF)");
    struct pollfd pf = { sv[1], POLLIN, 0 };
    syscall3(SYS_POLL, (uint64_t)&pf, 1, 0);
    check((pf.revents & (POLLIN | POLLHUP)) != 0, "D: and poll reports the hang-up");
    syscall1(SYS_CLOSE, sv[1]);

    /* E: a blocked reader is woken by the peer closing */
    {
        int pv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_SEQPACKET, 0, (uint64_t)pv);
        int64_t child = syscall1(SYS_FORK, 0);
        if (child == 0) {
            syscall1(SYS_CLOSE, pv[1]);
            char c[8];
            int64_t n = syscall3(SYS_READ, pv[0], (uint64_t)c, 8);
            syscall1(SYS_EXIT, n == 0 ? 0 : 1);
            for (;;) {}
        }
        sleep_ms(80);
        syscall1(SYS_CLOSE, pv[1]);
        int st = -1;
        int done_ = 0;
        int64_t t0 = now_ms();
        while (now_ms() - t0 < 1500) {
            if (syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 1) == child) { done_ = 1; break; }
            sleep_ms(10);
        }
        if (!done_) { syscall1(SYS_CLOSE, pv[0]); syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0); }
        check(done_ && st == 0, "E: a blocked read returns 0 when the peer closes");
        syscall1(SYS_CLOSE, pv[0]);
    }

    /* F: flags are accepted, other types are still rejected */
    {
        int fv[2];
        check(syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, (uint64_t)fv) == 0, "F: SOCK_SEQPACKET|SOCK_NONBLOCK|SOCK_CLOEXEC is accepted");
        check(syscall3(SYS_READ, fv[0], (uint64_t)b, 8) == -EAGAIN_, "F: SOCK_NONBLOCK makes the end non-blocking");
        syscall1(SYS_CLOSE, fv[0]);
        syscall1(SYS_CLOSE, fv[1]);
        check(syscall4(SYS_SOCKETPAIR, AF_UNIX, 3, 0, (uint64_t)fv) == -EINVAL_, "F: SOCK_RAW is still rejected");
    }

done:
    print(failures == 0 ? "hello168: PASS\n" : "hello168: FAIL\n");
    print("hello168 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
