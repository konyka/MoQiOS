/// hello181: sendto()/sendmsg() with an explicit address on AF_UNIX datagram sockets; oversized datagrams are EMSGSIZE.

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
#define SYS_WAIT4     61
#define SYS_NANOSLEEP 35
#define SYS_KILL      62
#define SYS_UNLINK    87
#define SYS_FCNTL     142
#define SYS_SOCKET    41
#define SYS_CONNECT   42
#define SYS_SENDTO    44
#define SYS_RECVFROM  45
#define SYS_BIND      49
#define SYS_LISTEN    50
#define SYS_GETPEERNAME 127
#define SYS_SENDMSG   46
#define SYS_SENDMMSG  135
#define SYS_RECVMMSG  134
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_SEQPACKET 5
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define MSG_DONTWAIT 0x40
#define WNOHANG 1
#define EAGAIN_ 11
#define EMSGSIZE_ 90
#define EPROTOTYPE_ 91
#define EOPNOTSUPP_ 95
#define EISCONN_ 106
#define ENOTCONN_ 107
#define ECONNREFUSED_ 111

struct sockaddr_un { uint16_t family; char path[108]; };
struct ts { int64_t s, n; };
struct iovec { void *base; uint64_t len; };
struct msghdr { void *name; uint32_t namelen; uint32_t pad0; struct iovec *iov; uint64_t iovlen; void *ctl; uint64_t ctllen; int flags; int pad1; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello181:   ok   " : "hello181:   FAIL ");
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
static int64_t sendto_(int64_t fd, const void *b, uint64_t n, struct sockaddr_un *a, uint64_t alen) {
    return syscall6(SYS_SENDTO, (uint64_t)fd, (uint64_t)b, n, 0, (uint64_t)a, alen);
}
static int64_t recv_(int64_t fd, void *b, uint64_t n) {
    return syscall6(SYS_RECVFROM, (uint64_t)fd, (uint64_t)b, n, 0, 0, 0);
}
static int64_t bound_dgram(const char *path, struct sockaddr_un *a, uint64_t *alen) {
    syscall1(SYS_UNLINK, (uint64_t)path);
    *alen = mkaddr(a, path);
    int64_t s = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
    syscall3(SYS_BIND, (uint64_t)s, (uint64_t)a, *alen);
    syscall3(SYS_FCNTL, (uint64_t)s, F_SETFL, O_NONBLOCK);
    return s;
}

void _start(void) {
    print("hello181: AF_UNIX datagram sendto / sendmsg with an address\n");
    char b[64];
    struct sockaddr_un ra, rb;
    uint64_t la, lb;
    int64_t r1 = bound_dgram("/tmp/h181a.sock", &ra, &la);
    int64_t r2 = bound_dgram("/tmp/h181b.sock", &rb, &lb);

    /* A: an unconnected sender reaches a bound receiver by address (the syslog pattern) */
    int64_t tx = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
    check(syscall3(SYS_WRITE, tx, (uint64_t)"x", 1) == -ENOTCONN_, "A: a plain write on an unconnected datagram socket is still ENOTCONN");
    check(sendto_(tx, "hello", 5, &ra, la) == 5, "A: sendto(path) from an unconnected socket succeeds");
    check(recv_(r1, b, 64) == 5 && b[0] == 'h' && b[4] == 'o', "A: and the receiver gets the datagram");
    check(recv_(r2, b, 64) == -EAGAIN_, "A: the other receiver got nothing");
    uint32_t pl = 128;
    struct sockaddr_un pn;
    check(syscall3(SYS_GETPEERNAME, tx, (uint64_t)&pn, (uint64_t)&pl) == -ENOTCONN_, "A: sendto does not connect the sender");

    /* B: the same sender can address a second receiver */
    check(sendto_(tx, "second", 6, &rb, lb) == 6, "B: sendto a second path");
    check(recv_(r2, b, 64) == 6 && b[0] == 's', "B: it arrives there");
    check(recv_(r1, b, 64) == -EAGAIN_, "B: and not at the first");

    /* C: a connected datagram socket with an explicit address goes to that address */
    int64_t cx = syscall3(SYS_SOCKET, AF_UNIX, SOCK_DGRAM, 0);
    check(syscall3(SYS_CONNECT, cx, (uint64_t)&ra, la) == 0, "C: connect to the first receiver");
    check(sendto_(cx, "viaaddr", 7, &rb, lb) == 7, "C: sendto(other path) on a connected socket");
    check(recv_(r2, b, 64) == 7 && b[0] == 'v', "C: goes to the address, not the connected peer");
    check(recv_(r1, b, 64) == -EAGAIN_, "C: the connected peer got nothing");
    check(syscall3(SYS_WRITE, cx, (uint64_t)"plain", 5) == 5 && recv_(r1, b, 64) == 5, "C: a plain write still uses the connected peer");

    /* D: sendmsg with msg_name */
    {
        struct iovec iv = { "viamsg", 6 };
        struct msghdr mh = { &rb, (uint32_t)lb, 0, &iv, 1, 0, 0, 0, 0 };
        check(syscall3(SYS_SENDMSG, tx, (uint64_t)&mh, 0) == 6, "D: sendmsg with msg_name from an unconnected socket");
        check(recv_(r2, b, 64) == 6 && b[0] == 'v', "D: arrives at the named receiver");
    }

    /* E: errors */
    {
        struct sockaddr_un none;
        uint64_t ln = mkaddr(&none, "/tmp/h181-nobody.sock");
        check(sendto_(tx, "x", 1, &none, ln) == -ECONNREFUSED_, "E: sendto an address nobody is bound to is ECONNREFUSED");
        struct sockaddr_un sa;
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h181s.sock");
        uint64_t ls = mkaddr(&sa, "/tmp/h181s.sock");
        int64_t st = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
        syscall3(SYS_BIND, (uint64_t)st, (uint64_t)&sa, ls);
        syscall2(SYS_LISTEN, (uint64_t)st, 2);
        check(sendto_(tx, "x", 1, &sa, ls) == -EPROTOTYPE_, "E: a datagram sent to a stream socket's path is EPROTOTYPE");
        int64_t sx = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
        check(sendto_(sx, "x", 1, &sa, ls) == -EOPNOTSUPP_, "E: sendto with an address on an unconnected stream socket is EOPNOTSUPP");
        syscall1(SYS_CLOSE, sx);
        syscall1(SYS_CLOSE, st);
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h181s.sock");
    }

    /* F: a full receiver: nonblocking senders see EAGAIN, and space returns once it is read */
    {
        char big[1000];
        for (int i = 0; i < 1000; i++) big[i] = 'f';
        int sent = 0;
        int64_t r;
        while ((r = syscall6(SYS_SENDTO, tx, (uint64_t)big, 1000, MSG_DONTWAIT, (uint64_t)&ra, la)) == 1000 && sent < 100) sent++;
        check(sent >= 4 && sent < 100 && r == -EAGAIN_, "F: a full receiver makes a MSG_DONTWAIT sendto fail with EAGAIN");
        check(recv_(r1, b, 64) == 64, "F: reading frees room");
        check(syscall6(SYS_SENDTO, tx, (uint64_t)big, 1000, MSG_DONTWAIT, (uint64_t)&ra, la) == 1000, "F: and the next sendto succeeds");
        while (recv_(r1, b, 64) > 0) {}
    }

    /* G: a datagram that can never fit the ring is EMSGSIZE, not EAGAIN and not an endless wait */
    {
        static char huge[8192];
        for (int i = 0; i < 8192; i++) huge[i] = 'h';
        check(sendto_(tx, huge, 8192, &ra, la) == -EMSGSIZE_, "G: an 8192-byte datagram (ring is 8192, plus the length prefix) is EMSGSIZE");
        int sv[2];
        syscall4(53, AF_UNIX, SOCK_DGRAM, 0, (uint64_t)sv);
        int64_t kid = syscall1(SYS_FORK, 0);
        if (kid == 0) {
            int64_t w = syscall3(SYS_WRITE, sv[0], (uint64_t)huge, 8192);
            syscall1(SYS_EXIT, w == -EMSGSIZE_ ? 0 : 1);
            for (;;) {}
        }
        int st = -1, done = 0;
        for (int i = 0; i < 150 && !done; i++) {
            if (syscall4(SYS_WAIT4, (uint64_t)kid, (uint64_t)&st, WNOHANG, 0) == kid) done = 1;
            else sleep_ms(10);
        }
        if (!done) {
            syscall2(SYS_KILL, (uint64_t)kid, 9);
            syscall4(SYS_WAIT4, (uint64_t)kid, (uint64_t)&st, 0, 0);
        }
        check(done && ((st >> 8) & 0xff) == 0, "G: and a blocking write of one returns EMSGSIZE instead of waiting forever");
        syscall1(SYS_CLOSE, sv[0]);
        syscall1(SYS_CLOSE, sv[1]);
    }

    /* H: sendmmsg / recvmmsg carry addresses and message boundaries on AF_UNIX datagram sockets */
    {
        struct mm { struct msghdr h; uint32_t len; uint32_t pad; };
        struct iovec i1 = { "one", 3 }, i2 = { "second", 6 };
        struct mm out[2];
        for (unsigned k = 0; k < sizeof(out); k++) ((char *)out)[k] = 0;
        out[0].h.name = &ra; out[0].h.namelen = (uint32_t)la; out[0].h.iov = &i1; out[0].h.iovlen = 1;
        out[1].h.name = &rb; out[1].h.namelen = (uint32_t)lb; out[1].h.iov = &i2; out[1].h.iovlen = 1;
        check(syscall4(SYS_SENDMMSG, tx, (uint64_t)out, 2, 0) == 2, "H: sendmmsg of two addressed datagrams returns 2");
        check(out[0].len == 3 && out[1].len == 6, "H: and fills msg_len for each");
        check(recv_(r1, b, 64) == 3 && b[0] == 'o', "H: the first went to the first receiver");
        check(recv_(r2, b, 64) == 6 && b[0] == 's', "H: the second to the second receiver");
        /* two datagrams to one receiver, read back in ONE recvmmsg as two messages */
        out[1].h.name = &ra; out[1].h.namelen = (uint32_t)la;
        check(syscall4(SYS_SENDMMSG, tx, (uint64_t)out, 2, 0) == 2, "H: two datagrams to one receiver");
        char ba[16], bb[16];
        struct iovec ia = { ba, 16 }, ib = { bb, 16 };
        struct mm in[2];
        for (unsigned k = 0; k < sizeof(in); k++) ((char *)in)[k] = 0;
        in[0].h.iov = &ia; in[0].h.iovlen = 1;
        in[1].h.iov = &ib; in[1].h.iovlen = 1;
        int64_t n = syscall5(SYS_RECVMMSG, r1, (uint64_t)in, 2, MSG_DONTWAIT, 0);
        check(n == 2 && in[0].len == 3 && in[1].len == 6, "H: recvmmsg returns them as two messages with their own lengths (boundaries kept)");
    }

    print(failures == 0 ? "hello181: PASS\n" : "hello181: FAIL\n");
    print("hello181 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
