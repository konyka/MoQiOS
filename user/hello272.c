/// hello272: more simultaneous TCP connections than the old 64-slot TCB table held. Each loopback connection is two TCBs (client and accepted
/// end), so 40 open at once need 81 slots with the listener; every one must connect, be accepted and carry a byte both ways.

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
    print(ok ? "hello272:   ok   " : "hello272:   FAIL ");
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

void _start(void) {
    print("hello272: 40 simultaneous loopback TCP connections (80 TCBs, more than the old 64-slot table)\n");
    uint8_t ia[16];
    mk_addr(ia, 18430);
    int64_t srv = sock4();
    reuse(srv);
    check(bind4(srv, 18430) == 0 && syscall2(SYS_LISTEN, (uint64_t)srv, 64) == 0, "a listener with a backlog of 64");
    /* Each process has 64 descriptors, so the 40 client ends live in a child and the 40 accepted ends in this process. */
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        int64_t cl[40];
        int ok = 0;
        for (int i = 0; i < 40; i++) {
            cl[i] = sock4();
            if (cl[i] < 0) { print_num("hello272: client socket() failed, rc ", cl[i]); continue; }
            int64_t r = syscall3(SYS_CONNECT, (uint64_t)cl[i], (uint64_t)ia, 16);
            /* up to ~5 s: in the full sequence earlier tests leave TIME_WAIT/LAST_ACK leftovers, and a SYN that meets a table momentarily full of
             * live slots is retransmitted after 2 s */
            for (int k = 0; k < 1000 && r != 0 && r != -106; k++) { syscall1(SYS_NETPOLL, 0); sleep_ms(5); r = syscall3(SYS_CONNECT, (uint64_t)cl[i], (uint64_t)ia, 16); }
            if (r == 0 || r == -106) ok++;
            else print_num("hello272: client connect failed, rc ", r);
        }
        /* every connection reads the byte the server writes to it */
        int echoed = 0;
        for (int i = 0; i < 40; i++) {
            if (cl[i] < 0) continue;
            char g = 0;
            int64_t n = -1;
            for (int k = 0; k < 400 && n <= 0; k++) { syscall1(SYS_NETPOLL, 0); n = syscall6(SYS_RECVFROM, (uint64_t)cl[i], (uint64_t)&g, 1, 0x40, 0, 0); if (n <= 0) sleep_ms(5); }
            if (n == 1 && g == 'z') echoed++;
        }
        for (int i = 0; i < 40; i++) if (cl[i] >= 0) syscall1(SYS_CLOSE, (uint64_t)cl[i]);
        syscall1(SYS_EXIT, (ok == 40 && echoed == 40) ? 0 : 1);
        for (;;) {}
    }
    int64_t ac[40];
    int accepted = 0;
    for (int i = 0; i < 40; i++) ac[i] = -1;
    int64_t t_acc = now_ms();
    for (int round = 0; round < 4000 && accepted < 40; round++) {
        syscall1(SYS_NETPOLL, 0);
        int64_t a = syscall4(SYS_ACCEPT4, (uint64_t)srv, 0, 0, 0x800);
        if (a >= 0) ac[accepted++] = a;
        else {
            if (a != -11) print_num("hello272: accept failed, rc ", a);
            sleep_ms(2);
        }
    }
    print_num("hello272: ms spent accepting: ", now_ms() - t_acc);
    {
        char tr[400];
        int64_t tf = syscall3(9, (uint64_t)"/proc/tcpstats", 0, 0);
        if (tf >= 0) { int64_t tn = syscall3(10, (uint64_t)tf, (uint64_t)tr, 390); syscall1(SYS_CLOSE, (uint64_t)tf); if (tn > 0) { tr[tn] = 0; print("hello272: tcpstats with every connection open: "); print(tr); } }
    }
    print_num("hello272: accepted: ", accepted);
    check(accepted == 40, "all 40 connections are accepted and held open at the same time");
    for (int i = 0; i < accepted; i++) { char m = 'z'; syscall3(SYS_WRITE, (uint64_t)ac[i], (uint64_t)&m, 1); }
    int st = -1;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    check(st == 0, "the client process connected all 40 and read its byte on each");
    for (int i = 0; i < accepted; i++) syscall1(SYS_CLOSE, (uint64_t)ac[i]);
    syscall1(SYS_CLOSE, (uint64_t)srv);
    print(failures == 0 ? "hello272: PASS\n" : "hello272: FAIL\n");
    print("hello272 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
