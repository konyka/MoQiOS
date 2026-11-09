/// hello269: connections that finished leave only TIME_WAIT/LAST_ACK leftovers; the 64-slot TCB table must never run out of room for a new socket because of them.

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
#define SYS_CLOSE     11
#define SYS_FORK      57
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_NETPOLL   104
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_SENDTO    121
#define SYS_CONNECT   124
#define SYS_ACCEPT4   131
#define SYS_SETSOCKOPT 132
#define SYS_GETSOCKOPT 133
#define SYS_RECVFROM  122
#define SO_RCVTIMEO 20
#define MSG_DONTWAIT 0x40
#define SYS_SETUID    174
#define SYS_IOCTL     165
#define SIOCGIFADDR   0x8915
#define EADDRNOTAVAIL_ 99
#define AF_INET 2
#define AF_INET6 10
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define SO_REUSEPORT 15
#define EACCES_ 13
#define EINVAL_ 22
#define EADDRINUSE_ 98

struct ts { int64_t s, n; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello269:   ok   " : "hello269:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
struct ts2 { int64_t s, n; };
static int64_t now_ms(void) {
    struct ts2 t;
    syscall2(228, 1, (uint64_t)&t);
    return t.s * 1000 + t.n / 1000000;
}
static void print_num(const char *label, int64_t x) {
    char r[24]; int m = 0; char o[40]; int k = 0;
    print(label);
    if (x < 0) { o[k++] = '-'; x = -x; }
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = (char)('0' + x % 10); x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k++] = '\n'; o[k] = 0;
    print(o);
}
static void pump(int ms) {
    for (int i = 0; i < ms; i += 10) { syscall1(SYS_NETPOLL, 0); sleep_ms(10); }
}
static void mk_addr(uint8_t *a, int port) {
    for (int i = 0; i < 16; i++) a[i] = 0;
    a[0] = 2; a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port; a[4] = 127; a[7] = 1;
}
static void mk_addr6(uint8_t *a, int port) {
    for (int i = 0; i < 28; i++) a[i] = 0;
    a[0] = AF_INET6;
    a[2] = (uint8_t)(port >> 8); a[3] = (uint8_t)port;
    a[8 + 15] = 1;
}
static int64_t sock4(void) { return syscall3(SYS_SOCKET, AF_INET, SOCK_STREAM, 0); }
static int64_t bind4(int64_t s, int port) {
    uint8_t sa[16];
    mk_addr(sa, port);
    return syscall3(SYS_BIND, (uint64_t)s, (uint64_t)sa, 16);
}
static void reuseport(int64_t s) {
    int one = 1;
    syscall5(SYS_SETSOCKOPT, (uint64_t)s, SOL_SOCKET, SO_REUSEPORT, (uint64_t)&one, 4);
}
static void reuse(int64_t s) {
    int one = 1;
    syscall5(SYS_SETSOCKOPT, (uint64_t)s, SOL_SOCKET, SO_REUSEADDR, (uint64_t)&one, 4);
}

static int read_tcpstats(char *raw, int rawmax) {
    int64_t fd = syscall3(9, (uint64_t)"/proc/tcpstats", 0, 0);
    if (fd < 0) return -1;
    int64_t n = syscall3(10, (uint64_t)fd, (uint64_t)raw, (uint64_t)(rawmax - 1));
    syscall1(SYS_CLOSE, (uint64_t)fd);
    if (n <= 0) return -2;
    raw[n] = 0;
    return 0;
}
static int stat_field(const char *raw, const char *name, int64_t *out) {
    int nl = 0;
    while (name[nl]) nl++;
    for (int i = 0; raw[i]; i++) {
        int k = 0;
        while (k < nl && raw[i + k] == name[k]) k++;
        if (k == nl && (i == 0 || raw[i - 1] == ' ')) {
            int64_t v = 0;
            int j = i + nl;
            if (raw[j] < '0' || raw[j] > '9') continue;
            while (raw[j] >= '0' && raw[j] <= '9') v = v * 10 + (raw[j++] - '0');
            *out = v;
            return 1;
        }
    }
    return 0;
}

