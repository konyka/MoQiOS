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
#define SYS_GETPID    39
#define SYS_SOCKETPAIR 53
#define SYS_SENDMSG   129
#define SYS_RECVMSG   130
#define SYS_SETSOCKOPT 132
#define SYS_GETSOCKOPT 133
#define SYS_GETUID    201
#define SYS_GETGID    202
#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_PASSCRED 16
#define SCM_CREDENTIALS 2
#define EPERM_ 1

struct iov { void *base; uint64_t len; };
struct msghdr { void *name; uint32_t namelen, pad0; struct iov *iov; uint64_t iovlen; void *ctl; uint64_t ctllen; uint32_t flags, pad1; };
struct cmsg { uint64_t len; int32_t level, type; };
struct ucred { int32_t pid; uint32_t uid, gid; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello164:   ok   " : "hello164:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void zero(void *p, uint64_t n) { uint8_t *b = p; for (uint64_t i = 0; i < n; i++) b[i] = 0; }

/* Receive one message with a control buffer; returns the byte count. */
static int64_t recv_ctl(int fd, char *buf, int cap, uint8_t *ctl, int ctlcap, uint64_t *ctllen) {
    struct iov v = { buf, (uint64_t)cap };
    struct msghdr m;
    zero(&m, sizeof m);
    m.iov = &v; m.iovlen = 1; m.ctl = ctl; m.ctllen = (uint64_t)ctlcap;
    int64_t n = syscall3(SYS_RECVMSG, (uint64_t)fd, (uint64_t)&m, 0x40);
    *ctllen = m.ctllen;
    return n;
}
static int64_t send_plain(int fd, const char *s, int len) {
    struct iov v = { (void *)s, (uint64_t)len };
    struct msghdr m;
    zero(&m, sizeof m);
    m.iov = &v; m.iovlen = 1;
    return syscall3(SYS_SENDMSG, (uint64_t)fd, (uint64_t)&m, 0);
}

void _start(void) {
    print("hello164: SCM_CREDENTIALS / SO_PASSCRED\n");
    int64_t pid = syscall1(SYS_GETPID, 0);
    int64_t uid = syscall1(SYS_GETUID, 0);
    int64_t gid = syscall1(SYS_GETGID, 0);
    char b[32];
    uint8_t ctl[64];
    uint64_t cl;

    int sv[2];
    syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);

    /* A: without SO_PASSCRED no credentials are delivered */
    send_plain(sv[0], "plain", 5);
    int64_t n = recv_ctl(sv[1], b, 32, ctl, 64, &cl);
    check(n == 5 && cl == 0, "A: without SO_PASSCRED recvmsg carries no control data");

    /* B: SO_PASSCRED makes every message carry the sender's credentials */
    int one = 1;
    check(syscall5(SYS_SETSOCKOPT, (uint64_t)sv[1], SOL_SOCKET, SO_PASSCRED, (uint64_t)&one, 4) == 0, "B: setsockopt(SO_PASSCRED) succeeds");
    int got = 0;
    uint32_t len = 4;
    syscall5(SYS_GETSOCKOPT, (uint64_t)sv[1], SOL_SOCKET, SO_PASSCRED, (uint64_t)&got, (uint64_t)&len);
    check(got == 1, "B: getsockopt(SO_PASSCRED) reads it back");
    send_plain(sv[0], "hello", 5);
    zero(ctl, sizeof ctl);
    n = recv_ctl(sv[1], b, 32, ctl, 64, &cl);
    check(n == 5, "B: the data still arrives");
    struct cmsg *h = (struct cmsg *)ctl;
    check(cl == 16 + 12 + 4 /* CMSG_SPACE(12) */ && h->len == 16 + 12 && h->level == SOL_SOCKET && h->type == SCM_CREDENTIALS, "B: a SCM_CREDENTIALS message of 12 bytes is attached");
    struct ucred *uc = (struct ucred *)(ctl + 16);
    check(uc->pid == (int32_t)pid && uc->uid == (uint32_t)uid && uc->gid == (uint32_t)gid, "B: carrying the sender's pid, uid and gid");

    /* C: a control buffer that is too small is truncated and says so */
    send_plain(sv[0], "x", 1);
    struct iov v = { b, 32 };
    struct msghdr m;
    zero(&m, sizeof m);
    m.iov = &v; m.iovlen = 1; m.ctl = ctl; m.ctllen = 8;
    n = syscall3(SYS_RECVMSG, (uint64_t)sv[1], (uint64_t)&m, 0x40);
    check(n == 1 && m.ctllen == 0 && (m.flags & 0x8) != 0, "C: a too-small control buffer yields MSG_CTRUNC and no control data");

    /* D: an explicit SCM_CREDENTIALS from the sender: own ids are accepted ... */
    {
        uint8_t sctl[32];
        zero(sctl, sizeof sctl);
        struct cmsg *sh = (struct cmsg *)sctl;
        sh->len = 16 + 12; sh->level = SOL_SOCKET; sh->type = SCM_CREDENTIALS;
        struct ucred *su = (struct ucred *)(sctl + 16);
        su->pid = (int32_t)pid; su->uid = (uint32_t)uid; su->gid = (uint32_t)gid;
        struct iov sv1 = { "own", 3 };
        struct msghdr sm;
        zero(&sm, sizeof sm);
        sm.iov = &sv1; sm.iovlen = 1; sm.ctl = sctl; sm.ctllen = 32;
        check(syscall3(SYS_SENDMSG, (uint64_t)sv[0], (uint64_t)&sm, 0) == 3, "D: sendmsg with the sender's own credentials is accepted");
        n = recv_ctl(sv[1], b, 32, ctl, 64, &cl);
        check(n == 3, "D: and delivered");

        /* ... a forged pid is refused for an unprivileged caller, allowed for root */
        su->pid = (int32_t)pid + 1000;
        int64_t r = syscall3(SYS_SENDMSG, (uint64_t)sv[0], (uint64_t)&sm, 0);
        check(r == 3 || r == -EPERM_, "D: a forged pid is either accepted (privileged) or EPERM");
        if (r == 3) recv_ctl(sv[1], b, 32, ctl, 64, &cl);
    }

    /* E: a datagram socketpair behaves the same, per message */
    {
        int dv[2];
        syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_DGRAM, 0, (uint64_t)dv);
        syscall5(SYS_SETSOCKOPT, (uint64_t)dv[1], SOL_SOCKET, SO_PASSCRED, (uint64_t)&one, 4);
        send_plain(dv[0], "dg", 2);
        zero(ctl, sizeof ctl);
        n = recv_ctl(dv[1], b, 32, ctl, 64, &cl);
        struct ucred *du = (struct ucred *)(ctl + 16);
        check(n == 2 && cl == 32 && du->pid == (int32_t)pid, "E: a datagram carries the sender's credentials too");
        syscall1(SYS_CLOSE, dv[0]);
        syscall1(SYS_CLOSE, dv[1]);
    }

    syscall1(SYS_CLOSE, sv[0]);
    syscall1(SYS_CLOSE, sv[1]);
    print(failures == 0 ? "hello164: PASS\n" : "hello164: FAIL\n");
    print("hello164 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
