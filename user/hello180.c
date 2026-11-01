/// hello180: getsockname and getpeername on AF_UNIX sockets.

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
#define SYS_UNLINK    87
#define SYS_SOCKETPAIR 53
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_CONNECT   124
#define SYS_ACCEPT    43
#define SYS_GETSOCKNAME 126
#define SYS_GETPEERNAME 127
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define ENOTCONN_ 107

struct sockaddr_un { uint16_t family; char path[108]; };
struct ts { int64_t s, n; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello180:   ok   " : "hello180:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static uint64_t mkaddr(struct sockaddr_un *a, const char *path) {
    a->family = AF_UNIX;
    int i = 0;
    while (path[i] && i < 107) { a->path[i] = path[i]; i++; }
    a->path[i] = 0;
    return 2 + i + 1;
}
static int path_is(const struct sockaddr_un *a, const char *p) {
    int i = 0;
    while (p[i] && a->path[i] == p[i]) i++;
    return p[i] == 0 && a->path[i] == 0;
}

void _start(void) {
    print("hello180: getsockname / getpeername on AF_UNIX\n");
    struct sockaddr_un want, got;
    const char *path = "/tmp/h180.sock";
    syscall1(SYS_UNLINK, (uint64_t)path);
    uint64_t wlen = mkaddr(&want, path);
    uint32_t len;

    /* A: an unbound socket has the unnamed address: just the family */
    int64_t u = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    len = sizeof(got);
    for (unsigned i = 0; i < sizeof(got); i++) ((char *)&got)[i] = 0x55;
    check(syscall3(SYS_GETSOCKNAME, (uint64_t)u, (uint64_t)&got, (uint64_t)&len) == 0, "A: getsockname on an unbound AF_UNIX socket succeeds");
    check(len == 2 && got.family == AF_UNIX, "A: the unnamed address is the 2-byte family");
    len = sizeof(got);
    check(syscall3(SYS_GETPEERNAME, (uint64_t)u, (uint64_t)&got, (uint64_t)&len) == -ENOTCONN_, "A: getpeername on an unconnected socket is ENOTCONN");

    /* B: a bound socket reports its path; the length counts the terminator; a short buffer truncates but reports the full size */
    int64_t srv = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    check(syscall3(SYS_BIND, (uint64_t)srv, (uint64_t)&want, wlen) == 0, "B: bind");
    len = sizeof(got);
    for (unsigned i = 0; i < sizeof(got); i++) ((char *)&got)[i] = 0x55;
    check(syscall3(SYS_GETSOCKNAME, (uint64_t)srv, (uint64_t)&got, (uint64_t)&len) == 0 && got.family == AF_UNIX && path_is(&got, path), "B: getsockname returns family and the bound path");
    check(len == wlen, "B: and the length is family + path + NUL");
    {
        char small[8];
        for (int i = 0; i < 8; i++) small[i] = 0x55;
        uint32_t sl = 8;
        check(syscall3(SYS_GETSOCKNAME, (uint64_t)srv, (uint64_t)small, (uint64_t)&sl) == 0 && sl == wlen && small[2] == '/' && small[3] == 't', "B: a short buffer is truncated while the real length is reported");
    }
    check(syscall2(SYS_LISTEN, (uint64_t)srv, 4) == 0, "B: listen");

    /* C: connected pair: the client sees the server's path as its peer, the accepted socket sees the (unnamed) client */
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        failures = 0;
        int64_t c = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
        check(syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)&want, wlen) == 0, "C: client connect");
        struct sockaddr_un pn;
        uint32_t pl = sizeof(pn);
        check(syscall3(SYS_GETPEERNAME, (uint64_t)c, (uint64_t)&pn, (uint64_t)&pl) == 0 && pn.family == AF_UNIX && path_is(&pn, path) && pl == wlen, "C: the client's getpeername is the server's path");
        struct sockaddr_un sn;
        uint32_t sl = sizeof(sn);
        check(syscall3(SYS_GETSOCKNAME, (uint64_t)c, (uint64_t)&sn, (uint64_t)&sl) == 0 && sl == 2, "C: an unbound client's getsockname is the unnamed address");
        sleep_ms(100);
        syscall1(SYS_CLOSE, (uint64_t)c);
        syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
        for (;;) {}
    }
    int64_t conn = syscall3(SYS_ACCEPT, (uint64_t)srv, 0, 0);
    check(conn >= 0, "C: accept");
    len = sizeof(got);
    check(conn >= 0 && syscall3(SYS_GETPEERNAME, (uint64_t)conn, (uint64_t)&got, (uint64_t)&len) == 0 && len == 2, "C: the accepted socket's peer (an unbound client) is the unnamed address");
    len = sizeof(got);
    for (unsigned i = 0; i < sizeof(got); i++) ((char *)&got)[i] = 0x55;
    check(conn >= 0 && syscall3(SYS_GETSOCKNAME, (uint64_t)conn, (uint64_t)&got, (uint64_t)&len) == 0 && path_is(&got, path), "C: and its own name is the listener's path");
    int st = 0;
    syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&st, 0);
    check(((st >> 8) & 0xff) == 0 && (st & 0x7f) == 0, "C: the client's own checks passed");

    /* D: socketpair ends are unnamed; each knows its peer is unnamed too */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        len = sizeof(got);
        check(syscall3(SYS_GETSOCKNAME, (uint64_t)sv[0], (uint64_t)&got, (uint64_t)&len) == 0 && len == 2, "D: a socketpair end has the unnamed address");
        len = sizeof(got);
        check(syscall3(SYS_GETPEERNAME, (uint64_t)sv[0], (uint64_t)&got, (uint64_t)&len) == 0 && len == 2, "D: and so does its peer");
        syscall1(SYS_CLOSE, (uint64_t)sv[0]);
        len = sizeof(got);
        check(syscall3(SYS_GETPEERNAME, (uint64_t)sv[1], (uint64_t)&got, (uint64_t)&len) == -ENOTCONN_, "D: after the peer closed getpeername is ENOTCONN");
        syscall1(SYS_CLOSE, (uint64_t)sv[1]);
    }

    /* E: a bound datagram socket, and a connected datagram socket's peer */
    {
        struct sockaddr_un da;
        uint64_t dlen = mkaddr(&da, "/tmp/h180d.sock");
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h180d.sock");
        int64_t d1 = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
        int64_t d2 = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
        check(syscall3(SYS_BIND, (uint64_t)d1, (uint64_t)&da, dlen) == 0, "E: bind a datagram socket");
        check(syscall3(SYS_CONNECT, (uint64_t)d2, (uint64_t)&da, dlen) == 0, "E: connect another to it");
        len = sizeof(got);
        for (unsigned i = 0; i < sizeof(got); i++) ((char *)&got)[i] = 0x55;
        check(syscall3(SYS_GETPEERNAME, (uint64_t)d2, (uint64_t)&got, (uint64_t)&len) == 0 && path_is(&got, "/tmp/h180d.sock") && len == dlen, "E: the connected datagram socket's peer is the bound path");
        len = sizeof(got);
        check(syscall3(SYS_GETSOCKNAME, (uint64_t)d1, (uint64_t)&got, (uint64_t)&len) == 0 && path_is(&got, "/tmp/h180d.sock"), "E: the bound datagram socket reports its own path");
        syscall1(SYS_CLOSE, (uint64_t)d1);
        len = sizeof(got);
        check(syscall3(SYS_GETPEERNAME, (uint64_t)d2, (uint64_t)&got, (uint64_t)&len) == -ENOTCONN_, "E: once the datagram target is closed getpeername is ENOTCONN");
        /* a new socket may reuse the closed target's slot: it must not be reported as the peer */
        int64_t d3 = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
        len = sizeof(got);
        check(syscall3(SYS_GETPEERNAME, (uint64_t)d2, (uint64_t)&got, (uint64_t)&len) == -ENOTCONN_, "E: and an unrelated new socket is not mistaken for the peer");
        syscall1(SYS_CLOSE, (uint64_t)d3);
        syscall1(SYS_CLOSE, (uint64_t)d2);
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h180d.sock");
    }

    syscall1(SYS_CLOSE, (uint64_t)srv);
    syscall1(SYS_CLOSE, (uint64_t)u);
    syscall1(SYS_UNLINK, (uint64_t)path);
    print(failures == 0 ? "hello180: PASS\n" : "hello180: FAIL\n");
    print("hello180 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