void _start(void) {
    print("hello269: finished connections do not exhaust the TCB table\n");
    uint8_t ia[16];
    mk_addr(ia, 18420);
    int64_t srv = sock4();
    reuse(srv);
    check(bind4(srv, 18420) == 0 && syscall2(SYS_LISTEN, (uint64_t)srv, 16) == 0, "a listener on a local port");
    char raw0[400], raw1[400];
    int64_t drop0 = -1, drop1 = -1, ev0 = -1, ev1 = -1, tw1 = -1, orph1 = -1, act1 = -1, cap1 = -1;
    int have_stats = read_tcpstats(raw0, sizeof raw0) == 0 && stat_field(raw0, "syn_dropped=", &drop0) && stat_field(raw0, "time_wait_evicted=", &ev0);
    check(have_stats, "/proc/tcpstats exists and lists syn_dropped and time_wait_evicted");
    static uint16_t ports_seen[100];
    int rounds_ok = 0, total = 0, socket_fail = 0, connect_fail = 0;
    int64_t t_start = now_ms();
    int64_t worst_ms = 0;
    /* 100 rounds, each a complete connection closed by both ends; every connection leaves a TIME_WAIT TCB (15 s) behind, so more than the table holds */
    for (int r = 0; r < 100; r++) {
        int64_t tr0 = now_ms();
        int64_t cl = sock4();
        if (cl < 0) { socket_fail++; break; }
        int64_t rc = syscall3(SYS_CONNECT, (uint64_t)cl, (uint64_t)ia, 16);
        int64_t ac = -1;
        for (int i = 0; i < 100 && ac < 0; i++) { syscall1(SYS_NETPOLL, 0); ac = syscall4(SYS_ACCEPT4, (uint64_t)srv, 0, 0, 0x800); }
        if (ac < 0 && rc != 0) { connect_fail++; syscall1(SYS_CLOSE, (uint64_t)cl); continue; }
        total++;
        {
            uint8_t nm[16]; uint32_t nl = 16;
            for (int q = 0; q < 16; q++) nm[q] = 0;
            if (syscall3(126, (uint64_t)cl, (uint64_t)nm, (uint64_t)&nl) == 0) ports_seen[r] = (uint16_t)((nm[2] << 8) | nm[3]);
        }
        if (now_ms() - tr0 > worst_ms) worst_ms = now_ms() - tr0;
        if (ac >= 0) syscall1(SYS_CLOSE, (uint64_t)ac);
        syscall1(SYS_CLOSE, (uint64_t)cl);
        syscall1(SYS_NETPOLL, 0);
        rounds_ok++;
    }
    int64_t elapsed = now_ms() - t_start;
    print_num("hello269: elapsed ms for the rounds: ", elapsed);
    print_num("hello269: slowest single round ms: ", worst_ms);
    check(worst_ms < 5000, "no single round stalls for seconds (a full TCB table of TIME_WAIT leftovers makes the next connect wait for them to expire)");
    check(socket_fail == 0, "socket() keeps succeeding through 100 connect/accept/close rounds");
    check(connect_fail == 0, "and so does every connect");
    check(rounds_ok == 100, "all 100 rounds completed");
    {
        int dup = 0, zero = 0;
        for (int a = 0; a < 100; a++) {
            if (ports_seen[a] == 0) zero++;
            for (int b = a + 1; b < 100; b++) if (ports_seen[a] != 0 && ports_seen[a] == ports_seen[b]) dup++;
        }
        print_num("hello269: client ports reported as zero: ", zero);
        print_num("hello269: client port reused within the 100 rounds: ", dup);
        check(zero == 0, "getsockname reports the client's local port every round");
        check(dup == 0, "no client port is reused within 100 rounds, so an evicted TIME_WAIT 4-tuple is not recycled soon");
    }
    int have1 = read_tcpstats(raw1, sizeof raw1) == 0 && stat_field(raw1, "syn_dropped=", &drop1) && stat_field(raw1, "time_wait_evicted=", &ev1) &&
                stat_field(raw1, "time_wait=", &tw1) && stat_field(raw1, "orphans=", &orph1) && stat_field(raw1, "active=", &act1) && stat_field(raw1, "capacity=", &cap1);
    check(have1, "/proc/tcpstats is readable after the rounds");
    if (have1) {
        print_num("hello269: syn_dropped during the rounds: ", drop1 - drop0);
        print_num("hello269: time_wait slots evicted during the rounds: ", ev1 - ev0);
        print_num("hello269: time_wait now: ", tw1);
        check(drop1 == drop0, "no SYN was dropped for lack of a free slot");
        check(tw1 <= cap1 && act1 <= cap1, "the table never reports more slots than its capacity");
        check(orph1 <= act1, "unreferenced leftovers are a subset of the active slots");
    }
    syscall1(SYS_CLOSE, (uint64_t)srv);
    int64_t after = sock4();
    check(after >= 0, "a fresh socket can still be created afterwards");
    if (after >= 0) syscall1(SYS_CLOSE, (uint64_t)after);
    (void)total;
    print(failures == 0 ? "hello269: PASS\n" : "hello269: FAIL\n");
    print("hello269 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
