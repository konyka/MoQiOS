/// hello178: IP_TTL, IP_TOS, IPV6_UNICAST_HOPS, IPV6_TCLASS, IPV6_V6ONLY on TCP and UDP sockets.

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
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SETSOCKOPT 132
#define SYS_GETSOCKOPT 133
#define SYS_FCNTL     142
#define AF_INET 2
#define AF_INET6 10
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SOL_IP 0
#define SOL_IPV6 41
#define IP_TOS 1
#define IP_TTL 2
#define IPV6_UNICAST_HOPS 16
#define IPV6_V6ONLY 26
#define IPV6_TCLASS 67
#define F_SETFL 4
#define O_NONBLOCK 0x800
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
    print(ok ? "hello178:   ok   " : "hello178:   FAIL ");
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
    a[0] = 2; a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port; a[4] = 127; a[7] = 1;
}
static void mk_addr6(uint8_t *a, int port) {
    for (int i = 0; i < 28; i++) a[i] = 0;
    a[0] = AF_INET6;
    a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port;
    a[8 + 15] = 1;
}
static int64_t set_int(int fd, int lvl, int name, int v) {
    return syscall5(SYS_SETSOCKOPT, (uint64_t)fd, (uint64_t)lvl, (uint64_t)name, (uint64_t)&v, 4);
}
static int get_int(int fd, int lvl, int name) {
    int v = -12345;
    uint32_t l = 4;
    if (syscall5(SYS_GETSOCKOPT, (uint64_t)fd, (uint64_t)lvl, (uint64_t)name, (uint64_t)&v, (uint64_t)&l) != 0) return -99999;
    return v;
}
static int make_pair(int family, int port, int *cli, int *srv) {
    uint8_t sa[28];
    int sl;
    if (family == AF_INET) { mk_addr(sa, port); sl = 16; } else { mk_addr6(sa, port); sl = 28; }
    int64_t l = syscall3(SYS_SOCKET, family, SOCK_STREAM, 0);
    if (l < 0) return -1;
    if (syscall3(SYS_BIND, (uint64_t)l, (uint64_t)sa, sl) != 0) return -2;
    if (syscall2(SYS_LISTEN, (uint64_t)l, 4) != 0) return -3;
    int64_t c = syscall3(SYS_SOCKET, family, SOCK_STREAM, 0);
    if (c < 0) return -4;
    int64_t cr = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, sl);
    if (cr < 0) syscall1(SYS_NETPOLL, 0);
    for (int i = 0; i < 20 && cr < 0; i++) {
        cr = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, sl);
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
    print("hello178: IP-level socket options\n");
    char b[16];

    /* A: IPv4 TCP: defaults, set, read back, and traffic still flows (the patched header must keep a valid checksum) */
    {
        int c, s;
        check(make_pair(AF_INET, 18878, &c, &s) == 0, "A: IPv4 loopback connection");
        check(get_int(c, SOL_IP, IP_TTL) == 64, "A: the default IP_TTL is 64");
        check(get_int(c, SOL_IP, IP_TOS) == 0, "A: the default IP_TOS is 0");
        check(set_int(c, SOL_IP, IP_TTL, 17) == 0 && get_int(c, SOL_IP, IP_TTL) == 17, "A: IP_TTL 17 reads back");
        check(set_int(c, SOL_IP, IP_TOS, 0x10) == 0 && get_int(c, SOL_IP, IP_TOS) == 0x10, "A: IP_TOS 0x10 (low delay) reads back");
        check(set_int(c, SOL_IP, IP_TOS, 0x13) == 0 && get_int(c, SOL_IP, IP_TOS) == 0x10, "A: the ECN bits of IP_TOS are not settable");
        check(set_int(c, SOL_IP, IP_TTL, 0) == -EINVAL_, "A: IP_TTL 0 is EINVAL");
        check(set_int(c, SOL_IP, IP_TTL, 256) == -EINVAL_, "A: IP_TTL 256 is EINVAL");
        check(set_int(c, SOL_IP, IP_TTL, -1) == 0 && get_int(c, SOL_IP, IP_TTL) == 64, "A: IP_TTL -1 restores the default");
        set_int(c, SOL_IP, IP_TTL, 5);
        set_int(s, SOL_IP, IP_TOS, 0xB8);
        check(syscall3(SYS_WRITE, c, (uint64_t)"ping", 4) == 4, "A: write with TTL/TOS set");
        pump(100);
        check(syscall3(SYS_READ, s, (uint64_t)b, 16) == 4 && b[0] == 'p', "A: arrives (the patched IPv4 header still checksums)");
        check(syscall3(SYS_WRITE, s, (uint64_t)"pong", 4) == 4, "A: and the reverse direction with its own TOS");
        pump(100);
        check(syscall3(SYS_READ, c, (uint64_t)b, 16) == 4 && b[0] == 'p', "A: arrives as well");
        check(get_int(c, SOL_IPV6, IPV6_UNICAST_HOPS) == -99999, "A: the IPv6 level does not apply to an IPv4 socket");
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    /* B: IPv6 TCP */
    {
        int c, s;
        check(make_pair(AF_INET6, 18879, &c, &s) == 0, "B: IPv6 loopback connection");
        check(get_int(c, SOL_IPV6, IPV6_UNICAST_HOPS) == 64, "B: the default IPV6_UNICAST_HOPS is 64");
        check(get_int(c, SOL_IPV6, IPV6_TCLASS) == 0, "B: the default IPV6_TCLASS is 0");
        check(set_int(c, SOL_IPV6, IPV6_UNICAST_HOPS, 9) == 0 && get_int(c, SOL_IPV6, IPV6_UNICAST_HOPS) == 9, "B: IPV6_UNICAST_HOPS 9 reads back");
        check(set_int(c, SOL_IPV6, IPV6_UNICAST_HOPS, 256) == -EINVAL_, "B: IPV6_UNICAST_HOPS 256 is EINVAL");
        check(set_int(c, SOL_IPV6, IPV6_UNICAST_HOPS, -2) == -EINVAL_, "B: IPV6_UNICAST_HOPS -2 is EINVAL");
        check(set_int(c, SOL_IPV6, IPV6_TCLASS, 0xB8) == 0 && get_int(c, SOL_IPV6, IPV6_TCLASS) == 0xB8, "B: IPV6_TCLASS 0xB8 reads back");
        check(set_int(c, SOL_IPV6, IPV6_TCLASS, 0xBB) == 0 && get_int(c, SOL_IPV6, IPV6_TCLASS) == 0xB8, "B: the ECN bits of IPV6_TCLASS are not settable");
        check(set_int(c, SOL_IPV6, IPV6_TCLASS, 256) == -EINVAL_, "B: IPV6_TCLASS 256 is EINVAL");
        check(get_int(c, SOL_IPV6, IPV6_V6ONLY) == 1, "B: IPV6_V6ONLY reads 1 (no IPv4-mapped dual stack here)");
        check(set_int(c, SOL_IPV6, IPV6_V6ONLY, 1) == 0, "B: setting IPV6_V6ONLY to 1 is accepted");
        check(set_int(c, SOL_IPV6, IPV6_V6ONLY, 0) == -EINVAL_, "B: turning IPV6_V6ONLY off is EINVAL (cannot be honoured)");
        check(get_int(c, SOL_IP, IP_TTL) == -99999, "B: the IPv4 level does not apply to an IPv6 socket");
        check(syscall3(SYS_WRITE, c, (uint64_t)"ping", 4) == 4, "B: write with hop limit / class set");
        pump(100);
        check(syscall3(SYS_READ, s, (uint64_t)b, 16) == 4 && b[0] == 'p', "B: arrives (the patched IPv6 header is accepted)");
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    /* C: UDP, both families */
    {
        uint8_t sa[16], me[16];
        mk_addr(sa, 24878);
        mk_addr(me, 24879);
        int64_t rx = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        int64_t tx = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        syscall3(SYS_BIND, (uint64_t)rx, (uint64_t)sa, 16);
        syscall3(SYS_BIND, (uint64_t)tx, (uint64_t)me, 16);
        syscall3(SYS_FCNTL, (uint64_t)rx, F_SETFL, O_NONBLOCK);
        check(set_int(tx, SOL_IP, IP_TTL, 33) == 0 && get_int(tx, SOL_IP, IP_TTL) == 33, "C: UDP IP_TTL reads back");
        check(set_int(tx, SOL_IP, IP_TOS, 0x28) == 0 && get_int(tx, SOL_IP, IP_TOS) == 0x28, "C: UDP IP_TOS reads back");
        syscall6(SYS_SENDTO, (uint64_t)tx, (uint64_t)"dgram", 5, 0, (uint64_t)sa, 16);
        pump(100);
        check(syscall6(SYS_RECVFROM, (uint64_t)rx, (uint64_t)b, 16, 0, 0, 0) == 5, "C: the datagram arrives (valid checksum after the patch)");
        syscall1(SYS_CLOSE, rx);
        syscall1(SYS_CLOSE, tx);

        uint8_t sa6[28], me6[28];
        mk_addr6(sa6, 24880);
        mk_addr6(me6, 24881);
        int64_t rx6 = syscall3(SYS_SOCKET, AF_INET6, SOCK_DGRAM, 0);
        int64_t tx6 = syscall3(SYS_SOCKET, AF_INET6, SOCK_DGRAM, 0);
        syscall3(SYS_BIND, (uint64_t)rx6, (uint64_t)sa6, 28);
        syscall3(SYS_BIND, (uint64_t)tx6, (uint64_t)me6, 28);
        syscall3(SYS_FCNTL, (uint64_t)rx6, F_SETFL, O_NONBLOCK);
        check(set_int(tx6, SOL_IPV6, IPV6_UNICAST_HOPS, 12) == 0 && get_int(tx6, SOL_IPV6, IPV6_UNICAST_HOPS) == 12, "C: UDP IPV6_UNICAST_HOPS reads back");
        check(set_int(tx6, SOL_IPV6, IPV6_TCLASS, 0x20) == 0 && get_int(tx6, SOL_IPV6, IPV6_TCLASS) == 0x20, "C: UDP IPV6_TCLASS reads back");
        syscall6(SYS_SENDTO, (uint64_t)tx6, (uint64_t)"dgram6", 6, 0, (uint64_t)sa6, 28);
        pump(100);
        check(syscall6(SYS_RECVFROM, (uint64_t)rx6, (uint64_t)b, 16, 0, 0, 0) == 6, "C: the IPv6 datagram arrives");
        syscall1(SYS_CLOSE, rx6);
        syscall1(SYS_CLOSE, tx6);
    }

    /* D: nonexistent options and levels are still refused */
    {
        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        check(set_int(u, SOL_IP, 99, 1) == -ENOPROTOOPT_, "D: an unknown IP option is ENOPROTOOPT");
        check(set_int(u, SOL_IP, IP_TTL, 5) == 0, "D: while a real one is accepted");
        syscall1(SYS_CLOSE, u);
    }

    print(failures == 0 ? "hello178: PASS\n" : "hello178: FAIL\n");
    print("hello178 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
