#include <stdint.h>

#define SYS_write   1
#define SYS_exit    2
#define SYS_net_send 100
#define SYS_net_recv 101

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static long syscall2(long n, long a1, long a2) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

static long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_write, 1, (long)s, len);
}

static void print_hex(uint8_t b) {
    const char *hex = "0123456789abcdef";
    char buf[3];
    buf[0] = hex[(b >> 4) & 0xF];
    buf[1] = hex[b & 0xF];
    buf[2] = ' ';
    syscall3(SYS_write, 1, (long)buf, 3);
}

void _start(void) {
    print("hello14: building ARP request\n");

    // Build an ARP request: who has 10.0.2.2? Tell 10.0.2.15
    // Ethernet header
    uint8_t pkt[64];
    for (int i = 0; i < 64; i++) pkt[i] = 0;

    // Destination MAC: broadcast (ff:ff:ff:ff:ff:ff)
    for (int i = 0; i < 6; i++) pkt[i] = 0xFF;

    // Source MAC: 52:54:00:12:34:56 (QEMU default)
    pkt[6] = 0x52; pkt[7] = 0x54; pkt[8] = 0x00;
    pkt[9] = 0x12; pkt[10] = 0x34; pkt[11] = 0x56;

    // EtherType: ARP (0x0806)
    pkt[12] = 0x08; pkt[13] = 0x06;

    // ARP payload
    // Hardware type: Ethernet (1)
    pkt[14] = 0x00; pkt[15] = 0x01;
    // Protocol type: IPv4 (0x0800)
    pkt[16] = 0x08; pkt[17] = 0x00;
    // Hardware size: 6
    pkt[18] = 6;
    // Protocol size: 4
    pkt[19] = 4;
    // Opcode: request (1)
    pkt[20] = 0x00; pkt[21] = 0x01;
    // Sender MAC: 52:54:00:12:34:56
    pkt[22] = 0x52; pkt[23] = 0x54; pkt[24] = 0x00;
    pkt[25] = 0x12; pkt[26] = 0x34; pkt[27] = 0x56;
    // Sender IP: 10.0.2.15
    pkt[28] = 10; pkt[29] = 0; pkt[30] = 2; pkt[31] = 15;
    // Target MAC: 00:00:00:00:00:00
    for (int i = 32; i < 38; i++) pkt[i] = 0;
    // Target IP: 10.0.2.2 (QEMU gateway)
    pkt[38] = 10; pkt[39] = 0; pkt[40] = 2; pkt[41] = 2;

    long ret = syscall2(SYS_net_send, (long)pkt, 42);
    if (ret > 0) {
        print("hello14: ARP request sent (42 bytes)\n");
    } else {
        print("hello14: send failed\n");
        syscall3(SYS_exit, 1, 0, 0);
    }

    // Wait for ARP reply
    print("hello14: waiting for packets (10k polls)...\n");
    uint8_t rbuf[2048];

    int got_any = 0;
    for (int attempt = 0; attempt < 200; attempt++) {
        long n = syscall2(SYS_net_recv, (long)rbuf, 2048);
        if (n > 0) {
            got_any = 1;
            print("hello14: received packet, len=");
            char numbuf[8];
            int dlen = 0;
            long val = n;
            while (val > 0) { numbuf[dlen++] = '0' + (val % 10); val /= 10; }
            for (int j = 0; j < dlen / 2; j++) {
                char tmp = numbuf[j];
                numbuf[j] = numbuf[dlen - 1 - j];
                numbuf[dlen - 1 - j] = tmp;
            }
            syscall3(SYS_write, 1, (long)numbuf, dlen);
            print(" ethertype=");
            print_hex(rbuf[12]); print_hex(rbuf[13]);
            print("\n");

            if (rbuf[12] == 0x08 && rbuf[13] == 0x06 && n >= 42 && rbuf[21] == 0x02) {
                print("hello14: got ARP reply from ");
                print_hex(rbuf[28]); print_hex(rbuf[29]);
                print_hex(rbuf[30]); print_hex(rbuf[31]);
                print("\n");
            }
        }
    }

    if (!got_any) {
        print("hello14: no packets received (QEMU SLIRP may not respond to ARP)\n");
    }

    print("hello14 done\n");
    syscall3(SYS_exit, 0, 0, 0);
}
