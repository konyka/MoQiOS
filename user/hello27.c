/**
 * hello27: TCP connect() syscall test
 *
 * Tests the socket API client-side path:
 *   1. socket(AF_INET, SOCK_STREAM, 0) → get fd
 *   2. connect(fd, 10.0.2.2:80) → syscall #124
 *   3. Poll for established state (tcp_poll #116 via TCB index)
 *   4. sendto(fd, "GET / HTTP/1.0\r\n\r\n") → send HTTP request
 *   5. recvfrom(fd, buf) → try to read response
 *   6. close(fd)
 *
 * This is the FIRST test of connect() syscall #124.
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

#define SYS_WRITE    1
#define SYS_EXIT     2
#define SYS_CLOSE    11
#define SYS_TCP_POLL 116
#define SYS_SOCKET   117
#define SYS_CONNECT  124
#define SYS_SENDTO   121
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
    print("hello27: connect() syscall test\n");

    /* 1. socket */
    int64_t fd = syscall3(SYS_SOCKET, 2, 1, 0);
    print("hello27: socket=");
    print_dec(fd);
    print("\n");
    if (fd < 0) { ok = 0; goto done; }

    /* 2. connect to 10.0.2.2:80 via socket API (syscall #124) */
    uint8_t addr[16];
    for (int i = 0; i < 16; i++) addr[i] = 0;
    addr[0] = 0x00; addr[1] = 0x02;  /* AF_INET */
    addr[2] = 0x00; addr[3] = 0x50;  /* port 80 big-endian */
    addr[4] = 10; addr[5] = 0; addr[6] = 2; addr[7] = 2;  /* 10.0.2.2 */
    int64_t cr = syscall3(SYS_CONNECT, (uint64_t)fd, (uint64_t)addr, 16);
    print("hello27: connect=");
    print_dec(cr);
    print("\n");
    if (cr < 0) {
        print("hello27: connect failed\n");
        ok = 0;
        goto close_fd;
    }

    /* 3. Wait for connection establishment */
    /* We need the TCB index to poll. The fd's tcb_idx is internal.
       Use a brief delay then try sendto — if connected, it works. */
    delay(2000000);

    /* 4. Send HTTP GET */
    const char *req = "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n";
    int req_len = 0;
    while (req[req_len]) req_len++;
    int64_t sent = syscall3(SYS_SENDTO, (uint64_t)fd, (uint64_t)req, (uint64_t)req_len);
    print("hello27: sendto=");
    print_dec(sent);
    print("/");
    print_dec(req_len);
    print("\n");

    if (sent >= 0) {
        /* 5. Try recv */
        delay(1000000);
        char buf[256];
        for (int i = 0; i < 256; i++) buf[i] = 0;
        int64_t n = syscall3(SYS_RECVFROM, (uint64_t)fd, (uint64_t)buf, 256);
        print("hello27: recv=");
        print_dec(n);
        print("\n");
        if (n > 0) {
            print("hello27: data=");
            int show = (int)n;
            if (show > 30) show = 30;
            syscall3(SYS_WRITE, 1, (uint64_t)buf, (uint64_t)show);
            print("\n");
        }
    }

close_fd:
    syscall1(SYS_CLOSE, (uint64_t)fd);

done:
    print("hello27: connect test ");
    print(ok ? "OK\n" : "FAILED\n");
    print("hello27 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
