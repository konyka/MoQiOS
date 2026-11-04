/// hello174: SO_SNDBUF and SO_RCVBUF really bound a TCP socket's buffering (and are reported doubled, as Linux does).

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
#define SYS_OPEN      9
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_NANOSLEEP 35
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SETSOCKOPT 132
#define SYS_GETSOCKOPT 133
#define SYS_FCNTL     142
#define SYS_IOCTL     165
#define SYS_CLOCK_GETTIME 228
#define AF_INET 2
#define SOCK_STREAM 1
#define SOL_SOCKET 1
#define SO_SNDBUF 7
#define SO_RCVBUF 8
#define F_SETFL 4
#define O_NONBLOCK 0x800
#define TIOCOUTQ 0x5411
#define FIONREAD 0x541B

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static void print_dec(int64_t v) {
    char b[24]; int n = 0;
    if (v < 0) { print("-"); v = -v; }
    if (v == 0) b[n++] = '0';
    while (v > 0) { b[n++] = (char)('0' + v % 10); v /= 10; }
    char o[24]; int k = 0;
    while (n > 0) o[k++] = b[--n];
    o[k] = 0;
    print(o);
}
static void note(const char *label, int64_t v) {
    print("hello174:   .. "); print(label); print("="); print_dec(v); print("\n");
}
/* /proc/lostats ("queued=N delivered=N dropped=N high_water=N depth=N"): whether the loopback queue ever refused a frame. */
static void print_lostats(const char *when) {
    char raw[160];
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/proc/lostats", 0, 0);
    if (fd < 0) { print("hello174:   .. lostats unavailable\n"); return; }
    int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)raw, sizeof raw - 1);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    if (n <= 0) return;
    if (raw[n - 1] == '\n') n--;
    raw[n] = 0;
    print("hello174:   .. lostats "); print(when); print(": "); print(raw); print("\n");
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello174:   ok   " : "hello174:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t now_ms(void) {
    struct ts t;
    syscall2(228, 1, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
static void pump(int ms) {
    for (int i = 0; i < ms; i += 10) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); }
}
static void mk_addr(uint8_t *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = 2; a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port; a[4] = 127; a[7] = 1;
}
static int set_int(int fd, int name, int v) {
    return (int)syscall5(SYS_SETSOCKOPT, (uint64_t)fd, SOL_SOCKET, (uint64_t)name, (uint64_t)&v, 4);
}
static int get_int(int fd, int name) {
    int v = -12345;
    uint32_t l = 4;
    if (syscall5(SYS_GETSOCKOPT, (uint64_t)fd, SOL_SOCKET, (uint64_t)name, (uint64_t)&v, (uint64_t)&l) != 0) return -99999;
    return v;
}
static int ioctl_int(int fd, uint64_t cmd) {
    int v = -1;
    if (syscall3(SYS_IOCTL, (uint64_t)fd, cmd, (uint64_t)&v) != 0) return -99999;
    return v;
}

/* Listening socket on `port`; *cli connects, *srv is the accepted end. `before_accept` options are applied to
 * the accepted socket by the caller afterwards. */
static int make_pair(int port, int *cli, int *srv) {
    uint8_t sa[16];
    mk_addr(sa, port);
    int64_t l = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    if (l < 0) return -1;
    if (syscall3(SYS_BIND, (uint64_t)l, (uint64_t)sa, 16) != 0) return -2;
    if (syscall2(SYS_LISTEN, (uint64_t)l, 4) != 0) return -3;
    int64_t c = syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    if (c < 0) return -4;
    int64_t cr = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, 16);
    if (cr < 0) syscall1(SYS_NETPOLL, 0);
    for (int i = 0; i < 20 && cr < 0; i++) {
        cr = syscall3(SYS_CONNECT, (uint64_t)c, (uint64_t)sa, 16);
        if (cr < 0) syscall1(SYS_NETPOLL, 0);
    }
    if (cr != 0) return -5;
    int64_t a = -1;
    for (int i = 0; i < 20 && a < 0; i++) {
        syscall1(SYS_NETPOLL, 0);
        a = syscall4(SYS_ACCEPT4, (uint64_t)l, 0, 0, 0);
    }
    if (a < 0) return -6;
    syscall1(SYS_CLOSE, (uint64_t)l);
    *cli = (int)c;
    *srv = (int)a;
    return 0;
}

static int port_off;
static char buf[4096];

/* Write until the socket stops taking data (peer never reads); returns the total accepted. */
static long fill(int fd) {
    syscall3(SYS_FCNTL, (uint64_t)fd, F_SETFL, O_NONBLOCK);
    long total = 0;
    int idle = 0;
    for (int i = 0; i < 400 && idle < 6; i++) {
        int64_t w = syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)buf, 4096);
        if (w > 0) { total += w; idle = 0; }
        else { idle++; pump(30); }
        if ((i % 4) == 3) pump(10);
    }
    pump(200);
    return total;
}

