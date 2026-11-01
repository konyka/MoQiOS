/// hello179: SO_PRIORITY, SO_MARK, SO_OOBINLINE, SO_BINDTODEVICE, SO_SNDLOWAT on every socket kind.

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
#define SYS_SOCKET    117
#define SYS_SOCKETPAIR 53
#define SYS_SETSOCKOPT 132
#define SYS_GETSOCKOPT 133
#define SYS_SETUID    174
#define AF_UNIX 1
#define AF_INET 2
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_OOBINLINE 10
#define SO_PRIORITY 12
#define SO_RCVLOWAT 18
#define SO_SNDLOWAT 19
#define SO_BINDTODEVICE 25
#define SO_MARK 36
#define EPERM_ 1
#define EINVAL_ 22
#define ENODEV_ 19
#define ENOPROTOOPT_ 92

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello179:   ok   " : "hello179:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t set_int(int fd, int name, int v) {
    return syscall5(SYS_SETSOCKOPT, (uint64_t)fd, SOL_SOCKET, (uint64_t)name, (uint64_t)&v, 4);
}
static int get_int(int fd, int name) {
    int v = -12345;
    uint32_t l = 4;
    if (syscall5(SYS_GETSOCKOPT, (uint64_t)fd, SOL_SOCKET, (uint64_t)name, (uint64_t)&v, (uint64_t)&l) != 0) return -99999;
    return v;
}

/* The options below behave the same on every socket kind. */
static void exercise(int fd, const char *kind) {
    (void)kind;
    check(get_int(fd, SO_PRIORITY) == 0, "default SO_PRIORITY is 0");
    check(set_int(fd, SO_PRIORITY, 6) == 0 && get_int(fd, SO_PRIORITY) == 6, "SO_PRIORITY 6 reads back");
    check(set_int(fd, SO_OOBINLINE, 1) == 0 && get_int(fd, SO_OOBINLINE) == 1, "SO_OOBINLINE 1 reads back");
    check(set_int(fd, SO_OOBINLINE, 0) == 0 && get_int(fd, SO_OOBINLINE) == 0, "SO_OOBINLINE 0 reads back");
    check(get_int(fd, SO_SNDLOWAT) == 1, "SO_SNDLOWAT reads 1");
    check(set_int(fd, SO_SNDLOWAT, 4) == -ENOPROTOOPT_, "SO_SNDLOWAT cannot be set (ENOPROTOOPT, as in Linux)");
}

void _start(void) {
    print("hello179: more SOL_SOCKET options\n");
    int64_t tcp = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    int64_t udp = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
    int sv[2];
    syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv);

    /* A: the same behaviour on TCP, UDP and AF_UNIX (root: privileged values are allowed) */
    print("hello179: -- TCP\n");
    exercise((int)tcp, "tcp");
    print("hello179: -- UDP\n");
    exercise((int)udp, "udp");
    print("hello179: -- AF_UNIX\n");
    exercise(sv[0], "unix");

    /* B: privileged values as root */
    check(set_int((int)tcp, SO_PRIORITY, 100) == 0 && get_int((int)tcp, SO_PRIORITY) == 100, "B: as root SO_PRIORITY 100 is accepted");
    check(set_int((int)tcp, SO_MARK, 0x1234) == 0 && get_int((int)tcp, SO_MARK) == 0x1234, "B: as root SO_MARK reads back");
    check(get_int((int)udp, SO_MARK) == 0, "B: the default SO_MARK is 0");
    check(get_int((int)udp, SO_RCVLOWAT) == -99999, "B: SO_RCVLOWAT stays unsupported (accepting and ignoring it would break waiters)");

    /* C: unprivileged */
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        failures = 0;
        syscall1(SYS_SETUID, 1000);
        int64_t t = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
        check(t >= 0, "C: socket after setuid(1000)");
        check(set_int((int)t, SO_PRIORITY, 6) == 0, "C: SO_PRIORITY 6 needs no privilege");
        check(set_int((int)t, SO_PRIORITY, 7) == -EPERM_, "C: SO_PRIORITY 7 needs CAP_NET_ADMIN");
        check(set_int((int)t, SO_PRIORITY, -1) == -EPERM_, "C: a negative SO_PRIORITY needs CAP_NET_ADMIN");
        check(get_int((int)t, SO_PRIORITY) == 6, "C: and a refused set leaves the value alone");
        check(set_int((int)t, SO_MARK, 5) == -EPERM_, "C: SO_MARK needs CAP_NET_ADMIN");
        check(get_int((int)t, SO_MARK) == 0, "C: and stays 0");
        syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
        for (;;) {}
    }
    int st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    check(((st >> 8) & 0xff) == 0 && (st & 0x7f) == 0, "C: the unprivileged child's checks all passed");

    /* D: SO_BINDTODEVICE */
    {
        char name[16];
        uint32_t l = 16;
        check(syscall5(SYS_GETSOCKOPT, (uint64_t)tcp, SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)name, (uint64_t)&l) == 0 && l == 0, "D: an unbound socket reports an empty device name");
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)tcp, SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)"lo", 3) == 0, "D: binding to lo succeeds");
        l = 16;
        for (int i = 0; i < 16; i++) name[i] = 0x7f;
        check(syscall5(SYS_GETSOCKOPT, (uint64_t)tcp, SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)name, (uint64_t)&l) == 0 && l == 3 && name[0] == 'l' && name[1] == 'o' && name[2] == 0, "D: and reads back \"lo\" with its terminator");
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)tcp, SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)"nosuch9", 8) == -ENODEV_, "D: an unknown device is ENODEV");
        l = 16;
        syscall5(SYS_GETSOCKOPT, (uint64_t)tcp, SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)name, (uint64_t)&l);
        check(l == 3 && name[0] == 'l', "D: and the failed bind leaves the old binding");
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)tcp, SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)"", 1) == 0, "D: an empty name unbinds");
        l = 16;
        check(syscall5(SYS_GETSOCKOPT, (uint64_t)tcp, SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)name, (uint64_t)&l) == 0 && l == 0, "D: and it reads back empty again");
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)udp, SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)"lo", 3) == 0, "D: UDP can bind to lo");
        check(syscall5(SYS_SETSOCKOPT, (uint64_t)sv[0], SOL_SOCKET, SO_BINDTODEVICE, (uint64_t)"lo", 3) == -ENOPROTOOPT_, "D: an AF_UNIX socket has no devices to bind to (ENOPROTOOPT)");
    }

    syscall1(SYS_CLOSE, tcp);
    syscall1(SYS_CLOSE, udp);
    syscall1(SYS_CLOSE, sv[0]);
    syscall1(SYS_CLOSE, sv[1]);
    print(failures == 0 ? "hello179: PASS\n" : "hello179: FAIL\n");
    print("hello179 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
