/// hello135: signal call argument and errno rules.

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
#define SYS_PIPE      22
#define SYS_SOCKET    41
#define SYS_SOCKETPAIR 53
#define SYS_SETSOCKOPT 132
#define SYS_GETSOCKOPT 133
#define SYS_GETPID    39
#define SYS_GETUID    201
#define SYS_GETGID    202
#define SYS_LISTEN    50
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_DEBUG 1
#define SO_REUSEADDR 2
#define SO_TYPE 3
#define SO_ERROR 4
#define SO_BROADCAST 6
#define SO_SNDBUF 7
#define SO_RCVBUF 8
#define SO_KEEPALIVE 9
#define SO_LINGER 13
#define SO_REUSEPORT 15
#define SO_PEERCRED 17
#define SO_ACCEPTCONN 30
#define SO_PROTOCOL 38
#define SO_DOMAIN 39
#define SO_RCVTIMEO 20
#define SO_SNDTIMEO 21
#define EBADF_ 9
#define EFAULT_ 14
#define EINVAL_ 22
#define ENOTSOCK_ 88
#define ENOPROTOOPT_ 92

struct ucred { int32_t pid; uint32_t uid; uint32_t gid; };
struct tv { int64_t s, us; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello143:   ok   " : "hello143:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t setopt(int fd, int lvl, int name, const void *v, uint64_t len) {
    return syscall5(SYS_SETSOCKOPT, (uint64_t)fd, (uint64_t)lvl, (uint64_t)name, (uint64_t)v, len);
}
static int64_t getopt(int fd, int lvl, int name, void *v, uint32_t *len) {
    return syscall5(SYS_GETSOCKOPT, (uint64_t)fd, (uint64_t)lvl, (uint64_t)name, (uint64_t)v, (uint64_t)len);
}
static int64_t get_int(int fd, int name, int *out) {
    uint32_t l = 4;
    *out = -12345;
    return getopt(fd, SOL_SOCKET, name, out, &l);
}
static int64_t set_int(int fd, int name, int v) { return setopt(fd, SOL_SOCKET, name, &v, 4); }

static void kind_checks(const char *tag, int fd, int domain, int type, int is_stream_unconnected) {
    (void)tag;
    int v;
    check(get_int(fd, SO_TYPE, &v) == 0 && v == type, "SO_TYPE reports the socket type");
    check(get_int(fd, SO_DOMAIN, &v) == 0 && v == domain, "SO_DOMAIN reports the address family");
    check(get_int(fd, SO_ERROR, &v) == 0 && v == 0, "SO_ERROR is 0 on a healthy socket");
    check(get_int(fd, SO_ACCEPTCONN, &v) == 0 && v == 0, "SO_ACCEPTCONN is 0 before listen");
    check(set_int(fd, SO_REUSEADDR, 1) == 0 && get_int(fd, SO_REUSEADDR, &v) == 0 && v != 0, "SO_REUSEADDR round-trips");
    check(set_int(fd, SO_REUSEADDR, 0) == 0 && get_int(fd, SO_REUSEADDR, &v) == 0 && v == 0, "and can be cleared");
    check(set_int(fd, SO_KEEPALIVE, 1) == 0 && get_int(fd, SO_KEEPALIVE, &v) == 0 && v != 0, "SO_KEEPALIVE round-trips");
    check(set_int(fd, SO_RCVBUF, 65536) == 0 && get_int(fd, SO_RCVBUF, &v) == 0 && v >= 65536, "SO_RCVBUF is at least what was asked");
    check(set_int(fd, SO_SNDBUF, 65536) == 0 && get_int(fd, SO_SNDBUF, &v) == 0 && v >= 65536, "SO_SNDBUF is at least what was asked");
    struct tv t = { 2, 500000 }, back = { 0, 0 };
    uint32_t l = 16;
    check(setopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, 16) == 0 && getopt(fd, SOL_SOCKET, SO_RCVTIMEO, &back, &l) == 0 && back.s == 2 && back.us == 500000, "SO_RCVTIMEO round-trips");
    check(setopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, 16) == 0 && getopt(fd, SOL_SOCKET, SO_SNDTIMEO, &back, &l) == 0 && back.s == 2, "SO_SNDTIMEO round-trips");
    check(set_int(fd, 9999, 1) == -ENOPROTOOPT_, "an unknown option is ENOPROTOOPT");
    check(setopt(fd, 9999, SO_REUSEADDR, &v, 4) == -ENOPROTOOPT_ || setopt(fd, 9999, SO_REUSEADDR, &v, 4) == -EINVAL_, "an unknown level is refused");
    check(setopt(fd, SOL_SOCKET, SO_REUSEADDR, &v, 2) == -EINVAL_, "a too-short optlen is EINVAL");
    check(setopt(fd, SOL_SOCKET, SO_REUSEADDR, 0, 4) == -EFAULT_, "a NULL optval is EFAULT");
    (void)is_stream_unconnected;
}

