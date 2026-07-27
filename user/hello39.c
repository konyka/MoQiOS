// hello39: socket option user-copy and sockaddr length regressions.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8)
                      : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_MMAP        8
#define SYS_CLOSE       11
#define SYS_SOCKET      117
#define SYS_BIND        118
#define SYS_SENDTO      121
#define SYS_SETSOCKOPT  132
#define SYS_GETSOCKOPT  133

#define AF_UNIX         1
#define AF_INET         2
#define SOCK_STREAM     1
#define SOCK_DGRAM      2
#define SOL_SOCKET      1
#define SO_REUSEADDR    2
#define SO_ERROR        4

#define PROT_READ       1
#define MAP_PRIVATE     2
#define MAP_ANONYMOUS   0x20
#define PAGE            4096UL

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello39: FAIL (");
    print(why);
    print(")\nhello39 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    const int64_t tcp = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    if (tcp < 0) fail("TCP socket");

    uint32_t one = 1;
    if (syscall5(SYS_SETSOCKOPT, tcp, SOL_SOCKET, SO_REUSEADDR, 0, 4) != -14) {
        fail("setsockopt null optval EFAULT");
    }

    const int64_t ro = syscall6(SYS_MMAP, 0, PAGE, PROT_READ,
                                MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (ro <= 0) fail("readonly mmap");
    if (syscall5(SYS_GETSOCKOPT, tcp, SOL_SOCKET, SO_ERROR, (uint64_t)&one, ro) != -14) {
        fail("getsockopt readonly optlen EFAULT");
    }
    syscall1(SYS_CLOSE, (uint64_t)tcp);

    const int64_t unix_fd = syscall3(SYS_SOCKET, AF_UNIX, SOCK_STREAM, 0);
    if (unix_fd < 0) fail("UNIX socket");
    uint8_t unix_addr[3] = { 1, 0, 'x' };
    if (syscall3(SYS_BIND, unix_fd, (uint64_t)unix_addr, 2) != -22) {
        fail("AF_UNIX short addr_len EINVAL");
    }
    syscall1(SYS_CLOSE, (uint64_t)unix_fd);

    const int64_t udp = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
    if (udp < 0) fail("UDP socket");
    uint8_t addr4[8] = { 2, 0, 0, 9, 127, 0, 0, 1 };
    uint8_t byte = 0;
    if (syscall6(SYS_SENDTO, udp, (uint64_t)&byte, 1, 0, (uint64_t)addr4, 7) != -22) {
        fail("UDP sendto short addr_len EINVAL");
    }
    syscall1(SYS_CLOSE, (uint64_t)udp);

    print("hello39: PASS (socket option faults/address lengths)\nhello39 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
