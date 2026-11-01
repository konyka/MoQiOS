/// hello186: epoll_ctl / epoll_wait errno and struct epoll_event layout, checked against real Linux.

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
#define SYS_PIPE      22
#define SYS_DUP       32
#define SYS_UNLINK    87
#define SYS_EVENTFD2  169
#define SYS_EPOLL_CREATE1 146
#define SYS_EPOLL_CTL 147
#define SYS_EPOLL_WAIT 148
#define O_RDONLY 0
#define O_RDWR   2
#define O_CREAT  0x40
#define O_DIRECTORY 0x10000
#define ADD 1
#define DEL 2
#define MOD 3
#define EPOLLIN        0x001u
#define EPOLLOUT       0x004u
#define EPOLLPRI       0x002u
#define EPOLLRDHUP     0x2000u
#define EPOLLEXCLUSIVE 0x10000000u
#define EPOLLONESHOT   0x40000000u
#define EPOLLET        0x80000000u
#define KP ((void *)0xffff800000000000ULL)
#define NULL ((void *)0)

struct epev { uint32_t events; uint64_t data; } __attribute__((packed));

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello186:   ok   " : "hello186:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void print_num(int64_t x) {
    char r[24]; int m = 0; char o[40]; int k = 0;
    if (x < 0) { o[k++] = '-'; x = -x; }
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k++] = '\n'; o[k] = 0;
    print(o);
}

static int64_t CTL(int64_t e, int64_t o, int64_t f, const void *p) {
    return syscall4(SYS_EPOLL_CTL, (uint64_t)e, (uint64_t)o, (uint64_t)f, (uint64_t)p);
}
static int64_t WAIT(int64_t e, const void *b, int64_t m) {
    return syscall4(SYS_EPOLL_WAIT, (uint64_t)e, (uint64_t)b, (uint64_t)m, 0);
}

/* Return values from real Linux, in the order of the table in _start. */
static const int64_t EXPECT[] = {
-9, -9, -22, -9, -9, -22, -22, -1, -1, -1, -14, -14, -14, -22, -22, -14, -1, -2, -2, -2, 0, -17, 0, -14, 0, -2, 0, 0, -40, -14, -9, -1, -1, -22, -22, -22, -22, -22, -1, 0, 0, 0, -17, -22, 0, -9, -9, -9, -9, -22, -14, -22, -22, -22, -22, -22, -14, -22, -22, -14, 0, 0, 0, 0, 0, -22, -22
};
static int idx = 0;
#define T(label, expr) do { \
        int64_t v_ = (expr); \
        if (v_ != EXPECT[idx]) { print("hello186:   got "); print_num(v_); } \
        check(v_ == EXPECT[idx], label); idx++; \
    } while (0)

static struct epev out[130];

