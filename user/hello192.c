/// hello192: stateful hostile-argument sweep (SEQUENCES = 1200 here; a 5000-sequence run of 20,000 calls was clean too). hello190 and hello191 call each system call in a fresh process
/// that owns only its standard streams, so no call ever touches a pipe, socket, epoll set, eventfd, timerfd,
/// inotify instance, file or mapping. Here every child first builds one of each (the descriptors are known),
/// then runs a short chain of random system calls whose arguments favour those descriptors, so calls reach the
/// code that works on real objects and later calls meet the state earlier ones left behind. The sequence is
/// fully determined by its number (xorshift), and "fz <seq>" / "c <nr>" lines name the culprit if the kernel
/// panics. The kernel must answer every call without panicking or hanging, and still fork and reap afterwards.

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
#define SYS_MMAP      8
#define SYS_OPEN      9
#define SYS_PIPE      22
#define SYS_SCHED_YIELD 24
#define SYS_NANOSLEEP 35
#define SYS_FORK      57
#define SYS_KILL      62
#define SYS_SETSID    206
#define SYS_WAIT4     263
#define SYS_SOCKETPAIR 53
#define SYS_SOCKET    117
#define SYS_BIND      118
#define SYS_LISTEN    119
#define SYS_FCNTL     142
#define SYS_EPOLL_CREATE1 146
#define SYS_EPOLL_CTL 147
#define SYS_INOTIFY_INIT1 166
#define SYS_EVENTFD2  169
#define SYS_TIMERFD_CREATE 170
#define WNOHANG       1
#define NSYS          512
#define SEQUENCES     1200
#define CHAIN         4
#define BUFSZ         65536
#define MAXOBJ        16

struct ts { int64_t s, n; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static void print_num(uint64_t x) {
    char r[24]; int m = 0; char o[28]; int k = 0;
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k] = 0;
    print(o);
}

/* Calls that would end the run or damage other tests on purpose (same list as hello190/191). */
static const int SKIP[] = { 2,5,29,56,57,58,59,60,62,64,68,149,153,156,205,206,207,220,222,223,224,226,233,238,243,262,264,266,270,273,279,283,284,288,289,295,296,308,316,318,319,322,334,424,428,429,432,433,435,442,457,458,467,472,473,484,485 };
static int skipped(int n) {
    for (unsigned i = 0; i < sizeof(SKIP) / sizeof(SKIP[0]); i++) {
        if (SKIP[i] == n) return 1;
    }
    return 0;
}

static uint64_t rng_state;
static uint64_t rnd(void) {
    uint64_t x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    rng_state = x;
    return x;
}

static unsigned char buf[BUFSZ] __attribute__((aligned(4096)));
static uint64_t objs[MAXOBJ];
static int nobjs;

static void add_obj(int64_t fd) {
    if (fd >= 0 && nobjs < MAXOBJ) {
        objs[nobjs++] = (uint64_t)fd;
        syscall3(SYS_FCNTL, (uint64_t)fd, 4 /* F_SETFL */, 0x800 /* O_NONBLOCK */);
    }
}

