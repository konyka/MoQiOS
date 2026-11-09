/// hello183: TCP bind() errors (EADDRINUSE, EACCES, EINVAL) and SO_REUSEADDR rules.

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
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_SENDTO    121
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SETSOCKOPT 132
#define SYS_SETUID    174
#define SYS_IOCTL     165
#define SIOCGIFADDR   0x8915
#define EADDRNOTAVAIL_ 99
#define AF_INET 2
#define AF_INET6 10
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define SO_REUSEPORT 15
#define EACCES_ 13
#define EINVAL_ 22
#define EADDRINUSE_ 98

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello183:   ok   " : "hello183:   FAIL ");
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
static int64_t sock4(void) { return syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0); }
static int64_t bind4(int64_t s, int port) {
    uint8_t sa[16];
    mk_addr(sa, port);
    return syscall3(SYS_BIND, (uint64_t)s, (uint64_t)sa, 16);
}
static void reuseport(int64_t s) {
    int one = 1;
    syscall5(SYS_SETSOCKOPT, (uint64_t)s, SOL_SOCKET, SO_REUSEPORT, (uint64_t)&one, 4);
}
static void reuse(int64_t s) {
    int one = 1;
    syscall5(SYS_SETSOCKOPT, (uint64_t)s, SOL_SOCKET, SO_REUSEADDR, (uint64_t)&one, 4);
}

