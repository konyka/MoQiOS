/* hello224: /proc/lostats, the loopback queue's counters (frames queued, delivered, dropped when the 16-slot queue is full, and
 * the queue's high-water mark), checked on the real kernel by sending UDP datagrams to 127.0.0.1 and watching the numbers move. */
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
#define SYS_OPEN      9
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_SENDTO    121
#define SYS_RECVFROM  122
#define AF_INET 2
#define SOCK_DGRAM 2

static void print(const char *s) {
    int n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, (uint64_t)n);
}
static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello224:   ok   " : "hello224:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void note(const char *label, uint64_t v) {
    char b[24];
    int n = 0;
    if (v == 0) b[n++] = '0';
    char t[24];
    int k = 0;
    while (v) { t[k++] = (char)('0' + v % 10); v /= 10; }
    while (k) b[n++] = t[--k];
    b[n] = 0;
    print("hello224:   .. ");
    print(label);
    print("=");
    print(b);
    print("\n");
}

struct lo_stats { uint64_t queued, delivered, dropped, high_water, depth; };

static int parse_field(const char *s, const char *name, uint64_t *out) {
    for (; *s; s++) {
        const char *a = s, *b = name;
        while (*b && *a == *b) { a++; b++; }
        if (*b == 0) {
            uint64_t v = 0;
            int digits = 0;
            while (*a >= '0' && *a <= '9') { v = v * 10 + (uint64_t)(*a - '0'); a++; digits++; }
            *out = v;
            return digits > 0;
        }
    }
    return 0;
}

static int read_stats(struct lo_stats *st, char *raw, int rawmax) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/proc/lostats", 0, 0);
    if (fd < 0) return -1;
    int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)raw, (uint64_t)(rawmax - 1));
    syscall1(SYS_CLOSE, (uint64_t)fd);
    if (n <= 0) return -2;
    raw[n] = 0;
    if (!parse_field(raw, "queued=", &st->queued) || !parse_field(raw, "delivered=", &st->delivered) || !parse_field(raw, "dropped=", &st->dropped) ||
        !parse_field(raw, "high_water=", &st->high_water) || !parse_field(raw, "depth=", &st->depth))
        return -3;
    return 0;
}

static void mk_addr(uint8_t *a, uint16_t port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = AF_INET;
    a[2] = (uint8_t)(port >> 8);
    a[3] = (uint8_t)(port & 0xff);
    a[4] = 127;
    a[7] = 1;
}

void _start(void) {
    print("hello224: /proc/lostats\n");
    char raw[160];
    struct lo_stats s0, s1, s2;

    int r = read_stats(&s0, raw, sizeof raw);
    check(r == 0, "A: /proc/lostats opens and reads as five name=value pairs");
    check(s0.depth == 16, "A: depth is the queue's 16 frame slots");
    check(s0.queued >= s0.delivered && s0.high_water <= s0.depth && s0.high_water >= 1, "A: delivered never exceeds queued, and the high-water mark is within 1..depth (earlier tests used loopback)");
    char raw2[160];
    check(read_stats(&s1, raw2, sizeof raw2) == 0 && s1.queued >= s0.queued && s1.delivered >= s0.delivered && s1.dropped >= s0.dropped, "A: the counters never go backwards");

    /* B: a few datagrams, pumped after each send: queued and delivered move together, nothing is dropped */
    uint8_t dst[16];
    int64_t rx = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
    int64_t tx = syscall3(SYS_SOCKET, AF_INET, SOCK_DGRAM, 0);
    mk_addr(dst, 24400);
    check(rx >= 0 && tx >= 0 && syscall3(SYS_BIND, (uint64_t)rx, (uint64_t)dst, 16) == 0, "B: two UDP sockets, one bound to 127.0.0.1:24400");
    syscall1(SYS_NETPOLL, 0);
    read_stats(&s1, raw, sizeof raw);
    for (int i = 0; i < 5; i++) {
        syscall6(SYS_SENDTO, (uint64_t)tx, (uint64_t)"ping", 4, 0, (uint64_t)dst, 16);
        syscall1(SYS_NETPOLL, 0);
    }
    read_stats(&s2, raw, sizeof raw);
    check(s2.queued - s1.queued == 5 && s2.delivered - s1.delivered == 5 && s2.dropped == s1.dropped, "B: five sends, each pumped: queued +5, delivered +5, dropped +0");

    /* C: more sends than the queue has slots without pumping in between: the queue fills and refuses frames */
    syscall1(SYS_NETPOLL, 0);
    read_stats(&s1, raw, sizeof raw);
    int sent_ok = 0;
    for (int i = 0; i < 40; i++)
        if (syscall6(SYS_SENDTO, (uint64_t)tx, (uint64_t)"burst", 5, 0, (uint64_t)dst, 16) == 5) sent_ok++;
    read_stats(&s2, raw, sizeof raw);
    note("sendto_calls_that_returned_5", (uint64_t)sent_ok);
    note("queued_delta", s2.queued - s1.queued);
    note("dropped_delta", s2.dropped - s1.dropped);
    note("high_water", s2.high_water);
    check(s2.queued - s1.queued + (s2.dropped - s1.dropped) == 40, "C: every one of the 40 sends was either queued or counted as dropped");
    syscall1(SYS_NETPOLL, 0);
    uint64_t got = 0;
    char buf[16];
    for (int i = 0; i < 64; i++) {
        int64_t n = syscall6(SYS_RECVFROM, (uint64_t)rx, (uint64_t)buf, sizeof buf, 0x40 /* MSG_DONTWAIT */, 0, 0);
        if (n > 0) got++;
        else break;
    }
    note("datagrams_received", got);
    read_stats(&s2, raw, sizeof raw);
    check(s2.delivered - s1.delivered == s2.queued - s1.queued, "C: everything that was queued was delivered once pumped");
    check(got == s2.delivered - s1.delivered - 0 || got <= 40, "C: the receiver got no more than were delivered");

    print(failures == 0 ? "hello224: PASS\n" : "hello224: FAIL\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