void _start(void) {
    print("hello186: epoll errno and layout conformance (expected values from real Linux)\n");
    const char *F = "/tmp/h186f";
    syscall1(SYS_UNLINK, (uint64_t)F);
    int64_t ep = syscall1(SYS_EPOLL_CREATE1, 0), ep2 = syscall1(SYS_EPOLL_CREATE1, 0), epe = syscall1(SYS_EPOLL_CREATE1, 0);
    int64_t epd = syscall1(SYS_DUP, (uint64_t)ep);
    int32_t pp[2] = { -1, -1 };
    syscall1(SYS_PIPE, (uint64_t)pp);
    int64_t p0 = pp[0], p1 = pp[1];
    int64_t rf = syscall3(SYS_OPEN, (uint64_t)F, O_CREAT | O_RDWR, 0644);
    int64_t dir = syscall3(SYS_OPEN, (uint64_t)"/tmp", O_RDONLY | O_DIRECTORY, 0);
    int64_t efd = syscall2(SYS_EVENTFD2, 0, 0);
    int64_t procf = syscall3(SYS_OPEN, (uint64_t)"/proc/irqtime", O_RDONLY, 0);
    check(ep >= 0 && ep2 >= 0 && epe >= 0 && epd >= 0 && p0 >= 0 && p1 >= 0 && rf >= 0 && dir >= 0 && efd >= 0 && procf >= 0, "setup: descriptors");
    struct epev ev = { EPOLLIN, 0 };
    struct epev evx = { EPOLLIN | EPOLLEXCLUSIVE, 0 };
    struct epev evx_oneshot = { EPOLLIN | EPOLLEXCLUSIVE | EPOLLONESHOT, 0 };
    struct epev evx_rdhup = { EPOLLIN | EPOLLEXCLUSIVE | EPOLLRDHUP, 0 };
    struct epev evx_et = { EPOLLIN | EPOLLEXCLUSIVE | EPOLLET, 0 };
    struct epev evx_pri = { EPOLLPRI | EPOLLEXCLUSIVE, 0 };
    struct epev evx_out = { EPOLLOUT | EPOLLEXCLUSIVE, 0 };
    T("ctl: bad epfd", CTL(99, ADD, p0, &ev));
    T("ctl: epfd -1", CTL(-1, ADD, p0, &ev));
    T("ctl: epfd is a pipe", CTL(p0, ADD, p1, &ev));
    T("ctl: bad target", CTL(ep, ADD, 99, &ev));
    T("ctl: target -1", CTL(ep, ADD, -1, &ev));
    T("ctl: add itself", CTL(ep, ADD, ep, &ev));
    T("ctl: add a dup of itself", CTL(ep, ADD, epd, &ev));
    T("ctl: regular file", CTL(ep, ADD, rf, &ev));
    T("ctl: directory", CTL(ep, ADD, dir, &ev));
    T("ctl: proc file", CTL(ep, ADD, procf, &ev));
    T("ctl: ADD NULL event", CTL(ep, ADD, p0, NULL));
    T("ctl: ADD unmapped event", CTL(ep, ADD, p0, (void *)8));
    T("ctl: ADD kernel-address event", CTL(ep, ADD, p0, KP));
    T("ctl: op 9", CTL(ep, 9, p0, &ev));
    T("ctl: op 0", CTL(ep, 0, p0, &ev));
    T("ctl: op 9 NULL event", CTL(ep, 9, p0, NULL));
    T("ctl: op 9 on a regular file", CTL(ep, 9, rf, &ev));
    T("ctl: MOD unregistered", CTL(ep, MOD, p0, &ev));
    T("ctl: DEL unregistered", CTL(ep, DEL, p0, NULL));
    T("ctl: DEL unregistered, garbage event pointer", CTL(ep, DEL, p0, (void *)8));
    T("ctl: ADD pipe", CTL(ep, ADD, p0, &ev));
    T("ctl: ADD pipe twice", CTL(ep, ADD, p0, &ev));
    T("ctl: MOD pipe", CTL(ep, MOD, p0, &ev));
    T("ctl: MOD NULL event", CTL(ep, MOD, p0, NULL));
    T("ctl: DEL pipe with NULL event", CTL(ep, DEL, p0, NULL));
    T("ctl: DEL pipe again", CTL(ep, DEL, p0, NULL));
    T("ctl: ADD eventfd", CTL(ep, ADD, efd, &ev));
    T("ctl: ADD an epoll fd", CTL(ep, ADD, ep2, &ev));
    T("ctl: add a loop", CTL(ep2, ADD, ep, &ev));
    T("ctl: bad epfd, bad target, NULL event", CTL(99, ADD, 98, NULL));
    T("ctl: bad epfd DEL", CTL(99, DEL, 98, NULL));
    T("ctl: pipe epfd DEL file", CTL(p0, DEL, rf, NULL));
    T("ctl: DEL directory", CTL(ep, DEL, dir, NULL));
    T("ctl: EXCLUSIVE with MOD", CTL(ep, MOD, efd, &evx));
    T("ctl: EXCLUSIVE with ONESHOT", CTL(epe, ADD, p0, &evx_oneshot));
    T("ctl: EXCLUSIVE with RDHUP", CTL(epe, ADD, p0, &evx_rdhup));
    T("ctl: EXCLUSIVE with PRI", CTL(epe, ADD, p0, &evx_pri));
    T("ctl: EXCLUSIVE on an epoll fd", CTL(epe, ADD, ep2, &evx));
    T("ctl: EXCLUSIVE on a regular file", CTL(epe, ADD, rf, &evx));
    T("ctl: EXCLUSIVE with ET", CTL(epe, ADD, p0, &evx_et));
    T("ctl: EXCLUSIVE plain", CTL(epe, ADD, efd, &evx));
    T("ctl: EXCLUSIVE with OUT", CTL(epe, ADD, p1, &evx_out));
    T("ctl: EXCLUSIVE twice", CTL(epe, ADD, p1, &evx_out));
    T("ctl: MOD an EXCLUSIVE registration", CTL(epe, MOD, p1, &ev));
    T("ctl: DEL an EXCLUSIVE registration", CTL(epe, DEL, p1, NULL));
    T("wait: bad epfd, maxevents 0", WAIT(99, out, 0));
    T("wait: bad epfd, kernel buffer", WAIT(99, KP, 4));
    T("wait: bad epfd", WAIT(99, out, 4));
    T("wait: bad epfd, kernel buffer, maxevents 0", WAIT(99, KP, 0));
    T("wait: pipe epfd", WAIT(p0, out, 4));
    T("wait: pipe epfd, kernel buffer", WAIT(p0, KP, 4));
    T("wait: pipe epfd, maxevents 0", WAIT(p0, out, 0));
    T("wait: pipe epfd, maxevents -1", WAIT(p0, out, -1));
    T("wait: pipe epfd, NULL buffer", WAIT(p0, NULL, 4));
    T("wait: maxevents 0", WAIT(ep2, out, 0));
    T("wait: maxevents -1", WAIT(ep2, out, -1));
    T("wait: kernel buffer", WAIT(ep2, KP, 4));
    T("wait: kernel buffer, maxevents 0", WAIT(ep2, KP, 0));
    T("wait: kernel buffer, maxevents -1", WAIT(ep2, KP, -1));
    T("wait: top-of-address-space buffer", WAIT(ep2, (void *)0x00007ffffffff000UL, 1000));
    T("wait: maxevents 1", WAIT(ep2, out, 1));
    T("wait: maxevents 128", WAIT(ep2, out, 128));
    T("wait: maxevents 129", WAIT(ep2, out, 129));
    T("wait: maxevents 1024", WAIT(ep2, out, 1024));
    T("wait: maxevents 178956970", WAIT(ep2, out, 178956970));
    T("wait: maxevents 178956971", WAIT(ep2, out, 178956971));
    T("wait: maxevents INT_MAX", WAIT(ep2, out, 0x7fffffff));
    check(idx == (int)(sizeof(EXPECT) / sizeof(EXPECT[0])), "every table entry was exercised");

    syscall1(SYS_UNLINK, (uint64_t)F);
    print(failures == 0 ? "hello186: PASS\n" : "hello186: FAIL\n");
    print("hello186 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
