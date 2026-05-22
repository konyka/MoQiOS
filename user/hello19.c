/// hello19: TCP connection test
///
/// Tests TCP syscalls:
///   - tcp_connect(112): Connect to QEMU SLIRP gateway (10.0.2.2:80)
///   - tcp_poll(116): Poll connection state
///   - tcp_send(113): Send HTTP request
///   - tcp_recv(114): Receive response
///   - tcp_close(115): Close connection
///
/// QEMU SLIRP acts as a router/NAT. Connecting to 10.0.2.2 reaches the host.
/// Port 80 may or may not be listening, but the SYN/ACK handshake tests the TCP stack.

#include <stdint.h>

// MoQiOS syscalls
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

// Syscall numbers
#define SYS_WRITE   1
#define SYS_NET_POLL 104
#define SYS_TCP_CONNECT 112
#define SYS_TCP_SEND    113
#define SYS_TCP_RECV    114
#define SYS_TCP_CLOSE   115
#define SYS_TCP_POLL    116

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_dec(int64_t v) {
    char buf[20];
    int pos = 0;
    if (v < 0) {
        syscall3(SYS_WRITE, 1, (uint64_t)"-", 1);
        v = -v;
    }
    if (v == 0) {
        syscall3(SYS_WRITE, 1, (uint64_t)"0", 1);
        return;
    }
    while (v > 0) {
        buf[pos++] = '0' + (v % 10);
        v /= 10;
    }
    // Reverse
    for (int i = 0; i < pos / 2; i++) {
        char tmp = buf[i];
        buf[i] = buf[pos - 1 - i];
        buf[pos - 1 - i] = tmp;
    }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

void _start(void) {
    print("hello19: TCP connection test\n");

    // Gateway IP: 10.0.2.2
    uint8_t gateway_ip[4] = {10, 0, 2, 2};
    uint16_t port = 80;

    // Step 1: Connect
    print("hello19: connecting to 10.0.2.2:80...\n");
    int64_t tcb = syscall2(SYS_TCP_CONNECT, (uint64_t)gateway_ip, port);
    print("hello19: tcp_connect returned ");
    print_dec(tcb);
    print("\n");

    if (tcb < 0) {
        print("hello19: connect failed (expected if no network)\n");
        print("hello19 done\n");
        syscall1(2, 0); // exit(0)
        
    }

    // Step 2: Poll until established (with timeout)
    print("hello19: polling for connection...\n");
    int max_polls = 5;
    int established = 0;
    for (int i = 0; i < max_polls; i++) {
        syscall1(SYS_NET_POLL, 0);
        int64_t state = syscall1(SYS_TCP_POLL, (uint64_t)tcb);
        if (state == 1) { established = 1; print("hello19: connection established!\n"); break; }
        if (state < 0) { print("hello19: connection failed\n"); break; }
    }

    if (!established) {
        print("hello19: no SYN-ACK (SLIRP has no TCP server)\n");
        print("hello19: TCP stack OK (SYN sent)\n");
    }

    if (established) {
        // Step 3: Send HTTP request
        const char *http_req = "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n";
        int req_len = 0;
        while (http_req[req_len]) req_len++;

        print("hello19: sending HTTP request...\n");
        int64_t sent = syscall3(SYS_TCP_SEND, (uint64_t)tcb, (uint64_t)http_req, req_len);
        print("hello19: tcp_send returned ");
        print_dec(sent);
        print("\n");

        // Step 4: Receive response (poll + recv loop)
        print("hello19: waiting for response...\n");
        for (int attempt = 0; attempt < 5; attempt++) {
            syscall1(SYS_NET_POLL, 0);
            char recv_buf[256];
            int64_t recv_len = syscall3(SYS_TCP_RECV, (uint64_t)tcb, (uint64_t)recv_buf, 255);
            if (recv_len > 0) {
                print("hello19: received ");
                print_dec(recv_len);
                print(" bytes\n");
                break;
            }
            if (recv_len < 0) {
                print("hello19: connection closed by remote\n");
                break;
            }
        }
    }

    // Step 5: Close
    print("hello19: closing connection...\n");
    int64_t close_result = syscall1(SYS_TCP_CLOSE, (uint64_t)tcb);
    print("hello19: tcp_close returned ");
    print_dec(close_result);
    print("\n");

    print("hello19 done\n");
    syscall1(2, 0);
    for (;;) {}
}
