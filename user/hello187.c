/// hello187: fcntl / dup errno and flag semantics, checked against real Linux.

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
#define SYS_CLOSE     11
#define SYS_PIPE      22
#define SYS_SOCKETPAIR 53
#define SYS_UNLINK    87
#define SYS_FCNTL     142
#define SYS_EPOLL_CREATE1 146
#define SYS_EVENTFD2  169
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2
#define O_CREAT  0x40
#define O_EXCL   0x80
#define O_TRUNC  0x200
#define O_APPEND 0x400
#define O_NONBLOCK 0x800
#define O_DIRECT 0x4000
#define O_DIRECTORY 0x10000
#define O_NOATIME 0x40000
#define O_CLOEXEC 0x80000
#define F_DUPFD 0
#define F_GETFD 1
#define F_SETFD 2
#define F_GETFL 3
#define F_SETFL 4
#define F_GETLK 5
#define F_SETLK 6
#define F_SETLKW 7
#define F_GETLEASE 1025
#define F_SETPIPE_SZ 1031
#define F_GETPIPE_SZ 1032
#define F_DUPFD_CLOEXEC 1030

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello187:   ok   " : "hello187:   FAIL ");
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

static int64_t FCNTL(int64_t f, int64_t c, int64_t a) {
    return syscall3(SYS_FCNTL, (uint64_t)f, (uint64_t)c, (uint64_t)a);
}
static int64_t GETFD(int64_t f) { return FCNTL(f, F_GETFD, 0); }
/* O_LARGEFILE (0x8000) is added by libc on Linux; a raw syscall never sees it, so it is masked out. */
static int64_t GETFL(int64_t f) {
    int64_t r = FCNTL(f, F_GETFL, 0);
    return r < 0 ? r : (r & ~0x8000LL);
}
static int64_t CLOSE(int64_t f) { return syscall1(SYS_CLOSE, (uint64_t)f); }

/* Return values from real Linux, in the order of the table in _start. */
static const int64_t EXPECT[] = {
0, 1, 2, 0, 1, 1025, 65536, 0, 1, 2, 2, 2, 2, -9, -9, -9, -9, -9, -22, 0, 1, 0, 1, 0, 0, 0, 0, 2050, 0, 2, 0, 2050, 0, 2, 0, 1026, 0, 2, 0, 262146, 0, 16386, 0, 16384, 0, 2048, 0, 2050, 0, 2050, 0, 1, 20, 21, 30, 1, 0, 0, -22, -22, -22, -22, 50, 51, 52, 53, -14, -14, -14, -14, -14, 2, 2, -9, -9, -9, 4096, 4096, 4096, 4096, -9
};
static int idx = 0;
#define T(label, expr) do { \
        int64_t v_ = (expr); \
        if (v_ != EXPECT[idx]) { print("hello187:   got "); print_num(v_); } \
        check(v_ == EXPECT[idx], label); idx++; \
    } while (0)