/* One of every object type, so a call that is handed any of these descriptors reaches real code. */
static void build_objects(int seq) {
    int32_t two[2];
    nobjs = 0;
    if (syscall1(SYS_PIPE, (uint64_t)two) == 0) { add_obj(two[0]); add_obj(two[1]); }
    if (syscall4(SYS_SOCKETPAIR, 1 /* AF_UNIX */, 1 /* STREAM */, 0, (uint64_t)two) == 0) { add_obj(two[0]); add_obj(two[1]); }
    if (syscall4(SYS_SOCKETPAIR, 1, 2 /* DGRAM */, 0, (uint64_t)two) == 0) { add_obj(two[0]); }
    int64_t tcp = syscall3(SYS_SOCKET, 2 /* AF_INET */, 1 /* STREAM */, 0);
    if (tcp >= 0) {
        uint8_t sa[16] = { 2, 0, 0, 0, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
        uint16_t port = (uint16_t)(20000 + seq % 200);
        sa[2] = (uint8_t)(port >> 8); sa[3] = (uint8_t)port;
        syscall3(SYS_BIND, (uint64_t)tcp, (uint64_t)sa, 16);
        syscall3(SYS_LISTEN, (uint64_t)tcp, 4, 0);
        add_obj(tcp);
    }
    int64_t udp = syscall3(SYS_SOCKET, 2, 2 /* DGRAM */, 0);
    if (udp >= 0) add_obj(udp);
    add_obj(syscall2(SYS_EVENTFD2, 1, 0));
    add_obj(syscall2(SYS_TIMERFD_CREATE, 1 /* CLOCK_MONOTONIC */, 0));
    add_obj(syscall1(SYS_INOTIFY_INIT1, 0));
    int64_t ep = syscall1(SYS_EPOLL_CREATE1, 0);
    if (ep >= 0) {
        struct { uint32_t events; uint64_t data; } __attribute__((packed)) ev = { 1, 0 };
        for (int i = 0; i < nobjs && i < 6; i++) syscall4(SYS_EPOLL_CTL, (uint64_t)ep, 1, objs[i], (uint64_t)&ev);
        add_obj(ep);
    }
    int64_t f = syscall3(SYS_OPEN, (uint64_t)"/tmp/h192f", 0x42 /* O_CREAT|O_RDWR */, 0644);
    if (f >= 0) {
        syscall3(SYS_WRITE, (uint64_t)f, (uint64_t)buf, 4096);
        add_obj(f);
        syscall6(SYS_MMAP, 0, 8192, 3, 1 /* MAP_SHARED */, (uint64_t)f, 0);
    }
    syscall6(SYS_MMAP, 0, 16384, 3, 0x22, (uint64_t)-1, 0);
}

static const uint64_t SMALL[] = { 0, 1, 2, 3, 4, 5, 7, 8, 12, 16, 24, 32, 64, 100, 128, 255, 256, 1024, 4096, 65536 };
static const uint64_t BAD[] = { ~0ULL, 0x8000000000000000ULL, 0x100000000ULL, 0xffff800000000000ULL, 0x7fffffffULL, 0x80000000ULL };

static uint64_t pick(int i) {
    uint64_t r = rnd();
    uint64_t k = r % 100;
    r = rnd();
    if (i == 0 && k < 60 && nobjs > 0) return objs[r % (uint64_t)nobjs];            /* the first argument is usually an object */
    if (k < 20 && nobjs > 0) return objs[r % (uint64_t)nobjs];
    if (k < 45) return SMALL[r % (sizeof(SMALL) / sizeof(SMALL[0]))];
    if (k < 75) return (uint64_t)&buf[(r % (BUFSZ - 64)) & ~7ULL];
    if (k < 82) return r % 24;
    if (k < 92) return BAD[r % (sizeof(BAD) / sizeof(BAD[0]))];
    return r;
}

static int pick_call(void) {
    for (;;) {
        int nr = (int)(rnd() % NSYS);
        if (!skipped(nr)) return nr;
    }
}

void _start(void) {
    print("hello192: stateful hostile-argument sweep\n");
    rng_state = 0x9e3779b97f4a7c15ULL;
    for (int i = 0; i < BUFSZ / 2; i++) buf[i] = (unsigned char)(0x20 + rnd() % 0x5f);
    for (int i = BUFSZ / 2; i < BUFSZ; i++) buf[i] = (unsigned char)rnd();
    int calls = 0, killed = 0;
    for (int seq = 0; seq < SEQUENCES; seq++) {
        int64_t pid = syscall1(SYS_FORK, 0);
        if (pid == 0) {
            syscall1(SYS_SETSID, 0);
            print("fz "); print_num((uint64_t)seq); print("\n");
            build_objects(seq);
            rng_state = 0x2545f4914f6cdd1dULL ^ ((uint64_t)(seq + 1) * 0xbf58476d1ce4e5b9ULL);
            if (rng_state == 0) rng_state = 1;
            for (int c = 0; c < CHAIN; c++) {
                int nr = pick_call();
                uint64_t a[6];
                for (int i = 0; i < 6; i++) a[i] = pick(i);
                print("c "); print_num((uint64_t)nr); print("\n");
                syscall6((uint64_t)nr, a[0], a[1], a[2], a[3], a[4], a[5]);
            }
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        if (pid < 0) { print("hello192:   FAIL fork failed\n"); print("hello192: FAIL\n"); syscall1(SYS_EXIT, 1); }
        calls += CHAIN;
        int done = 0;
        for (int w = 0; w < 500 && !done; w++) {
            int st = 0;
            int64_t r = syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, WNOHANG, 0);
            if (r == pid) { done = 1; break; }
            if (w < 300) { syscall1(SYS_SCHED_YIELD, 0); continue; }
            struct ts t = { 0, 10 * 1000 * 1000 };
            syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
        }
        if (!done) {
            syscall2(SYS_KILL, (uint64_t)pid, 9);
            int st = 0;
            syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, 0, 0);
            killed++;
        }
    }
    print("hello192: calls="); print_num((uint64_t)calls);
    print(" blocked-and-killed="); print_num((uint64_t)killed); print("\n");
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) { syscall1(SYS_EXIT, 7); for (;;) {} }
    int st = 0;
    int64_t r = syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, 0, 0);
    int ok = pid > 0 && r == pid && ((st >> 8) & 0xff) == 7;
    print(ok ? "hello192:   ok   the kernel still forks and reaps after the sweep\n" : "hello192:   FAIL the kernel no longer forks and reaps\n");
    print(ok ? "hello192: PASS\n" : "hello192: FAIL\n");
    print("hello192 done\n");
    syscall1(SYS_EXIT, ok ? 0 : 1);
    for (;;) {}
}