void _start(void) {
    print("hello174: SO_SNDBUF / SO_RCVBUF on TCP\n");
    port_off = (int)((syscall1(39, 0) * 7) % 5000); /* a different port set per process: repeated runs must not collide in TIME_WAIT */
    for (int i = 0; i < 4096; i++) buf[i] = (char)i;

    /* A: values are doubled for bookkeeping overhead, with Linux's minimums */
    {
        int c, s;
        check(make_pair(18174 + port_off, &c, &s) == 0, "A: loopback connection");
        check(set_int(c, SO_SNDBUF, 8192) == 0 && get_int(c, SO_SNDBUF) == 16384, "A: SO_SNDBUF 8192 reads back as 16384 (doubled)");
        check(set_int(c, SO_RCVBUF, 16384) == 0 && get_int(c, SO_RCVBUF) == 32768, "A: SO_RCVBUF 16384 reads back as 32768 (doubled)");
        check(set_int(c, SO_SNDBUF, 100) == 0 && get_int(c, SO_SNDBUF) == 4608, "A: a tiny SO_SNDBUF is raised to the minimum (4608)");
        check(set_int(c, SO_RCVBUF, 100) == 0 && get_int(c, SO_RCVBUF) == 2304, "A: a tiny SO_RCVBUF is raised to the minimum (2304)");
        check(set_int(c, SO_SNDBUF, 1 << 30) == 0 && get_int(c, SO_SNDBUF) == 425984, "A: a huge SO_SNDBUF is capped at 2 x rmem_max (425984)");
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    /* B: SO_SNDBUF bounds how much a non-reading peer lets the sender queue */
    long big_total, small_total;
    int big_avail;
    {
        int c, s;
        make_pair(18175 + port_off, &c, &s);
        big_total = fill(c);
        big_avail = ioctl_int(s, FIONREAD);
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }
    {
        int c, s;
        make_pair(18176 + port_off, &c, &s);
        set_int(c, SO_SNDBUF, 8192);
        small_total = fill(c);
        int q = ioctl_int(c, TIOCOUTQ);
        check(q >= 0 && q <= 8192, "B: with SO_SNDBUF 8192 at most 8192 bytes stay queued unacknowledged");
        check(small_total < big_total - 16384, "B: and the sender is cut off well before the default would be (accepted far less)");
        check(small_total >= 4096, "B: but still queues something");
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    /* C: SO_RCVBUF bounds what the receiver buffers for a reader that does not read */
    {
        int c, s;
        make_pair(18177 + port_off, &c, &s);
        set_int(s, SO_RCVBUF, 16384);
        syscall3(SYS_FCNTL, (uint64_t)c, F_SETFL, O_NONBLOCK);
        syscall3(SYS_WRITE, (uint64_t)c, (uint64_t)buf, 1);
        pump(300); /* the receiver's ACK carries the smaller window before the bulk write */
        long total = fill(c);
        /* The receiver fills up to its allowance and no further: wait (up to ~5 s) for it to get there, then
         * give a buggy over-advertising window time to overshoot before checking the cap. */
        int avail = ioctl_int(s, FIONREAD);
        for (int i = 0; i < 100 && avail < 14000; i++) { pump(50); avail = ioctl_int(s, FIONREAD); }
        int avail_first = avail;
        check(avail >= 14000, "C: the receiver buffers up to roughly its SO_RCVBUF allowance (>= 14000 bytes)");
        pump(500);
        avail = ioctl_int(s, FIONREAD);
        int cap_ok = avail > 0 && avail <= 16384 + 1460;
        check(cap_ok, "C: and never more than ~16 KiB (SO_RCVBUF 16384)");
        if (!cap_ok || avail_first < 14000) {
            note("avail_first", avail_first); note("avail_after_500ms", avail); note("sender_accepted", total);
            note("sender_outq", ioctl_int(c, TIOCOUTQ));
        }
        check(big_avail > 20000, "C: while a receiver that never set SO_RCVBUF buffers more than that (> 20000)");
        char drain[4096];
        long got = 0;
        syscall3(SYS_FCNTL, (uint64_t)s, F_SETFL, O_NONBLOCK);
        int64_t t0 = now_ms();
        int64_t last_progress = t0;
        long reads = 0, empty_reads = 0;
        /* When bytes arrived: the receiver's total at the end of each second of the drain, and the longest silence between reads. */
        long got_at_sec[11] = { 0 };
        int64_t longest_gap = 0;
        while (got < total + 1 && now_ms() - t0 < 10000) {
            int64_t r = syscall3(SYS_READ, (uint64_t)s, (uint64_t)drain, 4096);
            int64_t t = now_ms();
            if (r > 0) {
                if (t - last_progress > longest_gap) longest_gap = t - last_progress;
                got += r; last_progress = t; reads++;
            } else { empty_reads++; pump(10); }
            int64_t sec = (now_ms() - t0) / 1000;
            if (sec >= 0 && sec <= 10) got_at_sec[sec] = got;
        }
        int drained = got >= total + 1;
        check(drained, "C: reading drains everything that was accepted within 10 s, and the window reopens");
        if (!drained) {
            note("drain_got", got); note("drain_total_plus_1", total + 1); note("drain_elapsed_ms", now_ms() - t0);
            note("drain_stalled_for_ms", now_ms() - last_progress); note("drain_reads", reads); note("drain_empty_reads", empty_reads);
            note("drain_receiver_fionread", ioctl_int(s, FIONREAD)); note("drain_sender_outq", ioctl_int(c, TIOCOUTQ));
            note("drain_longest_gap_ms", longest_gap);
            for (int k = 0; k < 11; k++) { print("hello174:   .. drain_got_by_second_"); print_dec(k); print("="); print_dec(got_at_sec[k]); print("\n"); }
        }
        print_lostats(drained ? "after the drain" : "at the failed drain");
        syscall1(SYS_CLOSE, c);
        syscall1(SYS_CLOSE, s);
    }

    print(failures == 0 ? "hello174: PASS\n" : "hello174: FAIL\n");
    print("hello174 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