void _start(void) {
    print("hello187: fcntl errno and flag conformance (expected values from real Linux)\n");
    const char *F = "/tmp/h187f";
    syscall1(SYS_UNLINK, (uint64_t)F);
    int32_t pp[2] = { -1, -1 }, sv[2] = { -1, -1 };
    syscall1(SYS_PIPE, (uint64_t)pp);
    int64_t p0 = pp[0], p1 = pp[1];
    int64_t rf = syscall3(SYS_OPEN, (uint64_t)F, O_CREAT | O_RDWR, 0644);
    int64_t ro = syscall3(SYS_OPEN, (uint64_t)F, O_RDONLY, 0);
    int64_t wo = syscall3(SYS_OPEN, (uint64_t)F, O_WRONLY, 0);
    int64_t ap = syscall3(SYS_OPEN, (uint64_t)F, O_WRONLY | O_APPEND, 0);
    int64_t dir = syscall3(SYS_OPEN, (uint64_t)"/tmp", O_RDONLY | O_DIRECTORY, 0);
    syscall4(SYS_SOCKETPAIR, 1, 1, 0, (uint64_t)sv);
    int64_t sv0 = sv[0];
    int64_t efd = syscall2(SYS_EVENTFD2, 0, 0);
    int64_t ep = syscall1(SYS_EPOLL_CREATE1, 0);
    int64_t nul = syscall3(SYS_OPEN, (uint64_t)"/dev/null", O_RDWR, 0);
    int64_t cl = syscall3(SYS_OPEN, (uint64_t)F, O_RDONLY | O_CLOEXEC, 0);
    check(p0 >= 0 && p1 >= 0 && rf >= 0 && ro >= 0 && wo >= 0 && ap >= 0 && dir >= 0 && sv0 >= 0 && efd >= 0 && ep >= 0 && nul >= 0 && cl >= 0, "setup: descriptors");
    T("getfd: plain file", GETFD(rf));
    T("getfd: O_CLOEXEC file", GETFD(cl));
    T("getfl: O_RDWR file", GETFL(rf));
    T("getfl: O_RDONLY file", GETFL(ro));
    T("getfl: O_WRONLY file", GETFL(wo));
    T("getfl: O_APPEND file", GETFL(ap));
    T("getfl: directory", GETFL(dir));
    T("getfl: pipe read end", GETFL(p0));
    T("getfl: pipe write end", GETFL(p1));
    T("getfl: unix socket", GETFL(sv0));
    T("getfl: eventfd", GETFL(efd));
    T("getfl: epoll", GETFL(ep));
    T("getfl: /dev/null", GETFL(nul));
    T("bad fd: getfd", GETFD(99));
    T("bad fd: -1", GETFD(-1));
    T("bad fd: getfl", GETFL(99));
    T("bad fd: dupfd", FCNTL(99, F_DUPFD, 0));
    T("bad fd and bad cmd", FCNTL(99, 9999, 0));
    T("good fd and bad cmd", FCNTL(rf, 9999, 0));
    T("setfd 1", FCNTL(rf, F_SETFD, 1));
    T("getfd after setfd 1", GETFD(rf));
    T("setfd 0xff", FCNTL(rf, F_SETFD, 0xff));
    T("getfd after setfd 0xff keeps only FD_CLOEXEC", GETFD(rf));
    T("setfd 2", FCNTL(rf, F_SETFD, 2));
    T("getfd after setfd 2", GETFD(rf));
    T("setfd 0", FCNTL(rf, F_SETFD, 0));
    T("setfl O_NONBLOCK", FCNTL(rf, F_SETFL, O_NONBLOCK));
    T("getfl after O_NONBLOCK", GETFL(rf));
    T("setfl 0 clears", FCNTL(rf, F_SETFL, 0));
    T("getfl after clear", GETFL(rf));
    T("setfl cannot change the access mode", FCNTL(rf, F_SETFL, O_RDONLY|O_NONBLOCK));
    T("getfl after access mode attempt", GETFL(rf));
    T("setfl O_WRONLY is ignored", FCNTL(rf, F_SETFL, O_WRONLY));
    T("getfl after O_WRONLY", GETFL(rf));
    T("setfl O_APPEND", FCNTL(rf, F_SETFL, O_APPEND));
    T("getfl after O_APPEND", GETFL(rf));
    T("setfl O_CREAT|O_TRUNC|O_EXCL are ignored", FCNTL(rf, F_SETFL, O_CREAT|O_TRUNC|O_EXCL));
    T("getfl after creation flags", GETFL(rf));
    T("setfl O_NOATIME", FCNTL(rf, F_SETFL, O_NOATIME));
    T("getfl after O_NOATIME", GETFL(rf));
    T("setfl O_DIRECT", FCNTL(rf, F_SETFL, O_DIRECT));
    T("getfl after O_DIRECT", GETFL(rf));
    T("setfl O_DIRECT on a pipe", FCNTL(p0, F_SETFL, O_DIRECT));
    T("getfl pipe after O_DIRECT", GETFL(p0));
    T("setfl O_NONBLOCK on a pipe", FCNTL(p0, F_SETFL, O_NONBLOCK));
    T("getfl pipe O_NONBLOCK", GETFL(p0));
    T("setfl O_NONBLOCK on a socket", FCNTL(sv0, F_SETFL, O_NONBLOCK));
    T("getfl socket O_NONBLOCK", GETFL(sv0));
    T("setfl O_NONBLOCK on eventfd", FCNTL(efd, F_SETFL, O_NONBLOCK));
    T("getfl eventfd O_NONBLOCK", GETFL(efd));
    T("setfl 0 on an O_APPEND file", FCNTL(ap, F_SETFL, 0));
    T("getfl O_APPEND cleared keeps O_WRONLY", GETFL(ap));
    T("dupfd 20", FCNTL(rf, F_DUPFD, 20));
    T("dupfd 20 again takes the next free", FCNTL(rf, F_DUPFD, 20));
    T("dupfd cloexec 30", FCNTL(rf, F_DUPFD_CLOEXEC, 30));
    T("getfd of the cloexec dup", GETFD(30));
    T("getfd of the plain dup", GETFD(20));
    T("dupfd of a cloexec fd is not cloexec", (FCNTL(cl, F_DUPFD, 40), GETFD(40)));
    T("dupfd min -1", FCNTL(rf, F_DUPFD, -1));
    T("dupfd min 1000000", FCNTL(rf, F_DUPFD, 1000000));
    T("dupfd cloexec min -1", FCNTL(rf, F_DUPFD_CLOEXEC, -1));
    T("dupfd cloexec min 1000000", FCNTL(rf, F_DUPFD_CLOEXEC, 1000000));
    T("dupfd of a pipe", FCNTL(p0, F_DUPFD, 50));
    T("dupfd of a socket", FCNTL(sv0, F_DUPFD, 51));
    T("dupfd of an epoll", FCNTL(ep, F_DUPFD, 52));
    T("dupfd of a directory", FCNTL(dir, F_DUPFD, 53));
    T("getlk with a bad pointer", FCNTL(rf, F_GETLK, 8));
    T("setlk with a bad pointer", FCNTL(rf, F_SETLK, 8));
    T("setlk with NULL", FCNTL(rf, F_SETLK, 0));
    T("setlkw with a bad pointer", FCNTL(rf, F_SETLKW, 8));
    T("getlk on a pipe with a bad pointer", FCNTL(p0, F_GETLK, 8));
    T("getlease on a file", FCNTL(rf, F_GETLEASE, 0));
    T("getlease on a pipe", FCNTL(p0, F_GETLEASE, 0));
    T("getpipe_sz on a file", FCNTL(rf, F_GETPIPE_SZ, 0));
    T("getpipe_sz on a socket", FCNTL(sv0, F_GETPIPE_SZ, 0));
    T("setpipe_sz on a file", FCNTL(rf, F_SETPIPE_SZ, 4096));
    T("setpipe_sz 4096", FCNTL(p0, F_SETPIPE_SZ, 4096));
    T("getpipe_sz after setting 4096", FCNTL(p0, F_GETPIPE_SZ, 0));
    T("setpipe_sz 1 rounds up to a page", FCNTL(p0, F_SETPIPE_SZ, 1));
    T("setpipe_sz 0 rounds up to a page", FCNTL(p0, F_SETPIPE_SZ, 0));
    T("close then getfd", (CLOSE(rf), GETFD(rf)));
    check(idx == (int)(sizeof(EXPECT) / sizeof(EXPECT[0])), "every table entry was exercised");

    syscall1(SYS_UNLINK, (uint64_t)F);
    print(failures == 0 ? "hello187: PASS\n" : "hello187: FAIL\n");
    print("hello187 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
