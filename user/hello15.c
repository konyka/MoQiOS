#include <stdint.h>

#define SYS_write   1
#define SYS_exit    2
#define SYS_net_poll 104
#define SYS_udp_send 102
#define SYS_udp_recv 103

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static long syscall5(long n, long a1, long a2, long a3, long a4, long a5) {
    long ret;
    register long a4_reg asm("r10") = a4;
    register long a5_reg asm("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(a4_reg), "r"(a5_reg) : "rcx", "r11", "memory");
    return ret;
}

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_write, 1, (long)s, len);
}

static void print_num(long n) {
    if (n < 0) { print("-"); n = -n; }
    if (n == 0) { print("0"); return; }
    char buf[20];
    int i = 0;
    while (n > 0) { buf[i++] = '0' + (n % 10); n /= 10; }
    char out[20];
    for (int j = 0; j < i; j++) out[j] = buf[i - 1 - j];
    out[i] = '\0';
    print(out);
}

void _start(void) {
    print("hello15: network stack test\n");

    uint32_t gw_ip = ((uint32_t)10 << 24) | ((uint32_t)0 << 16) | ((uint32_t)2 << 8) | (uint32_t)2;
    const char *msg = "Hello from MoQiOS!";
    int msglen = 0;
    while (msg[msglen]) msglen++;

    long send_ret = 0;
    for (int attempt = 0; attempt < 50; attempt++) {
        send_ret = syscall5(SYS_udp_send, (long)gw_ip, 7, 12345, (long)msg, msglen);
        if (send_ret > 0) break;
        syscall1(SYS_net_poll, 0);
    }

    print("hello15: send=");
    print_num(send_ret);
    print("\n");

    uint8_t rbuf[1500];
    uint32_t src_ip = 0;
    uint16_t src_port = 0;

    for (int attempt = 0; attempt < 10; attempt++) {
        syscall1(SYS_net_poll, 0);
        long n = syscall5(SYS_udp_recv, 12345, (long)rbuf, 1500, (long)&src_ip, (long)&src_port);
        if (n > 0) {
            print("hello15: recv ");
            print_num(n);
            print(" bytes\n");
            break;
        }
    }

    print("hello15 done\n");
    syscall3(SYS_exit, 0, 0, 0);
}
