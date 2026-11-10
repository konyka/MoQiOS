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
#define SYS_PIPE2     250
#define SYS_CLOSE     11
#define SYS_READ      10
#define SYS_OPEN      9
#define SYS_UNLINK    111
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
#define SYS_GETSOCKOPT 133
#define SYS_RECVFROM  122
#define SO_RCVTIMEO 20
#define MSG_DONTWAIT 0x40
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

static void dump_tcpstats(void) {
    char raw[400];
    int64_t fd = syscall3(9, (uint64_t)"/proc/tcpstats", 0, 0);
    if (fd < 0) return;
    int64_t n = syscall3(10, (uint64_t)fd, (uint64_t)raw, 390);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    if (n <= 0) return;
    raw[n] = 0;
    print("hello183: tcpstats "); print(raw);
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
        int64_t sk_fail = 0;
        for (int i = 0; i < 12; i++) {
            clients[i] = sock4();
            if (clients[i] < 0) sk_fail++;
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
        if (!conn_ok) {
            char d[48] = "hello183: G accepted NN, socket() failed NN\n";
            int t = got1 + got2;
            d[21] = (char)('0' + t / 10); d[22] = (char)('0' + t % 10);
            d[41] = (char)('0' + sk_fail / 10); d[42] = (char)('0' + sk_fail % 10);
            print(d);
            dump_tcpstats();
        }
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


    /* H: UDP SO_REUSEADDR / SO_REUSEPORT share a port; datagrams are spread by sender (REUSEPORT) or go to the newest socket (REUSEADDR) */
    {
        int64_t u1 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0), u2 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        int64_t uplain = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        reuseport(u1); reuseport(u2);
        check(bind4(u1, 18400) == 0, "H: first SO_REUSEPORT UDP socket binds");
        check(bind4(u2, 18400) == 0, "H: a second SO_REUSEPORT UDP socket binds the same port");
        check(bind4(uplain, 18400) == -EADDRINUSE_, "H: a UDP socket without SO_REUSEPORT cannot join the port");
        {
            int v = 0; uint32_t l = 4;
            check(syscall5(SYS_GETSOCKOPT, (uint64_t)u1, SOL_SOCKET, SO_REUSEPORT, (uint64_t)&v, (uint64_t)&l) == 0 && v == 1, "H: SO_REUSEPORT set before bind survives the bind");
            int64_t tv[2] = { 3, 0 };
            int64_t ut = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
            syscall5(SYS_SETSOCKOPT, (uint64_t)ut, SOL_SOCKET, SO_RCVTIMEO, (uint64_t)tv, 16);
            check(bind4(ut, 18401) == 0, "H: bind a socket that has a receive timeout");
            int64_t got[2] = { 0, 0 }; uint32_t gl = 16;
            check(syscall5(SYS_GETSOCKOPT, (uint64_t)ut, SOL_SOCKET, SO_RCVTIMEO, (uint64_t)got, (uint64_t)&gl) == 0 && got[0] == 3, "H: SO_RCVTIMEO set before bind survives the bind");
            syscall1(SYS_CLOSE, (uint64_t)ut);
        }
        uint8_t da[16];
        mk_addr(da, 18400);
        int cnt1 = 0, cnt2 = 0;
        int64_t senders[12];
        for (int i = 0; i < 12; i++) senders[i] = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        for (int i = 0; i < 12; i++) {
            char m = 'a' + i;
            syscall6(SYS_SENDTO, (uint64_t)senders[i], (uint64_t)&m, 1, 0, (uint64_t)da, 16);
            pump(10);
            char rb[4];
            if (syscall6(SYS_RECVFROM, (uint64_t)u1, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1) cnt1++;
            if (syscall6(SYS_RECVFROM, (uint64_t)u2, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1) cnt2++;
        }
        for (int i = 0; i < 12; i++) syscall1(SYS_CLOSE, (uint64_t)senders[i]);
        check(cnt1 + cnt2 == 12, "H: every datagram sent to the shared port is received by exactly one of the two sockets");
        check(cnt1 > 0 && cnt2 > 0, "H: and both sockets get some (spread by sender)");
        {
            int64_t snd = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
            int a1 = 0, a2 = 0;
            for (int i = 0; i < 6; i++) {
                char m = 'x';
                syscall6(SYS_SENDTO, (uint64_t)snd, (uint64_t)&m, 1, 0, (uint64_t)da, 16);
            }
            pump(20);
            char rb[4];
            while (syscall6(SYS_RECVFROM, (uint64_t)u1, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1) a1++;
            while (syscall6(SYS_RECVFROM, (uint64_t)u2, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1) a2++;
            check((a1 == 6 && a2 == 0) || (a1 == 0 && a2 == 6), "H: one sender always reaches the same socket");
            syscall1(SYS_CLOSE, (uint64_t)snd);
        }
        syscall1(SYS_CLOSE, (uint64_t)u1);
        {
            int64_t snd = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
            char m = 'q', rb[4];
            syscall6(SYS_SENDTO, (uint64_t)snd, (uint64_t)&m, 1, 0, (uint64_t)da, 16);
            pump(20);
            check(syscall6(SYS_RECVFROM, (uint64_t)u2, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1, "H: after one socket closes the other still receives");
            syscall1(SYS_CLOSE, (uint64_t)snd);
        }
        syscall1(SYS_CLOSE, (uint64_t)u2);
        syscall1(SYS_CLOSE, (uint64_t)uplain);
        /* SO_REUSEADDR on both: the newest socket takes unicast datagrams */
        int64_t r1 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0), r2 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0), r3 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        reuse(r1); reuse(r2);
        check(bind4(r1, 18402) == 0 && bind4(r2, 18402) == 0, "H: two SO_REUSEADDR UDP sockets share a port");
        check(bind4(r3, 18402) == -EADDRINUSE_, "H: a third without SO_REUSEADDR cannot");
        {
            uint8_t ra[16];
            mk_addr(ra, 18402);
            int64_t snd = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
            char m = 'r', rb[4];
            syscall6(SYS_SENDTO, (uint64_t)snd, (uint64_t)&m, 1, 0, (uint64_t)ra, 16);
            pump(20);
            int g1 = (int)syscall6(SYS_RECVFROM, (uint64_t)r1, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0);
            int g2 = (int)syscall6(SYS_RECVFROM, (uint64_t)r2, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0);
            check(g2 == 1 && g1 != 1, "H: with SO_REUSEADDR the most recently bound socket receives the datagram");
            syscall1(SYS_CLOSE, (uint64_t)snd);
        }
        /* a connect()ed socket on a shared port receives every datagram from its peer, and nothing from anyone else (Linux, measured) */
        {
            int64_t k1 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0), k2 = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
            reuseport(k1); reuseport(k2);
            check(bind4(k1, 18403) == 0 && bind4(k2, 18403) == 0, "H: two SO_REUSEPORT sockets for the connected-socket rule");
            int64_t peer = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0), stranger = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
            check(bind4(peer, 18404) == 0 && bind4(stranger, 18405) == 0, "H: a peer and a stranger");
            uint8_t pa[16], ka[16];
            mk_addr(pa, 18404);
            mk_addr(ka, 18403);
            check(syscall3(SYS_CONNECT, (uint64_t)k2, (uint64_t)pa, 16) == 0, "H: the second socket connects to the peer");
            int from_peer_k2 = 0, from_peer_k1 = 0, from_stranger_k2 = 0, from_stranger_k1 = 0;
            char rb[4];
            for (int i = 0; i < 6; i++) {
                char m = 'p';
                syscall6(SYS_SENDTO, (uint64_t)peer, (uint64_t)&m, 1, 0, (uint64_t)ka, 16);
                pump(10);
                if (syscall6(SYS_RECVFROM, (uint64_t)k2, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1) from_peer_k2++;
                if (syscall6(SYS_RECVFROM, (uint64_t)k1, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1) from_peer_k1++;
                m = 's';
                syscall6(SYS_SENDTO, (uint64_t)stranger, (uint64_t)&m, 1, 0, (uint64_t)ka, 16);
                pump(10);
                if (syscall6(SYS_RECVFROM, (uint64_t)k2, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1) from_stranger_k2++;
                if (syscall6(SYS_RECVFROM, (uint64_t)k1, (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1) from_stranger_k1++;
            }
            check(from_peer_k2 == 6 && from_peer_k1 == 0, "H: every datagram from the peer goes to the socket connected to it");
            check(from_stranger_k2 == 0 && from_stranger_k1 == 6, "H: and a datagram from anyone else never reaches the connected socket");
            syscall1(SYS_CLOSE, (uint64_t)k1); syscall1(SYS_CLOSE, (uint64_t)k2); syscall1(SYS_CLOSE, (uint64_t)peer); syscall1(SYS_CLOSE, (uint64_t)stranger);
        }
        /* a socket that closes frees its share; the port is released with the last one */
        syscall1(SYS_CLOSE, (uint64_t)r1); syscall1(SYS_CLOSE, (uint64_t)r2);
        check(bind4(r3, 18402) == 0, "H: once every sharer closed the port can be bound by anyone");
        syscall1(SYS_CLOSE, (uint64_t)r3);
    }


    /* K: many UDP sockets at once. Linux opens hundreds; this kernel's port table was 16 entries, so the 17th socket() failed. 40 are opened
     * here, each bound to its own port and each receiving one datagram. */
    {
        int64_t us[40];
        int opened = 0, recvd = 0;
        for (int i = 0; i < 40; i++) {
            us[i] = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
            if (us[i] >= 0 && bind4(us[i], 18500 + i) == 0) opened++;
        }
        { char d[48] = "hello183: K opened NN UDP sockets\n"; d[19] = (char)('0' + opened / 10); d[20] = (char)('0' + opened % 10); print(d); }
        check(opened == 40, "K: forty UDP sockets can be open and bound at once");
        int64_t snd = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        for (int i = 0; i < 40; i++) {
            uint8_t da[16];
            mk_addr(da, 18500 + i);
            char m = (char)('A' + i % 26);
            syscall6(SYS_SENDTO, (uint64_t)snd, (uint64_t)&m, 1, 0, (uint64_t)da, 16);
            if (i % 8 == 7) pump(10);   /* the loopback queue holds 16 frames; let it drain */
        }
        pump(50);
        for (int i = 0; i < 40; i++) {
            char rb[4];
            if (us[i] >= 0 && syscall6(SYS_RECVFROM, (uint64_t)us[i], (uint64_t)rb, 4, MSG_DONTWAIT, 0, 0) == 1 && rb[0] == (char)('A' + i % 26)) recvd++;
        }
        check(recvd == 40, "K: and each receives the datagram sent to its own port");
        for (int i = 0; i < 40; i++) if (us[i] >= 0) syscall1(SYS_CLOSE, (uint64_t)us[i]);
        syscall1(SYS_CLOSE, (uint64_t)snd);
    }

    /* J: the owner uid of a SO_REUSEPORT port group is the one recorded at bind(). An unprivileged child binds, forks a grandchild that keeps the
     * socket open, and exits; the socket outlives the task that bound it. A live owner lookup then finds no task (uid 0) and would let the
     * parent (uid 0) join; Linux keeps the binder's uid with the socket and refuses. The grandchild reports through a file and exits later. */
    {
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h183j");
        int64_t jk = syscall1(SYS_FORK, 0);
        if (jk == 0) {
            failures = 0;
            syscall1(SYS_SETUID, 1000);
            int64_t s1 = sock4();
            reuseport(s1);
            int64_t r1 = bind4(s1, 18397);
            int64_t gk = syscall1(SYS_FORK, 0);
            if (gk == 0) {
                pump(50);
                int64_t wf = syscall3(SYS_OPEN, (uint64_t)"/tmp/h183j", 0x241, 0644);
                if (wf >= 0) { char c = (char)(r1 == 0 ? 'y' : 'n'); syscall3(SYS_WRITE, (uint64_t)wf, (uint64_t)&c, 1); syscall1(SYS_CLOSE, (uint64_t)wf); }
                pump(800);   /* keep the socket open after its binder exited */
                syscall1(SYS_CLOSE, (uint64_t)s1);
                syscall1(SYS_EXIT, 0);
                for (;;) {}
            }
            syscall1(SYS_EXIT, 0);   /* the binding task goes away; the socket lives on in the grandchild */
            for (;;) {}
        }
        int st2 = 0;
        syscall3(SYS_WAITPID, (uint64_t)jk, (uint64_t)&st2, 0);
        char got = 0;
        for (int i = 0; i < 400 && got == 0; i++) {
            int64_t rf = syscall3(SYS_OPEN, (uint64_t)"/tmp/h183j", 0, 0);
            if (rf >= 0) { if (syscall3(SYS_READ, (uint64_t)rf, (uint64_t)&got, 1) != 1) got = 0; syscall1(SYS_CLOSE, (uint64_t)rf); }
            if (got == 0) pump(10);
        }
        check(got == 'y', "J: the unprivileged child bound its SO_REUSEPORT port");
        int64_t s2 = sock4();
        reuseport(s2);
        check(bind4(s2, 18397) == -EADDRINUSE_, "J: after the binding task exited, a socket from another user still cannot join the group");
        syscall1(SYS_CLOSE, (uint64_t)s2);
        pump(900);   /* let the grandchild close the socket before the next sections */
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h183j");
    }

    syscall1(SYS_CLOSE, b);
    print(failures == 0 ? "hello183: PASS\n" : "hello183: FAIL\n");
    print("hello183 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
