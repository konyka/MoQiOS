// hello78 - raw socketpair(2) acceptance for the supported Unix-stream boundary.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx)
                      : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_READ 10
#define SYS_CLOSE 11
#define SYS_SOCKETPAIR 53

#define AF_UNIX 1
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define EFAULT 14
#define EINVAL 22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello78: FAIL ");
    print(why);
    print("\nhello78 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static void expect(int condition, const char *why) {
    if (!condition) fail(why);
}

void _start(void) {
    int32_t sv[2];
    char left_to_right[] = "hello78 left to right";
    char right_to_left[] = "hello78 right to left";
    char buf[32];

    print("hello78: start\n");

    expect(syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, 0) == -EFAULT,
           "null sv EFAULT");
    expect(syscall4(SYS_SOCKETPAIR, 999, SOCK_STREAM, 0, (uint64_t)sv) == -EINVAL,
           "invalid domain EINVAL");
    expect(syscall4(SYS_SOCKETPAIR, AF_UNIX, 999, 0, (uint64_t)sv) == -EINVAL,
           "invalid type EINVAL");
    expect(syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 1, (uint64_t)sv) == -EINVAL,
           "invalid protocol EINVAL");

    expect(syscall4(SYS_SOCKETPAIR, AF_UNIX, SOCK_STREAM, 0, (uint64_t)sv) == 0,
           "create Unix stream pair");
    expect(sv[0] == 3 && sv[1] == 4, "rejected calls leaked fd");

    expect(syscall3(SYS_WRITE, (uint64_t)sv[1], (uint64_t)left_to_right,
                    sizeof(left_to_right) - 1) == (int64_t)(sizeof(left_to_right) - 1),
           "write left to right");
    expect(syscall3(SYS_READ, (uint64_t)sv[0], (uint64_t)buf,
                    sizeof(left_to_right) - 1) == (int64_t)(sizeof(left_to_right) - 1),
           "read left to right");
    expect(buf[0] == 'h' && buf[1] == 'e' && buf[2] == 'l' && buf[3] == 'l' &&
               buf[4] == 'o' && buf[5] == '7' && buf[6] == '8',
           "left to right contents");

    expect(syscall3(SYS_WRITE, (uint64_t)sv[0], (uint64_t)right_to_left,
                    sizeof(right_to_left) - 1) == (int64_t)(sizeof(right_to_left) - 1),
           "write right to left");
    expect(syscall3(SYS_READ, (uint64_t)sv[1], (uint64_t)buf,
                    sizeof(right_to_left) - 1) == (int64_t)(sizeof(right_to_left) - 1),
           "read right to left");
    expect(buf[0] == 'h' && buf[1] == 'e' && buf[2] == 'l' && buf[3] == 'l' &&
               buf[4] == 'o' && buf[5] == '7' && buf[6] == '8',
           "right to left contents");

    expect(syscall1(SYS_CLOSE, (uint64_t)sv[0]) == 0, "close first socket");
    expect(syscall1(SYS_CLOSE, (uint64_t)sv[1]) == 0, "close second socket");
    print("hello78: PASS (raw Unix socketpair bidirectional/error/cleanup)\nhello78 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
