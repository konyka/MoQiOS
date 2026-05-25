/**
 * hello26: TCP echo server test
 *
 * Tests the full TCP server-side socket API:
 *   1. socket(AF_INET, SOCK_STREAM, 0)
 *   2. bind to 0.0.0.0:9090
 *   3. listen with backlog 1
 *   4. accept (non-blocking — returns 0 if no pending)
 *   5. If connected: recv data, send it back (echo), close
 *
 * For manual testing with SLIRP hostfwd:
 *   qemu ... -netdev user,id=net0,hostfwd=tcp::9090-:9090
 *   Then from host: echo "hello" | nc localhost 9090
 */

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
#define SYS_EXIT    2
#define SYS_CLOSE   11
#define SYS_SOCKET  117
#define SYS_BIND    118
#define SYS_LISTEN  119
#define SYS_ACCEPT  120
#define SYS_SENDTO  121
#define SYS_RECVFROM 122

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

static void delay(int count) {
    for (volatile int i = 0; i < count; i++) {}
}

void _start(void) {
    int ok = 1;
    print("hello26: TCP echo server test\n");

    /* 1. socket(AF_INET=2, SOCK_STREAM=1, 0) */
    int64_t server_fd = syscall3(SYS_SOCKET, 2, 1, 0);
    print("hello26: socket=");
    print_dec(server_fd);
    print("\n");
    if (server_fd < 0) { ok = 0; goto done; }

    /* 2. bind to 0.0.0.0:9090 */
    uint8_t addr[16];
    for (int i = 0; i < 16; i++) addr[i] = 0;
    addr[0] = 0x00; addr[1] = 0x02;  /* AF_INET */
    addr[2] = 0x23; addr[3] = 0x82;  /* port 9090 big-endian */
    int64_t br = syscall3(SYS_BIND, (uint64_t)server_fd, (uint64_t)addr, 16);
    print("hello26: bind=");
    print_dec(br);
    print("\n");
    if (br < 0) { ok = 0; goto close_server; }

    /* 3. listen */
    int64_t lr = syscall2(SYS_LISTEN, (uint64_t)server_fd, 1);
    print("hello26: listen=");
    print_dec(lr);
    print("\n");
    if (lr < 0) { ok = 0; goto close_server; }

    /* 4. Poll accept a few times */
    int64_t client_fd = 0;
    for (int attempt = 0; attempt < 5; attempt++) {
        client_fd = syscall3(SYS_ACCEPT, (uint64_t)server_fd, 0, 0);
        if (client_fd > 0) break;
        delay(500000);
    }
    print("hello26: accept=");
    print_dec(client_fd);
    print("\n");

    if (client_fd > 0) {
        /* 5. Echo loop: recv then send back */
        int echo_count = 0;
        for (int round = 0; round < 3; round++) {
            char buf[128];
            for (int i = 0; i < 128; i++) buf[i] = 0;

            int64_t n = syscall3(SYS_RECVFROM, (uint64_t)client_fd, (uint64_t)buf, 128);
            print("hello26: recv=");
            print_dec(n);
            print("\n");

            if (n <= 0) break;

            print("hello26: data=");
            int show = (int)n;
            if (show > 40) show = 40;
            syscall3(SYS_WRITE, 1, (uint64_t)buf, (uint64_t)show);
            print("\n");

            /* Echo back */
            int64_t sent = syscall3(SYS_SENDTO, (uint64_t)client_fd, (uint64_t)buf, (uint64_t)n);
            print("hello26: echo=");
            print_dec(sent);
            print("\n");
            echo_count++;
        }
        print("hello26: echoed ");
        print_dec(echo_count);
        print(" messages\n");

        syscall1(SYS_CLOSE, (uint64_t)client_fd);
    } else {
        print("hello26: no client (expected in automated test)\n");
    }

close_server:
    syscall1(SYS_CLOSE, (uint64_t)server_fd);

done:
    print("hello26: echo server ");
    print(ok ? "OK\n" : "FAILED\n");
    print("hello26 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
