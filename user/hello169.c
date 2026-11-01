/// hello169: socket(AF_UNIX, SOCK_SEQPACKET) with bind/listen/connect/accept.

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
#define SYS_SOCKET    41
#define SYS_CONNECT   42
#define SYS_ACCEPT    43
#define SYS_BIND      49
#define SYS_LISTEN    50
#define SYS_RECVFROM  122
#define SYS_GETSOCKOPT 133
#define SYS_UNLINK    87
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_SEQPACKET 5
#define SOL_SOCKET 1
#define SO_TYPE 3
#define MSG_TRUNC 0x20
#define EINVAL_ 22
#define EPROTOTYPE_ 91
#define ECONNREFUSED_ 111

struct sockaddr_un { uint16_t family; char path[108]; };
struct ts { int64_t s, n; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello169:   ok   " : "hello169:   FAIL ");
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
static int sock_type(int64_t fd) {
    int ty = 0;
    uint32_t len = 4;
    syscall5(SYS_GETSOCKOPT, (uint64_t)fd, SOL_SOCKET, SO_TYPE, (uint64_t)&ty, (uint64_t)&len);
    return ty;
}

void _start(void) {
    print("hello169: socket(AF_UNIX, SOCK_SEQPACKET) listen/connect/accept\n");
    char b[64];
    struct sockaddr_un addr, addr2;
    uint64_t alen = mkaddr(&addr, "/tmp/h169.sock");
    uint64_t alen2 = mkaddr(&addr2, "/tmp/h169b.sock");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h169.sock");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h169b.sock");

    int64_t srv = syscall3(SYS_SOCKET, AF_UNIX, SOCK_SEQPACKET, 0);
    check(srv >= 0, "A: socket(AF_UNIX, SOCK_SEQPACKET) succeeds");
    if (srv < 0) goto done;
    check(sock_type(srv) == SOCK_SEQPACKET, "A: SO_TYPE reports SOCK_SEQPACKET (5)");
    check(syscall3(SYS_SOCKET, AF_INET, SOCK_SEQPACKET, 0) == -EINVAL_, "A: SOCK_SEQPACKET is still rejected for AF_INET");

    /* B: listen/accept need a bound listening socket */
    check(syscall3(SYS_LISTEN, (uint64_t)srv, 4, 0) == -EINVAL_, "B: listen before bind is EINVAL");
    check(syscall3(SYS_BIND, (uint64_t)srv, (uint64_t)&addr, alen) == 0, "B: bind");
    check(syscall3(SYS_ACCEPT, (uint64_t)srv, 0, 0) == -EINVAL_, "B: accept before listen is EINVAL");
    int64_t bound_only = syscall3(SYS_SOCKET, AF_UNIX, SOCK_SEQPACKET, 0);
    syscall3(SYS_BIND, (uint64_t)bound_only, (uint64_t)&addr2, alen2);
    int64_t c0 = syscall3(SYS_SOCKET, AF_UNIX, SOCK_SEQPACKET, 0);
    check(syscall3(SYS_CONNECT, (uint64_t)c0, (uint64_t)&addr2, alen2) == -ECONNREFUSED_, "B: connect to a bound but not listening socket is ECONNREFUSED");
    syscall1(SYS_CLOSE, (uint64_t)c0);
    syscall1(SYS_CLOSE, (uint64_t)bound_only);
    check(syscall3(SYS_LISTEN, (uint64_t)srv, 4, 0) == 0, "B: listen");

    /* C: a stream socket cannot connect to a seqpacket listener */
    int64_t cs = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    check(syscall3(SYS_CONNECT, (uint64_t)cs, (uint64_t)&addr, alen) == -EPROTOTYPE_, "C: SOCK_STREAM connect to a SOCK_SEQPACKET listener is EPROTOTYPE");
    syscall1(SYS_CLOSE, (uint64_t)cs);

    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        char c[16];
        int64_t cl = syscall3(SYS_SOCKET, AF_UNIX, SOCK_SEQPACKET, 0);
        int ok = syscall3(SYS_CONNECT, (uint64_t)cl, (uint64_t)&addr, alen) == 0;
        /* sent before the server accepts: must be kept, not lost */
        ok = ok && syscall3(SYS_WRITE, (uint64_t)cl, (uint64_t)"early", 5) == 5;
        ok = ok && syscall3(SYS_READ, (uint64_t)cl, (uint64_t)c, 16) == 3;
        ok = ok && syscall3(SYS_WRITE, (uint64_t)cl, (uint64_t)"aa", 2) == 2;
        ok = ok && syscall3(SYS_WRITE, (uint64_t)cl, (uint64_t)"bbb", 3) == 3;
        ok = ok && syscall3(SYS_WRITE, (uint64_t)cl, (uint64_t)"abcdefgh", 8) == 8;
        syscall1(SYS_CLOSE, (uint64_t)cl);
        syscall1(SYS_EXIT, ok ? 0 : 1);
        for (;;) {}
    }
    sleep_ms(150);
    int64_t conn = syscall3(SYS_ACCEPT, (uint64_t)srv, 0, 0);
    check(conn >= 0, "D: accept returns a connected socket");
    check(conn >= 0 && sock_type(conn) == SOCK_SEQPACKET, "D: the accepted socket is SOCK_SEQPACKET");
    check(conn >= 0 && syscall3(SYS_READ, (uint64_t)conn, (uint64_t)b, 64) == 5 && b[0] == 'e', "D: the record sent before accept() arrives whole (5 bytes)");
    check(conn >= 0 && syscall3(SYS_WRITE, (uint64_t)conn, (uint64_t)"ack", 3) == 3, "D: the server replies");
    check(conn >= 0 && syscall3(SYS_READ, (uint64_t)conn, (uint64_t)b, 64) == 2, "D: the first record read is 2 bytes");
    check(conn >= 0 && syscall3(SYS_READ, (uint64_t)conn, (uint64_t)b, 64) == 3, "D: the next record is 3 bytes");
    check(conn >= 0 && syscall6(SYS_RECVFROM, (uint64_t)conn, (uint64_t)b, 3, MSG_TRUNC, 0, 0) == 8, "D: recv(MSG_TRUNC) with a 3-byte buffer reports the record size (8)");
    check(conn >= 0 && syscall3(SYS_READ, (uint64_t)conn, (uint64_t)b, 64) == 0, "D: after the client closed, read returns 0 (EOF)");
    int status = -1;
    syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0);
    check(((status >> 8) & 0xff) == 0, "D: the client saw every reply and exited cleanly");
    if (conn >= 0) syscall1(SYS_CLOSE, (uint64_t)conn);
    syscall1(SYS_CLOSE, (uint64_t)srv);
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h169.sock");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h169b.sock");

done:
    print(failures == 0 ? "hello169: PASS\n" : "hello169: FAIL\n");
    print("hello169 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
