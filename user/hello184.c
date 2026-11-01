/// hello184: TCP errno conformance for calls made in the wrong socket state.

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
#define SYS_NANOSLEEP 35
#define SYS_ACCEPT    43
#define SYS_SHUTDOWN  48
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define SYS_CONNECT   124
#define SYS_GETSOCKNAME 126
#define SYS_GETPEERNAME 127
#define SYS_ACCEPT4   131
#define SYS_GETSOCKOPT 133
#define SYS_FCNTL     142
#define SYS_RT_SIGACTION 13
#define AF_INET 2
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_NONBLOCK 0x800
#define SOCK_CLOEXEC 0x80000
#define SOL_SOCKET 1
#define SO_ACCEPTCONN 30
#define F_GETFD 1
#define F_GETFL 3
#define O_NONBLOCK 0x800
#define EINVAL_ 22
#define EPIPE_ 32
#define EAFNOSUPPORT_ 97
#define EISCONN_ 106
#define ENOTCONN_ 107

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello184:   ok   " : "hello184:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static void mk_addr(uint8_t *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = 2; a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port; a[4] = 127; a[7] = 1;
}
/* A sockaddr_in exactly as a Linux program fills it: sin_family = AF_INET stored little-endian (02 00). */
static void mk_addr_abi(uint8_t *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = AF_INET; a[1] = 0;
    a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port; a[4] = 127; a[7] = 1;
}
static int64_t sock4(void) { return syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0); }
static int get_int(int64_t fd, int name) {
    int v = -12345;
    uint32_t l = 4;
    if (syscall5(SYS_GETSOCKOPT, (uint64_t)fd, SOL_SOCKET, (uint64_t)name, (uint64_t)&v, (uint64_t)&l) != 0) return -99999;
    return v;
}

