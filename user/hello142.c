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
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_PIPE      22
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_SOCKETPAIR 53
#define SYS_SENDMSG   129
#define SYS_RECVMSG   130
#define SYS_OPEN      9
#define SYS_UNLINK    87
#define SYS_FCNTL     142
#define SYS_LSEEK     197
#define SYS_NANOSLEEP 35
#define O_RDWR_CREAT 0x42
#define F_GETFD 1
#define FD_CLOEXEC 1
#define SOL_SOCKET 1
#define SCM_RIGHTS 1
#define SCM_CREDENTIALS 2
#define MSG_CTRUNC 0x8
#define MSG_CMSG_CLOEXEC 0x40000000
#define EBADF_ 9
#define EFAULT_ 14
#define EINVAL_ 22

struct iov { void *base; uint64_t len; };
struct msghdr { void *name; uint32_t namelen, pad0; struct iov *iov; uint64_t iovlen; void *ctl; uint64_t ctllen; uint32_t flags, pad1; };
struct cmsg { uint64_t len; int32_t level, type; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello142:   ok   " : "hello142:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void zero(void *p, unsigned n) { volatile char *c = p; for (unsigned i = 0; i < n; i++) c[i] = 0; }
static void sleep_ms(int ms) {
    struct { int64_t s, n; } t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}

/* send `len` bytes with `nfds` descriptors attached (nfds == 0: no control data) */
static int64_t send_fds(int sock, const void *data, uint64_t len, const int *fds, int nfds) {
    char ctl[64];
    struct iov v = { (void *)data, len };
    struct msghdr m;
    zero(&m, sizeof m);
    m.iov = &v;
    m.iovlen = 1;
    if (nfds > 0) {
        zero(ctl, sizeof ctl);
        struct cmsg *c = (struct cmsg *)ctl;
        c->len = 16 + 4 * nfds;
        c->level = SOL_SOCKET;
        c->type = SCM_RIGHTS;
        for (int i = 0; i < nfds; i++) ((int *)(ctl + 16))[i] = fds[i];
        m.ctl = ctl;
        m.ctllen = (16 + 4 * nfds + 7) & ~7ULL;
    }
    return syscall3(SYS_SENDMSG, (uint64_t)sock, (uint64_t)&m, 0);
}

static char rctl[64];
static uint64_t rctllen;
static uint32_t rflags;
static int rfds[8];
static int rnfds;
static int64_t recv_fds(int sock, void *buf, uint64_t len, uint64_t ctlcap, uint64_t flags) {
    struct iov v = { buf, len };
    struct msghdr m;
    zero(&m, sizeof m);
    zero(rctl, sizeof rctl);
    m.iov = &v;
    m.iovlen = 1;
    m.ctl = rctl;
    m.ctllen = ctlcap;
    int64_t r = syscall3(SYS_RECVMSG, (uint64_t)sock, (uint64_t)&m, flags);
    rctllen = m.ctllen;
    rflags = m.flags;
    rnfds = 0;
    if (r >= 0 && m.ctllen >= 16) {
        struct cmsg *c = (struct cmsg *)rctl;
        if (c->level == SOL_SOCKET && c->type == SCM_RIGHTS) {
            rnfds = (int)((c->len - 16) / 4);
            for (int i = 0; i < rnfds && i < 8; i++) rfds[i] = ((int *)(rctl + 16))[i];
        }
    }
    return r;
}

void _start(void) {
    print("hello142: SCM_RIGHTS\n");
    int sv[2];
    syscall4(SYS_SOCKETPAIR, 1, 1, 0, (uint64_t)sv);

    /* A: pass a pipe end and use it from the received descriptor */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        check(send_fds(sv[0], "x", 1, &pp[1], 1) == 1, "A: sendmsg with one SCM_RIGHTS descriptor succeeds");
        char b[8];
        int64_t r = recv_fds(sv[1], b, 8, 64, 0);
        check(r == 1 && b[0] == 'x', "A: recvmsg returns the data byte");
        check(rnfds == 1 && rfds[0] >= 0 && rfds[0] != pp[1], "A: and one new descriptor");
        check(rctllen == 24, "A: msg_controllen is CMSG_SPACE(4) = 24");
        check((rflags & MSG_CTRUNC) == 0, "A: and MSG_CTRUNC is clear");
        if (rnfds == 1) {
            check(syscall3(SYS_WRITE, rfds[0], (uint64_t)"hi", 2) == 2, "A: the received descriptor is a usable pipe write end");
            char got[4] = { 0, 0, 0, 0 };
            check(syscall3(SYS_READ, pp[0], (uint64_t)got, 2) == 2 && got[0] == 'h' && got[1] == 'i', "A: and the original read end sees the data");
            check(syscall1(SYS_CLOSE, rfds[0]) == 0, "A: it can be closed independently");
            check(syscall3(SYS_WRITE, pp[1], (uint64_t)"z", 1) == 1, "A: the sender's own end still works afterwards");
        }
        syscall1(SYS_CLOSE, pp[0]);
        syscall1(SYS_CLOSE, pp[1]);
    }