void _start(void) {
    print("hello143: socket options on every socket kind\n");
    int v;

    /* A: errno for non-sockets */
    {
        check(set_int(77, SO_REUSEADDR, 1) == -EBADF_, "A: a closed fd is EBADF");
        check(get_int(77, SO_TYPE, &v) == -EBADF_, "A: getsockopt on a closed fd is EBADF");
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        check(set_int(pp[0], SO_REUSEADDR, 1) == -ENOTSOCK_, "A: a pipe is ENOTSOCK");
        check(get_int(pp[0], SO_TYPE, &v) == -ENOTSOCK_, "A: getsockopt on a pipe is ENOTSOCK");
        syscall1(SYS_CLOSE, pp[0]);
        syscall1(SYS_CLOSE, pp[1]);
    }

    /* B: AF_UNIX stream socketpair */
    {
        int sv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);
        kind_checks("unix", sv[0], AF_UNIX, SOCK_STREAM, 0);
        struct ucred uc = { 0, 0, 0 };
        uint32_t l = 12;
        int64_t r = getopt(sv[0], SOL_SOCKET, SO_PEERCRED, &uc, &l);
        check(r == 0 && uc.pid == (int32_t)syscall1(SYS_GETPID, 0), "B: SO_PEERCRED reports the peer's pid");
        check(uc.uid == (uint32_t)syscall1(SYS_GETUID, 0) && uc.gid == (uint32_t)syscall1(SYS_GETGID, 0), "B: and its uid and gid");
        check(l == 12, "B: and optlen is sizeof(struct ucred)");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* C: AF_UNIX listener and datagram */
    {
        int64_t s = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
        check(s >= 0 && get_int((int)s, SO_ACCEPTCONN, &v) == 0 && v == 0, "C: a fresh stream socket is not listening");
        syscall1(SYS_CLOSE, s);
        int64_t d = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
        check(d >= 0 && get_int((int)d, SO_TYPE, &v) == 0 && v == SOCK_DGRAM, "C: an AF_UNIX datagram socket reports SOCK_DGRAM");
        syscall1(SYS_CLOSE, d);
    }

    /* D: UDP socket */
    {
        int64_t u = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
        check(u >= 0, "D: create a UDP socket");
        if (u >= 0) {
            kind_checks("udp", (int)u, AF_INET, SOCK_DGRAM, 0);
            check(set_int((int)u, SO_BROADCAST, 1) == 0 && get_int((int)u, SO_BROADCAST, &v) == 0 && v != 0, "D: SO_BROADCAST round-trips");
            check(set_int((int)u, SO_REUSEPORT, 1) == 0 && get_int((int)u, SO_REUSEPORT, &v) == 0 && v != 0, "D: SO_REUSEPORT round-trips");
            check(get_int((int)u, SO_PROTOCOL, &v) == 0 && v == 17, "D: SO_PROTOCOL is IPPROTO_UDP");
            syscall1(SYS_CLOSE, u);
        }
    }

    /* E: TCP socket reports the new read-only options too */
    {
        int64_t t = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
        check(t >= 0, "E: create a TCP socket");
        if (t >= 0) {
            check(get_int((int)t, SO_TYPE, &v) == 0 && v == SOCK_STREAM, "E: SO_TYPE on TCP");
            check(get_int((int)t, SO_DOMAIN, &v) == 0 && v == AF_INET, "E: SO_DOMAIN on TCP");
            check(get_int((int)t, SO_PROTOCOL, &v) == 0 && v == 6, "E: SO_PROTOCOL is IPPROTO_TCP");
            check(get_int((int)t, SO_ACCEPTCONN, &v) == 0 && v == 0, "E: SO_ACCEPTCONN is 0 before listen");
            check(set_int((int)t, SO_REUSEPORT, 1) == 0 && get_int((int)t, SO_REUSEPORT, &v) == 0 && v != 0, "E: SO_REUSEPORT round-trips on TCP");
            check(set_int((int)t, SO_BROADCAST, 1) == 0, "E: SO_BROADCAST is accepted on TCP (and ignored)");
            check(set_int((int)t, SO_DEBUG, 1) == 0, "E: SO_DEBUG is accepted");
            syscall1(SYS_CLOSE, t);
        }
    }

    print(failures == 0 ? "hello143: PASS\n" : "hello143: FAIL\n");
    print("hello143 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
