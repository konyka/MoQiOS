/// hello134: socket(2) type flags and AF_UNIX stream/datagram error semantics.

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
#define SYS_FCNTL     142
#define SYS_SOCKET    41
#define SYS_CONNECT   42
#define SYS_ACCEPT    43
#define SYS_SENDTO    44
#define SYS_RECVFROM  45
#define SYS_SHUTDOWN  48
#define SYS_BIND      49
#define SYS_LISTEN    50
#define SYS_SOCKETPAIR 53
#define SYS_UNLINK    87
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_RT_SIGACTION 13

#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM  2
#define SOCK_NONBLOCK 0x800
#define SOCK_CLOEXEC  0x80000
#define F_GETFD 1
#define F_GETFL 3
#define O_NONBLOCK 0x800
#define FD_CLOEXEC 1

#define EBADF_  9
#define EAGAIN_ 11
#define EINVAL_ 22
#define EPIPE_  32
#define ENOTSOCK_ 88
#define EPROTONOSUPPORT_ 93
#define EAFNOSUPPORT_ 97
#define EADDRINUSE_ 98
#define ENOTCONN_ 107
#define ECONNREFUSED_ 111
#define EISCONN_ 106
#define ENOENT_ 2

struct sockaddr_un { uint16_t family; char path[108]; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello134:   ok   " : "hello134:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static uint64_t mkaddr(struct sockaddr_un *a, const char *path) {
    a->family = AF_UNIX;
    int i = 0;
    while (path[i] && i < 107) { a->path[i] = path[i]; i++; }
    a->path[i] = 0;
    return 2 + i + 1;
}
static int64_t sendto0(int64_t fd, const char *b, uint64_t n) {
    return syscall6(SYS_SENDTO, (uint64_t)fd, (uint64_t)b, n, 0, 0, 0);
}
static int64_t recvfrom0(int64_t fd, char *b, uint64_t n) {
    return syscall6(SYS_RECVFROM, (uint64_t)fd, (uint64_t)b, n, 0, 0, 0);
}
static void sleep_ms(int ms) {
    struct { int64_t s, n; } t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}

void _start(void) {
    print("hello134: sockets\n");
    uint64_t act[4] = { 1, 0, 0, 0 }; /* SIGPIPE ignored: writes report EPIPE */
    syscall4(SYS_RT_SIGACTION, 13, (uint64_t)act, 0, 8);

    /* A: socket() arguments */
    int64_t s = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    check(s >= 0, "A: socket(AF_UNIX, SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK) is accepted");
    check(s >= 0 && syscall3(SYS_FCNTL, (uint64_t)s, F_GETFD, 0) == FD_CLOEXEC, "A: SOCK_CLOEXEC sets FD_CLOEXEC");
    check(s >= 0 && (syscall3(SYS_FCNTL, (uint64_t)s, F_GETFL, 0) & O_NONBLOCK) != 0, "A: SOCK_NONBLOCK sets O_NONBLOCK");
    if (s >= 0) syscall1(SYS_CLOSE, (uint64_t)s);
    int64_t plain = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
    check(plain >= 0 && syscall3(SYS_FCNTL, (uint64_t)plain, F_GETFD, 0) == 0, "A: without the flags FD_CLOEXEC is clear");
    if (plain >= 0) syscall1(SYS_CLOSE, (uint64_t)plain);
    check(syscall3(SYS_SOCKET, 99, SOCK_STREAM, 0) == -EAFNOSUPPORT_, "A: an unknown address family is EAFNOSUPPORT");
    check(syscall3(SYS_SOCKET, AF_UNIX, 77, 0) == -EINVAL_, "A: an unknown socket type is EINVAL");
    check(syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM | 0x100000, 0) == -EINVAL_, "A: unknown type flag bits are EINVAL");
    check(syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 5) == -EPROTONOSUPPORT_, "A: a protocol that does not exist for AF_UNIX is EPROTONOSUPPORT");
    check(syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0) >= 0, "A: protocol 0 is accepted");

    /* B: operations on things that are not sockets / bad fds */
    check(syscall3(SYS_LISTEN, 999, 1, 0) == -EBADF_, "B: listen on a bad fd is EBADF");
    check(syscall2(SYS_SHUTDOWN, 999, 1) == -EBADF_, "B: shutdown on a bad fd is EBADF");
    check(sendto0(999, "x", 1) == -EBADF_, "B: sendto on a bad fd is EBADF");
    check(syscall3(SYS_ACCEPT, 999, 0, 0) == -EBADF_, "B: accept on a bad fd is EBADF");
    check(syscall3(SYS_LISTEN, 1, 1, 0) == -ENOTSOCK_, "B: listen on stdout is ENOTSOCK");

    /* C: AF_UNIX stream server and client */
    const char *path = "/tmp/h134.sock";
    syscall1(SYS_UNLINK, (uint64_t)path);
    struct sockaddr_un addr;
    uint64_t alen = mkaddr(&addr, path);
    int64_t srv = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    int64_t cli0 = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    check(syscall3(SYS_CONNECT, (uint64_t)cli0, (uint64_t)&addr, alen) == -ECONNREFUSED_ || syscall3(SYS_CONNECT, (uint64_t)cli0, (uint64_t)&addr, alen) == -ENOENT_, "C: connect to a path nobody listens on fails (ECONNREFUSED/ENOENT)");
    syscall1(SYS_CLOSE, (uint64_t)cli0);
    check(syscall3(SYS_LISTEN, (uint64_t)srv, 4, 0) == -EINVAL_, "C: listen before bind is EINVAL");
    check(syscall3(SYS_BIND, (uint64_t)srv, (uint64_t)&addr, alen) == 0, "C: bind");
    int64_t dup = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    check(syscall3(SYS_BIND, (uint64_t)dup, (uint64_t)&addr, alen) == -EADDRINUSE_, "C: binding a second socket to the same path is EADDRINUSE");
    syscall1(SYS_CLOSE, (uint64_t)dup);
    check(syscall3(SYS_BIND, (uint64_t)srv, (uint64_t)&addr, alen) == -EINVAL_, "C: binding an already bound socket is EINVAL");
    check(syscall3(SYS_LISTEN, (uint64_t)srv, 4, 0) == 0, "C: listen");
    int64_t unbound = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    check(sendto0(unbound, "x", 1) == -ENOTCONN_ || sendto0(unbound, "x", 1) == -EPIPE_, "C: sending on an unconnected stream socket fails (ENOTCONN/EPIPE)");
    syscall1(SYS_CLOSE, (uint64_t)unbound);

    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        int64_t c = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
        int ok = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)&addr, alen) == 0;
        ok = ok && sendto0(c, "hello", 5) == 5;
        char b[8] = {0};
        ok = ok && syscall3(SYS_READ, (uint64_t)c, (uint64_t)b, 4) == 4 && b[0] == 'p' && b[3] == 'g';
        syscall1(SYS_CLOSE, (uint64_t)c);
        syscall1(SYS_EXIT, ok ? 0 : 1);
        for (;;) {}
    }
    int64_t conn = syscall3(SYS_ACCEPT, (uint64_t)srv, 0, 0);
    check(conn >= 0, "C: accept returns a connected socket");
    char buf[16] = {0};
    check(conn >= 0 && syscall3(SYS_READ, (uint64_t)conn, (uint64_t)buf, 16) == 5 && buf[0] == 'h' && buf[4] == 'o', "C: the server reads what the client sent");
    check(conn >= 0 && sendto0(conn, "pong", 4) == 4, "C: the server replies");
    int status = -1;
    syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0);
    check(((status >> 8) & 0xff) == 0, "C: the client saw the reply and exited cleanly");
    /* the peer has closed: read returns 0 (EOF), write is EPIPE */
    check(conn >= 0 && syscall3(SYS_READ, (uint64_t)conn, (uint64_t)buf, 16) == 0, "C: after the peer closed, read returns 0");
    check(conn >= 0 && sendto0(conn, "x", 1) == -EPIPE_, "C: and write is EPIPE");
    if (conn >= 0) syscall1(SYS_CLOSE, (uint64_t)conn);

    /* D0: blocking semantics. A blocking recv/accept must wait for the peer, not
     * return EAGAIN. The client starts after a delay, the server is already waiting. */
    {
        const char *path2 = "/tmp/h134b.sock";
        struct sockaddr_un addr2;
        uint64_t alen2 = mkaddr(&addr2, path2);
        int64_t srv2 = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
        int64_t br = syscall3(SYS_BIND, (uint64_t)srv2, (uint64_t)&addr2, alen2);
        int64_t lr = syscall3(SYS_LISTEN, (uint64_t)srv2, 4, 0);
        check(br == 0 && lr == 0, "D0: bind and listen a second server on the same path after the first one closed");
        int64_t kid = syscall1(SYS_FORK, 0);
        if (kid == 0) {
            sleep_ms(80);
            int64_t c = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
            int ok = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)&addr2, alen2) == 0;
            sleep_ms(80);
            ok = ok && sendto0(c, "late", 4) == 4;
            sleep_ms(80);
            syscall1(SYS_CLOSE, (uint64_t)c);
            syscall1(SYS_EXIT, ok ? 0 : 1);
            for (;;) {}
        }
        int64_t cn = syscall3(SYS_ACCEPT, (uint64_t)srv2, 0, 0);
        check(cn >= 0, "D0: a blocking accept waits for the client instead of returning EAGAIN");
        char lb[8] = {0};
        int64_t rn = cn >= 0 ? syscall3(SYS_READ, (uint64_t)cn, (uint64_t)lb, 8) : -1;
        check(rn == 4 && lb[0] == 'l' && lb[3] == 'e', "D0: a blocking read waits for data instead of returning EAGAIN");
        rn = cn >= 0 ? syscall3(SYS_READ, (uint64_t)cn, (uint64_t)lb, 8) : -1;
        check(rn == 0, "D0: and returns 0 (EOF) once the peer closes");
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
        check(((st >> 8) & 0xff) == 0, "D0: the client ran to completion");
        if (cn >= 0) syscall1(SYS_CLOSE, (uint64_t)cn);
        syscall1(SYS_CLOSE, (uint64_t)srv2);
        syscall1(SYS_UNLINK, (uint64_t)path2);
    }

    /* D: a non-blocking accept with nothing waiting */
    syscall3(SYS_FCNTL, (uint64_t)srv, 4 /* F_SETFL */, O_NONBLOCK);
    check(syscall3(SYS_ACCEPT, (uint64_t)srv, 0, 0) == -EAGAIN_, "D: a non-blocking accept with no client is EAGAIN");
    syscall1(SYS_CLOSE, (uint64_t)srv);
    syscall1(SYS_UNLINK, (uint64_t)path);

    /* E: datagrams keep their message boundaries */
    {
        const char *pa = "/tmp/h134-a.sock", *pb = "/tmp/h134-b.sock";
        struct sockaddr_un aa, ab;
        uint64_t la = mkaddr(&aa, pa), lb = mkaddr(&ab, pb);
        syscall1(SYS_UNLINK, (uint64_t)pa); syscall1(SYS_UNLINK, (uint64_t)pb);
        int64_t da = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0), db = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
        check(syscall3(SYS_BIND, (uint64_t)da, (uint64_t)&aa, la) == 0 && syscall3(SYS_BIND, (uint64_t)db, (uint64_t)&ab, lb) == 0, "E: bind two datagram sockets");
        check(syscall3(SYS_CONNECT, (uint64_t)da, (uint64_t)&ab, lb) == 0, "E: connect the first to the second");
        check(sendto0(da, "abc", 3) == 3 && sendto0(da, "de", 2) == 2, "E: two datagrams are sent");
        char d1[8] = {0}, d2[8] = {0};
        check(recvfrom0(db, d1, 8) == 3 && d1[0] == 'a' && d1[2] == 'c', "E: the first recv returns exactly the first datagram (message boundaries)");
        check(recvfrom0(db, d2, 8) == 2 && d2[0] == 'd' && d2[1] == 'e', "E: the second recv returns the second datagram");
        syscall1(SYS_CLOSE, (uint64_t)da); syscall1(SYS_CLOSE, (uint64_t)db);
        syscall1(SYS_UNLINK, (uint64_t)pa); syscall1(SYS_UNLINK, (uint64_t)pb);
    }
    {
        int sv[2] = { -1, -1 };
        check(syscall4(SYS_SOCKETPAIR, AF_INET, SOCK_STREAM, 0, (uint64_t)sv) < 0, "E: socketpair of AF_INET is refused");
        check(syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, 0) == -14, "E: socketpair with a NULL result pointer is EFAULT");
    }

    print(failures == 0 ? "hello134: PASS\n" : "hello134: FAIL\n");
    print("hello134 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