void _start(void) {
    print("hello183: TCP bind errors and SO_REUSEADDR\n");

    /* A: a port held by another socket is EADDRINUSE */
    int64_t a = sock4();
    check(bind4(a, 18383) == 0, "A: bind a free port");
    int64_t b = sock4();
    check(bind4(b, 18383) == -EADDRINUSE_, "A: binding the same port again is EADDRINUSE");
    check(bind4(a, 18384) == -EINVAL_, "A: rebinding an already bound socket is EINVAL");
    check(bind4(b, 18385) == 0, "A: a different port is fine");
    syscall1(SYS_CLOSE, b);

    /* B: a listening socket's port is not shareable even with SO_REUSEADDR on both */
    reuse(a);
    check(syscall2(SYS_LISTEN, (uint64_t)a, 4) == 0, "B: listen");
    int64_t c = sock4();
    reuse(c);
    check(bind4(c, 18383) == -EADDRINUSE_, "B: SO_REUSEADDR does not let a second socket bind a listening port");
    syscall1(SYS_CLOSE, c);

    /* C: after the listener closes the port can be bound again (with SO_REUSEADDR, even with connections in TIME_WAIT) */
    {
        uint8_t sa[16];
        mk_addr(sa, 18383);
        int64_t cl = sock4();
        int64_t r = syscall3(SYS_CONNECT, (uint64_t)cl, (uint64_t)sa, 16);
        for (int i = 0; i < 20 && r < 0; i++) { syscall1(SYS_NETPOLL, 0); r = syscall3(SYS_CONNECT, (uint64_t)cl, (uint64_t)sa, 16); if (r == -106) { r = 0; break; } }
        int64_t acc = -1;
        for (int i = 0; i < 20 && acc < 0; i++) { syscall1(SYS_NETPOLL, 0); acc = syscall4(SYS_ACCEPT4, (uint64_t)a, 0, 0, 0); }
        check(r == 0 && acc >= 0, "C: a connection to the listener");
        syscall1(SYS_CLOSE, (uint64_t)acc);
        syscall1(SYS_CLOSE, (uint64_t)cl);
        pump(100);
        syscall1(SYS_CLOSE, a);
        pump(100);
        int64_t d = sock4();
        reuse(d);
        check(bind4(d, 18383) == 0, "C: with SO_REUSEADDR the port can be rebound while old connections linger");
        syscall1(SYS_CLOSE, d);
    }

    /* D: privileged ports need CAP_NET_BIND_SERVICE */
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        failures = 0;
        syscall1(SYS_SETUID, 1000);
        int64_t s = sock4();
        check(bind4(s, 80) == -EACCES_, "D: an unprivileged bind to port 80 is EACCES");
        check(bind4(s, 18386) == 0, "D: and the socket is still usable for an ordinary port");
        {
            uint8_t ua[16], ua6[28];
            mk_addr(ua, 53);
            mk_addr6(ua6, 53);
            int64_t u4 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
            check(syscall3(SYS_BIND, (uint64_t)u4, (uint64_t)ua, 16) == -EACCES_, "D: an unprivileged UDP bind to port 53 is EACCES");
            mk_addr(ua, 24383);
            check(syscall3(SYS_BIND, (uint64_t)u4, (uint64_t)ua, 16) == 0, "D: and an ordinary UDP port is fine");
            int64_t u6 = syscall3(SYS_SOCKET, AF_INET6, SOCK_DGRAM, 0);
            check(syscall3(SYS_BIND, (uint64_t)u6, (uint64_t)ua6, 28) == -EACCES_, "D: an unprivileged IPv6 UDP bind to port 53 is EACCES");
        }
        syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
        for (;;) {}
    }
    int st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    check(((st >> 8) & 0xff) == 0 && (st & 0x7f) == 0, "D: the unprivileged child's checks all passed");

    /* E: IPv6 sockets report the same errors */
    {
        uint8_t s6a[28];
        mk_addr6(s6a, 18387);
        int64_t x = syscall3(SYS_SOCKET, AF_INET6, SOCK_STREAM, 0);
        int64_t y = syscall3(SYS_SOCKET, AF_INET6, SOCK_STREAM, 0);
        check(syscall3(SYS_BIND, (uint64_t)x, (uint64_t)s6a, 28) == 0, "E: IPv6 bind");
        check(syscall3(SYS_BIND, (uint64_t)y, (uint64_t)s6a, 28) == -EADDRINUSE_, "E: the same IPv6 port again is EADDRINUSE");
        check(syscall3(SYS_BIND, (uint64_t)x, (uint64_t)s6a, 28) == -EINVAL_, "E: rebinding an IPv6 socket is EINVAL");
        syscall1(SYS_CLOSE, x);
        syscall1(SYS_CLOSE, y);
    }

    /* F: binding an address this host does not have is EADDRNOTAVAIL, checked before the port (so before EADDRINUSE and EACCES) */
    {
        uint8_t fa[16];
        int64_t t4 = sock4();
        mk_addr(fa, 18390); fa[4] = 192; fa[5] = 0; fa[6] = 2; fa[7] = 1; /* 192.0.2.1: TEST-NET-1, never assigned here */
        check(syscall3(SYS_BIND, (uint64_t)t4, (uint64_t)fa, 16) == -EADDRNOTAVAIL_, "F: TCP bind to a foreign address is EADDRNOTAVAIL");
        mk_addr(fa, 18390); fa[4] = 0; fa[5] = 0; fa[6] = 0; fa[7] = 0;
        check(syscall3(SYS_BIND, (uint64_t)t4, (uint64_t)fa, 16) == 0, "F: the failed bind left the socket unbound: 0.0.0.0 works");
        int64_t t5 = sock4();
        mk_addr(fa, 18390); fa[4] = 192; fa[5] = 0; fa[6] = 2; fa[7] = 1;
        check(syscall3(SYS_BIND, (uint64_t)t5, (uint64_t)fa, 16) == -EADDRNOTAVAIL_, "F: a foreign address on a taken port is EADDRNOTAVAIL, not EADDRINUSE");
        mk_addr(fa, 18391); fa[4] = 127; fa[7] = 2;
        check(syscall3(SYS_BIND, (uint64_t)t5, (uint64_t)fa, 16) == 0, "F: any 127.x.y.z address is local");
        int64_t u4 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        mk_addr(fa, 24390); fa[4] = 192; fa[5] = 0; fa[6] = 2; fa[7] = 1;
        check(syscall3(SYS_BIND, (uint64_t)u4, (uint64_t)fa, 16) == -EADDRNOTAVAIL_, "F: UDP bind to a foreign address is EADDRNOTAVAIL");
        mk_addr(fa, 24390); fa[4] = 224; fa[5] = 0; fa[6] = 0; fa[7] = 251;
        check(syscall3(SYS_BIND, (uint64_t)u4, (uint64_t)fa, 16) == 0, "F: a multicast address may be bound (Linux allows it)");
        {
            uint8_t req[40];
            for (int i = 0; i < 40; i++) req[i] = 0;
            req[0] = 'e'; req[1] = 't'; req[2] = 'h'; req[3] = '0';
            if (syscall3(SYS_IOCTL, (uint64_t)t4, SIOCGIFADDR, (uint64_t)req) == 0) {
                int64_t u5 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
                mk_addr(fa, 24391);
                for (int i = 0; i < 4; i++) fa[4 + i] = req[20 + i];
                check(syscall3(SYS_BIND, (uint64_t)u5, (uint64_t)fa, 16) == 0, "F: the NIC's own address is local");
                syscall1(SYS_CLOSE, u5);
            }
        }
        uint8_t f6[28];
        int64_t t6 = syscall3(SYS_SOCKET, AF_INET6, SOCK_STREAM, 0);
        mk_addr6(f6, 18392);
        for (int i = 0; i < 16; i++) f6[8 + i] = 0;
        f6[8] = 0x20; f6[9] = 0x01; f6[10] = 0x0d; f6[11] = 0xb8; f6[23] = 1; /* 2001:db8::1 documentation prefix */
        check(syscall3(SYS_BIND, (uint64_t)t6, (uint64_t)f6, 28) == -EADDRNOTAVAIL_, "F: IPv6 TCP bind to a foreign address is EADDRNOTAVAIL");
        int64_t u6 = syscall3(SYS_SOCKET, AF_INET6, SOCK_DGRAM, 0);
        mk_addr6(f6, 24392);
        for (int i = 0; i < 16; i++) f6[8 + i] = 0;
        f6[8] = 0x20; f6[9] = 0x01; f6[10] = 0x0d; f6[11] = 0xb8; f6[23] = 1;
        check(syscall3(SYS_BIND, (uint64_t)u6, (uint64_t)f6, 28) == -EADDRNOTAVAIL_, "F: IPv6 UDP bind to a foreign address is EADDRNOTAVAIL");
        for (int i = 0; i < 16; i++) f6[8 + i] = 0;
        check(syscall3(SYS_BIND, (uint64_t)u6, (uint64_t)f6, 28) == 0, "F: :: (any) is fine");
        syscall1(SYS_CLOSE, t4); syscall1(SYS_CLOSE, t5); syscall1(SYS_CLOSE, u4);
        syscall1(SYS_CLOSE, t6); syscall1(SYS_CLOSE, u6);
    }

    /* G: SO_REUSEPORT lets sockets that all set it share one port, each with its own listener; connections are spread over them */
    {
        int64_t p1 = sock4(), p2 = sock4(), p3 = sock4(), plain = sock4();
        reuseport(p1); reuseport(p2);
        check(bind4(p1, 18395) == 0, "G: first SO_REUSEPORT socket binds");
        check(bind4(p2, 18395) == 0, "G: a second SO_REUSEPORT socket binds the same port");
        check(bind4(plain, 18395) == -EADDRINUSE_, "G: a socket without SO_REUSEPORT cannot join the port");
        reuseport(plain);
        check(bind4(plain, 18395) == 0, "G: once it sets SO_REUSEPORT it can");
        check(syscall2(SYS_LISTEN, (uint64_t)p1, 8) == 0 && syscall2(SYS_LISTEN, (uint64_t)p2, 8) == 0, "G: both listen on the shared port");
        int64_t other = sock4();
        check(bind4(other, 18396) == 0, "G: a different port is unaffected");
        int64_t late = sock4();
        check(bind4(late, 18395) == -EADDRINUSE_, "G: a socket that sets SO_REUSEPORT only after trying to bind is still refused");
        reuseport(late);
        check(bind4(late, 18395) == 0, "G: and joins when it set the option first");
        syscall1(SYS_CLOSE, late); syscall1(SYS_CLOSE, other); syscall1(SYS_CLOSE, plain);
        /* connections: 12 clients, each accepted by exactly one of the two listeners; every client is accepted somewhere */
        uint8_t sa[16];
        mk_addr(sa, 18395);
        int got1 = 0, got2 = 0, conn_ok = 0;
        int64_t clients[12];
        for (int i = 0; i < 12; i++) {
            clients[i] = sock4();
            syscall3(SYS_CONNECT, (uint64_t)clients[i], (uint64_t)sa, 16);
        }
        for (int round = 0; round < 40 && got1 + got2 < 12; round++) {
            syscall1(SYS_NETPOLL, 0);
            int64_t a1 = syscall4(SYS_ACCEPT4, (uint64_t)p1, 0, 0, 0x800);
            if (a1 >= 0) { got1++; syscall1(SYS_CLOSE, (uint64_t)a1); }
            int64_t a2 = syscall4(SYS_ACCEPT4, (uint64_t)p2, 0, 0, 0x800);
            if (a2 >= 0) { got2++; syscall1(SYS_CLOSE, (uint64_t)a2); }
            sleep_ms(5);
        }
        conn_ok = got1 + got2 == 12;
        check(conn_ok, "G: all 12 connections to the shared port are accepted by one of the two listeners");
        check(got1 > 0 && got2 > 0, "G: and both listeners get some of them (spread, not all to one)");
        for (int i = 0; i < 12; i++) syscall1(SYS_CLOSE, (uint64_t)clients[i]);
        /* closing one listener leaves the other serving the port */
        syscall1(SYS_CLOSE, p1);
        pump(100);
        int64_t c2 = sock4();
        int64_t cr = syscall3(SYS_CONNECT, (uint64_t)c2, (uint64_t)sa, 16);
        int64_t acc = -1;
        for (int i = 0; i < 40 && acc < 0; i++) { syscall1(SYS_NETPOLL, 0); acc = syscall4(SYS_ACCEPT4, (uint64_t)p2, 0, 0, 0x800); sleep_ms(5); }
        check((cr == 0 || cr == -115 || cr == -106) && acc >= 0, "G: after one listener closes, the other still accepts new connections");
        if (acc >= 0) syscall1(SYS_CLOSE, (uint64_t)acc);
        syscall1(SYS_CLOSE, c2); syscall1(SYS_CLOSE, p2); syscall1(SYS_CLOSE, p3);
    }

    syscall1(SYS_CLOSE, b);
    print(failures == 0 ? "hello183: PASS\n" : "hello183: FAIL\n");
    print("hello183 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
