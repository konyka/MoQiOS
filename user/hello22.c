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

#define SYS_WRITE   1
#define SYS_CLOSE   11
#define SYS_SOCKET  117
#define SYS_BIND    118
#define SYS_LISTEN  119
#define SYS_ACCEPT  120

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_dec(int64_t v) {
    char buf[20];
    int pos = 0;
    if (v < 0) { syscall3(SYS_WRITE, 1, (uint64_t)"-", 1); v = -v; }
    if (v == 0) { syscall3(SYS_WRITE, 1, (uint64_t)"0", 1); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char tmp = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = tmp; }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

void _start(void) {
    print("hello22: TCP socket API test\n");

    // socket(AF_INET=2, SOCK_STREAM=1, 0)
    int64_t fd = syscall3(SYS_SOCKET, 2, 1, 0);
    print("hello22: socket=");
    print_dec(fd);
    print("\n");

    if (fd < 0) {
        print("hello22: socket failed\n");
        goto done;
    }

    // sockaddr_in: {family=2, port=8080 big-endian, ip=0.0.0.0}
    uint8_t addr[8] = { 0x00, 0x02, 0x1F, 0x90, 0x00, 0x00, 0x00, 0x00 };
    int64_t br = syscall3(SYS_BIND, (uint64_t)fd, (uint64_t)addr, 16);
    print("hello22: bind=");
    print_dec(br);
    print("\n");

    int64_t lr = syscall2(SYS_LISTEN, (uint64_t)fd, 1);
    print("hello22: listen=");
    print_dec(lr);
    print("\n");

    int64_t ar = syscall3(SYS_ACCEPT, (uint64_t)fd, 0, 0);
    print("hello22: accept=");
    print_dec(ar);
    print(" (0=no pending)\n");

    syscall1(SYS_CLOSE, (uint64_t)fd);

    int ok = (fd >= 0 && br == 0 && lr == 0);
    print("hello22: socket API ");
    print(ok ? "OK\n" : "FAILED\n");

done:
    print("hello22 done\n");
    syscall1(2, 0);
    for (;;) {}
}