    /* B: a regular file shares its offset with the sender's descriptor */
    {
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h142");
        int64_t f = syscall3(SYS_OPEN, (uint64_t)"/tmp/h142", O_RDWR_CREAT, 0644);
        syscall3(SYS_WRITE, f, (uint64_t)"0123456789", 10);
        syscall3(SYS_LSEEK, f, 0, 0);
        int fd = (int)f;
        check(send_fds(sv[0], "f", 1, &fd, 1) == 1, "B: send a regular file");
        char b[4];
        recv_fds(sv[1], b, 4, 64, 0);
        check(rnfds == 1, "B: the file arrives");
        if (rnfds == 1) {
            char two[4] = { 0, 0, 0, 0 };
            check(syscall3(SYS_READ, rfds[0], (uint64_t)two, 3) == 3 && two[0] == '0', "B: reading 3 bytes through the copy");
            char next[4] = { 0, 0, 0, 0 };
            check(syscall3(SYS_READ, f, (uint64_t)next, 2) == 2 && next[0] == '3', "B: the sender continues at the shared offset");
            syscall1(SYS_CLOSE, rfds[0]);
        }
        syscall1(SYS_CLOSE, f);
        syscall1(SYS_UNLINK, (uint64_t)"/tmp/h142");
    }

    /* C: several descriptors in one message */
    {
        int a[2], b2[2];
        syscall1(SYS_PIPE, (uint64_t)a);
        syscall1(SYS_PIPE, (uint64_t)b2);
        int fds[3] = { a[1], b2[1], sv[0] };
        check(send_fds(sv[0], "m", 1, fds, 3) == 1, "C: send three descriptors");
        char x[4];
        recv_fds(sv[1], x, 4, 64, 0);
        check(rnfds == 3, "C: three arrive");
        check(rctllen == 32, "C: msg_controllen is CMSG_SPACE(12) = 32");
        if (rnfds == 3) {
            syscall3(SYS_WRITE, rfds[0], (uint64_t)"A", 1);
            syscall3(SYS_WRITE, rfds[1], (uint64_t)"B", 1);
            char ra = 0, rb = 0;
            syscall3(SYS_READ, a[0], (uint64_t)&ra, 1);
            syscall3(SYS_READ, b2[0], (uint64_t)&rb, 1);
            check(ra == 'A' && rb == 'B', "C: the descriptors keep their identity and order");
            check(syscall3(SYS_WRITE, rfds[2], (uint64_t)"S", 1) == 1, "C: a socket can be passed over itself");
            char s = 0;
            syscall3(SYS_READ, sv[1], (uint64_t)&s, 1);
            check(s == 'S', "C: and the passed socket end works");
            for (int i = 0; i < 3; i++) syscall1(SYS_CLOSE, rfds[i]);
        }
        syscall1(SYS_CLOSE, a[0]); syscall1(SYS_CLOSE, a[1]);
        syscall1(SYS_CLOSE, b2[0]); syscall1(SYS_CLOSE, b2[1]);
    }

