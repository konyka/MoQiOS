/// hello43: loopback (127.0.0.1) TCP + UDP round trip in one process (F2).
///
/// Exercises the lo device (kernel/net/lo.zig):
///   TCP: socket → bind 127.0.0.1:18043 → listen → connect → netpoll until
///        accept succeeds → client/server echo both directions.
///   UDP: socket → bind 127.0.0.1:19043 → sendto self → netpoll → recvfrom,
///        verifying payload and that the source address is 127.0.0.1.
///
/// Sockets here are non-blocking; netpoll (syscall 104) pumps the loopback
/// queue between steps, which is what drives the handshake and delivery.

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

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE    1
#define SYS_EXIT     2
#define SYS_CLOSE    11
#define SYS_NETPOLL  104
#define SYS_SOCKET   117
#define SYS_BIND     118
#define SYS_LISTEN   119
#define SYS_ACCEPT   120
#define SYS_SENDTO   121
#define SYS_RECVFROM 122
#define SYS_CONNECT  124

#define AF_INET      2
#define SOCK_STREAM  1
#define SOCK_DGRAM   2

#define TCP_PORT 18043
#define UDP_PORT 19043

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello43: FAIL (");
    print(why);
    print(")\nhello43 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static void netpoll(void) {
    syscall1(SYS_NETPOLL, 0);
}

/* sockaddr_in, 16 bytes: family(2) port(2, BE) addr(4) zero(8) */
static void mk_addr(uint8_t *a, uint16_t port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = 0x00; a[1] = AF_INET;
    a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)(port & 0xff);
    a[4] = 127; a[5] = 0; a[6] = 0; a[7] = 1;
}

static int str_eq_n(const char *a, const char *b, int n) {
    for (int i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

/* Bounded non-blocking recv: pump lo between attempts. */
static int64_t recv_pumped(int64_t fd, char *buf, uint64_t len, uint8_t *src, uint64_t *srclen) {
    for (int attempt = 0; attempt < 1000; attempt++) {
        netpoll();
        int64_t n = syscall6(SYS_RECVFROM, (uint64_t)fd, (uint64_t)buf, len, 0, (uint64_t)src, (uint64_t)srclen);
        if (n != 0) return n;
    }
    return 0;
}

void _start(void) {
    uint8_t addr[16];
    char buf[64];

    /* ── TCP over 127.0.0.1 ─────────────────────────────────────────── */
    int64_t srv = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    if (srv < 0) fail("tcp socket");

    mk_addr(addr, TCP_PORT);
    if (syscall3(SYS_BIND, (uint64_t)srv, (uint64_t)addr, 16) < 0) fail("tcp bind");
    if (syscall2(SYS_LISTEN, (uint64_t)srv, 1) < 0) fail("tcp listen");

    int64_t cli = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    if (cli < 0) fail("tcp client socket");
    if (syscall3(SYS_CONNECT, (uint64_t)cli, (uint64_t)addr, 16) < 0) fail("tcp connect");

    /* SYN → SYN-ACK → ACK all flow through the lo queue; pump until the
       backlog entry is established and accept succeeds. */
    int64_t afd = -1;
    for (int attempt = 0; attempt < 1000 && afd < 0; attempt++) {
        netpoll();
        afd = syscall3(SYS_ACCEPT, (uint64_t)srv, 0, 0);
    }
    if (afd < 0) fail("tcp accept");

    /* client → server */
    const char *ping = "lo-tcp-ping";
    int64_t sent = -1;
    for (int attempt = 0; attempt < 1000 && sent < 0; attempt++) {
        sent = syscall6(SYS_SENDTO, (uint64_t)cli, (uint64_t)ping, 11, 0, 0, 0);
        if (sent < 0) netpoll();
    }
    if (sent != 11) fail("tcp send ping");
    for (int i = 0; i < 64; i++) buf[i] = 0;
    if (recv_pumped(afd, buf, 64, 0, 0) != 11) fail("tcp recv ping");
    if (!str_eq_n(buf, "lo-tcp-ping", 11)) fail("tcp ping payload");

    /* server → client */
    const char *pong = "lo-tcp-pong";
    if (syscall6(SYS_SENDTO, (uint64_t)afd, (uint64_t)pong, 11, 0, 0, 0) != 11) fail("tcp send pong");
    for (int i = 0; i < 64; i++) buf[i] = 0;
    if (recv_pumped(cli, buf, 64, 0, 0) != 11) fail("tcp recv pong");
    if (!str_eq_n(buf, "lo-tcp-pong", 11)) fail("tcp pong payload");

    syscall1(SYS_CLOSE, (uint64_t)afd);
    syscall1(SYS_CLOSE, (uint64_t)cli);
    syscall1(SYS_CLOSE, (uint64_t)srv);
    print("hello43: tcp loopback ok\n");

    /* ── UDP over 127.0.0.1 ─────────────────────────────────────────── */
    int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
    if (u < 0) fail("udp socket");
    mk_addr(addr, UDP_PORT);
    if (syscall3(SYS_BIND, (uint64_t)u, (uint64_t)addr, 16) < 0) fail("udp bind");

    const char *msg = "lo-udp-ok";
    if (syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)msg, 9, 0, (uint64_t)addr, 16) != 9)
        fail("udp sendto");

    uint8_t src[16];
    uint64_t srclen = 16;
    for (int i = 0; i < 16; i++) src[i] = 0;
    for (int i = 0; i < 64; i++) buf[i] = 0;
    if (recv_pumped(u, buf, 64, src, &srclen) != 9) fail("udp recvfrom");
    if (!str_eq_n(buf, "lo-udp-ok", 9)) fail("udp payload");
    /* The datagram must come back from the loopback address itself. */
    if (src[4] != 127 || src[5] != 0 || src[6] != 0 || src[7] != 1) fail("udp src addr");

    syscall1(SYS_CLOSE, (uint64_t)u);
    print("hello43: udp loopback ok\n");

    print("hello43: PASS\nhello43 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
