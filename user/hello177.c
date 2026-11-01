/// hello177: TCP_INFO, TCP_MAXSEG, TCP_CONGESTION and the accepted-but-inert TCP options.

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
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SETSOCKOPT 132
#define SYS_GETSOCKOPT 133
#define AF_INET 2
#define SOCK_STREAM 1
#define SOL_TCP 6
#define TCP_MAXSEG 2
#define TCP_INFO 11
#define TCP_CONGESTION 13
#define TCP_USER_TIMEOUT 18
#define TCP_DEFER_ACCEPT 9
#define TCP_SYNCNT 7
#define TCP_LINGER2 8
#define TCP_NOTSENT_LOWAT 25
#define ENOENT_ 2
#define EINVAL_ 22
#define ENOPROTOOPT_ 92

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello177:   ok   " : "hello177:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
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
static int set_int(int fd, int name, int v) {
    return (int)syscall5(SYS_SETSOCKOPT, (uint64_t)fd, SOL_TCP, (uint64_t)name, (uint64_t)&v, 4);
}
static int get_int(int fd, int name) {
    int v = -12345;
    uint32_t l = 4;
    if (syscall5(SYS_GETSOCKOPT, (uint64_t)fd, SOL_TCP, (uint64_t)name, (uint64_t)&v, (uint64_t)&l) != 0) return -99999;
    return v;
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
static uint32_t u32at(const uint8_t *b, int off) { return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | ((uint32_t)b[off + 3] << 24); }

void _start(void) {
    print("hello177: TCP_INFO / TCP_MAXSEG / TCP_CONGESTION\n");
    int c, s;
    check(make_pair(18877, &c, &s) == 0, "A: loopback connection");

    /* B: TCP_INFO */
    uint8_t info[256];
    for (int i = 0; i < 256; i++) info[i] = 0x77;
    uint32_t len = sizeof(info);
    int64_t r = syscall5(SYS_GETSOCKOPT, (uint64_t)c, SOL_TCP, TCP_INFO, (uint64_t)info, (uint64_t)&len);
    check(r == 0, "B: getsockopt(TCP_INFO) succeeds");
    check(len >= 104 && len <= 256, "B: and reports a length covering the common fields (>= 104)");
    check(info[0] == 1, "B: tcpi_state is TCP_ESTABLISHED (1)");
    check((info[5] & 0x2) != 0, "B: tcpi_options says SACK is on");
    check(u32at(info, 16) >= 500 && u32at(info, 16) <= 1460, "B: tcpi_snd_mss is a plausible MSS");
    check(u32at(info, 80) >= 1, "B: tcpi_snd_cwnd is at least one segment");
    check(u32at(info, 60) >= 576, "B: tcpi_pmtu is at least 576");
    uint32_t small_len = 16;
    uint8_t small[16];
    check(syscall5(SYS_GETSOCKOPT, (uint64_t)c, SOL_TCP, TCP_INFO, (uint64_t)small, (uint64_t)&small_len) == 0 && small_len == 16 && small[0] == 1, "B: a short buffer gets a truncated copy");

    /* C: TCP_MAXSEG */
    int mss = get_int(c, TCP_MAXSEG);
    check(mss >= 500 && mss <= 1460, "C: TCP_MAXSEG of an established connection reports its MSS");
    check(set_int(c, TCP_MAXSEG, 1000) == -EINVAL_, "C: setting TCP_MAXSEG after the connection is established is EINVAL");
    {
        int c2 = (int)syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
        check(set_int(c2, TCP_MAXSEG, 10) == -EINVAL_, "C: a TCP_MAXSEG below 88 is EINVAL");
        check(set_int(c2, TCP_MAXSEG, 100000) == -EINVAL_, "C: and one above the maximum is EINVAL");
        check(set_int(c2, TCP_MAXSEG, 536) == 0, "C: a valid TCP_MAXSEG before connect is accepted");
        check(get_int(c2, TCP_MAXSEG) <= 536, "C: and caps the reported MSS");
        syscall1(SYS_CLOSE, c2);
    }

    /* D: TCP_CONGESTION */
    char cc[16];
    for (int i = 0; i < 16; i++) cc[i] = 0x7f;
    uint32_t cl = 16;
    check(syscall5(SYS_GETSOCKOPT, (uint64_t)c, SOL_TCP, TCP_CONGESTION, (uint64_t)cc, (uint64_t)&cl) == 0 && cl == 6 && cc[0] == 'c' && cc[4] == 'c' && cc[5] == 0, "D: TCP_CONGESTION reads back \"cubic\"");
    check(syscall5(SYS_SETSOCKOPT, (uint64_t)c, SOL_TCP, TCP_CONGESTION, (uint64_t)"cubic", 5) == 0, "D: selecting cubic is accepted");
    check(syscall5(SYS_SETSOCKOPT, (uint64_t)c, SOL_TCP, TCP_CONGESTION, (uint64_t)"nosuchalgo", 10) == -ENOENT_, "D: an unknown algorithm is ENOENT");

    /* E: options that are accepted but have nothing to tune here */
    check(set_int(c, TCP_USER_TIMEOUT, 5000) == 0 && get_int(c, TCP_USER_TIMEOUT) == 0, "E: TCP_USER_TIMEOUT is accepted");
    check(set_int(c, TCP_USER_TIMEOUT, -1) == -EINVAL_, "E: a negative TCP_USER_TIMEOUT is EINVAL");
    check(set_int(c, TCP_NOTSENT_LOWAT, 4096) == 0, "E: TCP_NOTSENT_LOWAT is accepted");
    check(set_int(c, TCP_SYNCNT, 3) == 0 && set_int(c, TCP_DEFER_ACCEPT, 1) == 0 && set_int(c, TCP_LINGER2, 10) == 0, "E: TCP_SYNCNT / TCP_DEFER_ACCEPT / TCP_LINGER2 are accepted");
    check(set_int(c, 99, 1) == -ENOPROTOOPT_, "E: a TCP option that does not exist is still ENOPROTOOPT");

    /* F: the connection still carries data after all of this */
    check(syscall3(SYS_WRITE, c, (uint64_t)"ping", 4) == 4, "F: write after the option calls");
    pump(100);
    char b[8];
    check(syscall3(SYS_READ, s, (uint64_t)b, 8) == 4 && b[0] == 'p', "F: and the peer reads it");

    syscall1(SYS_CLOSE, c);
    syscall1(SYS_CLOSE, s);
    print(failures == 0 ? "hello177: PASS\n" : "hello177: FAIL\n");
    print("hello177 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