    /* D: a receiver with no control buffer drops the descriptors but gets the data */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        send_fds(sv[0], "d", 1, &pp[1], 1);
        char b[4];
        struct iov v = { b, 4 };
        struct msghdr m;
        zero(&m, sizeof m);
        m.iov = &v;
        m.iovlen = 1;
        check(syscall3(SYS_RECVMSG, (uint64_t)sv[1], (uint64_t)&m, 0) == 1 && b[0] == 'd', "D: recvmsg without a control buffer still returns the data");
        check((m.flags & MSG_CTRUNC) != 0, "D: and reports MSG_CTRUNC");
        syscall1(SYS_CLOSE, pp[1]);
        char t = 0;
        check(syscall3(SYS_READ, pp[0], (uint64_t)&t, 1) == 0, "D: the dropped descriptor was released (the pipe sees EOF once the sender closes)");
        syscall1(SYS_CLOSE, pp[0]);
    }

    /* E: a control buffer that is too small truncates */
    {
        int a[2];
        syscall1(SYS_PIPE, (uint64_t)a);
        int fds[2] = { a[0], a[1] };
        send_fds(sv[0], "e", 1, fds, 2);
        char b[4];
        recv_fds(sv[1], b, 4, 20, 0);
        check(rnfds == 1, "E: only one of two descriptors fits in a 20-byte buffer");
        check((rflags & MSG_CTRUNC) != 0, "E: and MSG_CTRUNC is set");
        if (rnfds == 1) syscall1(SYS_CLOSE, rfds[0]);
        syscall1(SYS_CLOSE, a[0]); syscall1(SYS_CLOSE, a[1]);
    }

    /* F: MSG_CMSG_CLOEXEC */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        send_fds(sv[0], "c", 1, &pp[1], 1);
        char b[4];
        recv_fds(sv[1], b, 4, 64, MSG_CMSG_CLOEXEC);
        check(rnfds == 1 && syscall3(SYS_FCNTL, (uint64_t)rfds[0], F_GETFD, 0) == FD_CLOEXEC, "F: MSG_CMSG_CLOEXEC marks the received descriptor close-on-exec");
        send_fds(sv[0], "c", 1, &pp[1], 1);
        recv_fds(sv[1], b, 4, 64, 0);
        check(rnfds == 1 && syscall3(SYS_FCNTL, (uint64_t)rfds[0], F_GETFD, 0) == 0, "F: without the flag it is not");
        syscall1(SYS_CLOSE, pp[0]); syscall1(SYS_CLOSE, pp[1]);
    }

    /* G: errors */
    {
        int bad = 55;
        check(send_fds(sv[0], "g", 1, &bad, 1) == -EBADF_, "G: passing a closed descriptor is EBADF");
        int neg = -1;
        check(send_fds(sv[0], "g", 1, &neg, 1) == -EBADF_, "G: passing -1 is EBADF");
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        check(send_fds(sv[0], "", 0, &pp[1], 1) == -EINVAL_, "G: a descriptor set needs at least one data byte");
        char ctl[32];
        zero(ctl, 32);
        struct cmsg *c = (struct cmsg *)ctl;
        c->len = 20; c->level = SOL_SOCKET; c->type = SCM_CREDENTIALS;
        struct iov v = { "k", 1 };
        struct msghdr m;
        zero(&m, sizeof m);
        m.iov = &v; m.iovlen = 1; m.ctl = ctl; m.ctllen = 24;
        check(syscall3(SYS_SENDMSG, (uint64_t)sv[0], (uint64_t)&m, 0) == -EINVAL_, "G: an unsupported control message type is EINVAL");
        syscall1(SYS_CLOSE, pp[0]); syscall1(SYS_CLOSE, pp[1]);
    }

    /* H: bytes in front of a set are delivered first without it */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        send_fds(sv[0], "AAAA", 4, 0, 0);
        send_fds(sv[0], "B", 1, &pp[1], 1);
        char b[16];
        int64_t r = recv_fds(sv[1], b, 16, 64, 0);
        check(r == 4 && rnfds == 0, "H: a read for control data stops before the bytes that carry a set");
        r = recv_fds(sv[1], b, 16, 64, 0);
        check(r == 1 && b[0] == 'B' && rnfds == 1, "H: the next read delivers the set with its byte");
        if (rnfds == 1) syscall1(SYS_CLOSE, rfds[0]);
        syscall1(SYS_CLOSE, pp[0]); syscall1(SYS_CLOSE, pp[1]);
    }

    /* I: descriptors in flight are released when the receiver closes */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        int s2[2];
        syscall4(SYS_SOCKETPAIR, 1, 1, 0, (uint64_t)s2);
        send_fds(s2[0], "i", 1, &pp[1], 1);
        syscall1(SYS_CLOSE, s2[1]);
        syscall1(SYS_CLOSE, pp[1]);
        char t = 0;
        check(syscall3(SYS_READ, pp[0], (uint64_t)&t, 1) == 0, "I: closing the receiver releases the in-flight write end (EOF)");
        syscall1(SYS_CLOSE, s2[0]);
        syscall1(SYS_CLOSE, pp[0]);
    }

    /* J: a child receives a descriptor the parent opened later */
    {
        int pp[2];
        syscall1(SYS_PIPE, (uint64_t)pp);
        int64_t c = syscall1(SYS_FORK, 0);
        if (c == 0) {
            char b[4];
            recv_fds(sv[1], b, 4, 64, 0);
            if (rnfds == 1) syscall3(SYS_WRITE, rfds[0], (uint64_t)"Q", 1);
            syscall1(SYS_EXIT, rnfds == 1 ? 0 : 1);
            for (;;) {}
        }
        sleep_ms(30);
        send_fds(sv[0], "j", 1, &pp[1], 1);
        int st = -1;
        syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&st, 0);
        char q = 0;
        check(st == 0 && syscall3(SYS_READ, pp[0], (uint64_t)&q, 1) == 1 && q == 'Q', "J: a forked child receives and uses a passed descriptor");
        syscall1(SYS_CLOSE, pp[0]); syscall1(SYS_CLOSE, pp[1]);
    }

    print(failures == 0 ? "hello142: PASS\n" : "hello142: FAIL\n");
    print("hello142 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