void _start(void) {
    print("hello184: TCP errno conformance\n");
    uint64_t act[4] = { 1, 0, 0, 0 }; /* SIGPIPE ignored: the EPIPE results are visible */
    syscall4(SYS_RT_SIGACTION, 13, (uint64_t)act, 0, 8);
    uint8_t sa[16];
    char b[16];

    /* A: an unconnected stream socket */
    int64_t u = sock4();
    uint8_t name[28];
    uint32_t nl = sizeof(name);
    check(syscall3(SYS_GETPEERNAME, (uint64_t)u, (uint64_t)name, (uint64_t)&nl) == -ENOTCONN_, "A: getpeername on an unconnected socket is ENOTCONN");
    check(syscall2(SYS_SHUTDOWN, (uint64_t)u, 1) == -ENOTCONN_, "A: shutdown on an unconnected socket is ENOTCONN");
    check(syscall6(SYS_RECVFROM, (uint64_t)u, (uint64_t)b, 16, 0, 0, 0) == -ENOTCONN_, "A: recv on an unconnected socket is ENOTCONN");
    check(syscall6(SYS_SENDTO, (uint64_t)u, (uint64_t)"x", 1, 0, 0, 0) == -EPIPE_, "A: send on an unconnected socket is EPIPE");
    check(syscall4(SYS_ACCEPT4, (uint64_t)u, 0, 0, 0) == -EINVAL_, "A: accept on a socket that is not listening is EINVAL");
    check(syscall2(SYS_LISTEN, (uint64_t)u, 4) == -98 || syscall2(SYS_LISTEN, (uint64_t)u, 4) >= -98, "A: (listen before bind picks a port or fails; not asserted)");

    /* B: wrong address family and short addresses */
    {
        uint8_t bad[16];
        mk_addr(bad, 18484);
        bad[0] = AF_UNIX; bad[1] = 0;
        check(syscall3(SYS_CONNECT, (uint64_t)u, (uint64_t)bad, 16) == -EAFNOSUPPORT_, "B: connect with a non-AF_INET address is EAFNOSUPPORT");
        mk_addr(sa, 18484);
        check(syscall3(SYS_CONNECT, (uint64_t)u, (uint64_t)sa, 8) == -EINVAL_, "B: connect with a too-short address is EINVAL");
        check(syscall3(SYS_BIND, (uint64_t)u, (uint64_t)sa, 8) == -EINVAL_, "B: bind with a too-short address is EINVAL");
        check(syscall3(SYS_BIND, (uint64_t)u, (uint64_t)bad, 16) == -EAFNOSUPPORT_, "B: bind with a non-AF_INET address is EAFNOSUPPORT");
    }

    /* B2: the real Linux layout (family 02 00) is what programs actually pass */
    {
        uint8_t abi[16];
        mk_addr_abi(abi, 18486);
        int64_t l = sock4();
        check(syscall3(SYS_BIND, (uint64_t)l, (uint64_t)abi, 16) == 0, "B2: bind with a Linux-layout sockaddr_in (family bytes 02 00)");
        check(syscall2(SYS_LISTEN, (uint64_t)l, 4) == 0, "B2: listen");
        int64_t k = sock4();
        int64_t cr = syscall3(SYS_CONNECT, (uint64_t)k, (uint64_t)abi, 16);
        for (int i = 0; i < 20 && cr < 0 && cr != -EISCONN_; i++) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); cr = syscall3(SYS_CONNECT, (uint64_t)k, (uint64_t)abi, 16); }
        check(cr == 0 || cr == -EISCONN_, "B2: connect with a Linux-layout sockaddr_in");
        syscall1(SYS_CLOSE, k);
        syscall1(SYS_CLOSE, l);
    }

    /* C: a listener */
    int64_t srv = sock4();
    mk_addr(sa, 18485);
    check(syscall3(SYS_BIND, (uint64_t)srv, (uint64_t)sa, 16) == 0, "C: bind");
    check(syscall2(SYS_LISTEN, (uint64_t)srv, 4) == 0, "C: listen");
    check(get_int(srv, SO_ACCEPTCONN) == 1, "C: SO_ACCEPTCONN is 1 on a listener");
    check(get_int(u, SO_ACCEPTCONN) == 0, "C: and 0 elsewhere");
    check(syscall6(SYS_RECVFROM, (uint64_t)srv, (uint64_t)b, 16, 0, 0, 0) == -ENOTCONN_, "C: recv on a listening socket is ENOTCONN");
    check(syscall6(SYS_SENDTO, (uint64_t)srv, (uint64_t)"x", 1, 0, 0, 0) == -EPIPE_, "C: send on a listening socket is EPIPE");
    check(syscall2(SYS_LISTEN, (uint64_t)srv, 4) == 0, "C: listen again is accepted");

    /* D: an established connection */
    int64_t cl = sock4();
    int64_t r = syscall3(SYS_CONNECT, (uint64_t)cl, (uint64_t)sa, 16);
    for (int i = 0; i < 20 && r < 0 && r != -EISCONN_; i++) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); r = syscall3(SYS_CONNECT, (uint64_t)cl, (uint64_t)sa, 16); }
    check(r == 0 || r == -EISCONN_, "D: connect to the listener");
    int64_t conn = -1;
    for (int i = 0; i < 20 && conn < 0; i++) { syscall1(SYS_NETPOLL, 0); conn = syscall4(SYS_ACCEPT4, (uint64_t)srv, 0, 0, SOCK_NONBLOCK | SOCK_CLOEXEC); }
    check(conn >= 0, "D: accept4(SOCK_NONBLOCK|SOCK_CLOEXEC)");
    if (conn >= 0) {
        check((syscall3(SYS_FCNTL, (uint64_t)conn, F_GETFL, 0) & O_NONBLOCK) != 0, "D: the accepted socket is non-blocking");
        check((syscall3(SYS_FCNTL, (uint64_t)conn, F_GETFD, 0) & 1) != 0, "D: and close-on-exec");
    }
    check(syscall3(SYS_CONNECT, (uint64_t)cl, (uint64_t)sa, 16) == -EISCONN_, "D: connect on an established socket is EISCONN");
    check(syscall2(SYS_LISTEN, (uint64_t)cl, 4) == -EINVAL_, "D: listen on an established socket is EINVAL");
    check(syscall3(SYS_BIND, (uint64_t)cl, (uint64_t)sa, 16) == -EINVAL_, "D: bind on an established socket is EINVAL");
    check(syscall4(SYS_ACCEPT4, (uint64_t)cl, 0, 0, 0) == -EINVAL_, "D: accept on an established socket is EINVAL");
    nl = sizeof(name);
    check(syscall3(SYS_GETPEERNAME, (uint64_t)cl, (uint64_t)name, (uint64_t)&nl) == 0 && nl == 16 && name[2] == (18485 >> 8) && name[3] == (18485 & 0xff), "D: getpeername reports the listener's port");

    /* E: after shutdown(SHUT_WR) */
    check(syscall2(SYS_SHUTDOWN, (uint64_t)cl, 1) == 0, "E: shutdown(SHUT_WR)");
    check(syscall6(SYS_SENDTO, (uint64_t)cl, (uint64_t)"x", 1, 0, 0, 0) == -EPIPE_, "E: send after SHUT_WR is EPIPE");
    check(syscall2(SYS_SHUTDOWN, (uint64_t)cl, 1) == 0, "E: and a second shutdown is harmless");

    syscall1(SYS_CLOSE, u);
    syscall1(SYS_CLOSE, srv);
    syscall1(SYS_CLOSE, cl);
    if (conn >= 0) syscall1(SYS_CLOSE, conn);
    print(failures == 0 ? "hello184: PASS\n" : "hello184: FAIL\n");
    print("hello184 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
