/// hello112: sigaltstack delivery and undeliverable-signal handling.
///
///   A. sigaltstack set/query round-trips; undersized stacks are ENOMEM.
///   B. an SA_ONSTACK handler runs on the alternate stack, sees SS_ONSTACK,
///      and cannot change the stack while on it (EPERM).
///   C. a handler without SA_ONSTACK stays on the normal stack.
///   D. a signal whose frame cannot be written (RSP points at unmapped
///      memory) kills the process with SIGSEGV instead of being dropped.
///   E. mprotect(PROT_WRITE) on a MAP_SHARED mapping of a read-only fd is
///      EACCES (the mapping can never write the file).
///   F. a page past EOF at mmap time becomes readable once the file grows;
///      a page still past EOF raises SIGBUS.
///   G. mincore reports real residency; msync rejects bad flags.
///   H. brk does not grow across a not-yet-faulted file mapping.
///   I. with the region table full, an adjacent mapping whose prot differs
///      (so it cannot merge) fails with ENOMEM instead of panicking.
///   J. an epoll registration survives the registering process closing its
///      fd while a fork child still holds the same pipe end.

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

static inline int64_t syscall4_(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_WAITPID     6
#define SYS_MMAP        8
#define SYS_SIGACTION   13
#define SYS_GETPID      39
#define SYS_FORK        57
#define SYS_KILL        62
#define SYS_SIGALTSTACK 218
#define SYS_OPEN        9
#define SYS_CLOSE       11
#define SYS_UNLINK      111
#define SYS_MPROTECT    164
#define SYS_MUNMAP      12
#define SYS_MINCORE     27
#define SYS_PIPE        22
#define SYS_EPOLL_CREATE1 146
#define SYS_EPOLL_CTL   147
#define SYS_EPOLL_WAIT  148
#define SYS_NANOSLEEP   35
#define SYS_MSYNC       26
#define EACCES 13

#define SIGUSR1 10
#define SIGUSR2 31
#define SIGSEGV 11
#define SA_ONSTACK 0x08000000ULL
#define SS_ONSTACK 1
#define SS_DISABLE 2
#define EPERM  1
#define ENOMEM 12
#define ALT_SIZE (16 * 4096)

struct ksigaction { uint64_t handler, flags, restorer, mask; };
struct kstack { uint64_t sp; int32_t flags; int32_t pad; uint64_t size; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello112:   ok   " : "hello112:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static uint64_t alt_base = 0;
static volatile uint64_t seen_sp = 0;
static volatile int32_t seen_flags = -1;
static volatile int64_t seen_set = 0;

static void on_usr1(int s) {
    (void)s;
    volatile int local = 0;
    seen_sp = (uint64_t)&local;
    struct kstack old = { 0, 0, 0, 0 };
    syscall2(SYS_SIGALTSTACK, 0, (uint64_t)&old);
    seen_flags = old.flags;
    struct kstack other = { alt_base, 0, 0, ALT_SIZE };
    seen_set = syscall2(SYS_SIGALTSTACK, (uint64_t)&other, 0);
}

static void on_usr2(int s) {
    (void)s;
    volatile int local = 0;
    seen_sp = (uint64_t)&local;
}

static int on_alt(uint64_t sp) { return sp > alt_base && sp <= alt_base + ALT_SIZE; }

static long install(int sig, uint64_t handler, uint64_t flags) {
    struct ksigaction a = { handler, flags, 0, 0 };
    return syscall3(SYS_SIGACTION, sig, (uint64_t)&a, 0);
}

void _start(void) {
    print("hello112: sigaltstack delivery and undeliverable signals\n");
    int64_t pid = syscall1(SYS_GETPID, 0);

    /* A. set / query */
    int64_t m = syscall6(SYS_MMAP, 0, ALT_SIZE, 3, 0x22, (uint64_t)-1, 0);
    check(m > 0, "A: mmap alternate stack");
    alt_base = (uint64_t)m;
    struct kstack small = { alt_base, 0, 0, 1024 };
    check(syscall2(SYS_SIGALTSTACK, (uint64_t)&small, 0) == -ENOMEM, "A: undersized stack is ENOMEM");
    struct kstack ss = { alt_base, 0, 0, ALT_SIZE };
    check(syscall2(SYS_SIGALTSTACK, (uint64_t)&ss, 0) == 0, "A: sigaltstack accepted");
    struct kstack q = { 0, -1, 0, 0 };
    syscall2(SYS_SIGALTSTACK, 0, (uint64_t)&q);
    check(q.sp == alt_base && q.size == ALT_SIZE && q.flags == 0, "A: query reports the stack, not on it");

    /* B. SA_ONSTACK */
    install(SIGUSR1, (uint64_t)on_usr1, SA_ONSTACK);
    syscall2(SYS_KILL, (uint64_t)pid, SIGUSR1);
    check(on_alt(seen_sp), "B: SA_ONSTACK handler ran on the alternate stack");
    check(seen_flags == SS_ONSTACK, "B: handler sees SS_ONSTACK");
    check(seen_set == -EPERM, "B: changing the stack while on it is EPERM");

    /* C. no SA_ONSTACK */
    seen_sp = 0;
    install(SIGUSR2, (uint64_t)on_usr2, 0);
    syscall2(SYS_KILL, (uint64_t)pid, SIGUSR2);
    check(seen_sp != 0 && !on_alt(seen_sp), "C: plain handler stays on the normal stack");

    struct kstack off = { 0, SS_DISABLE, 0, 0 };
    syscall2(SYS_SIGALTSTACK, (uint64_t)&off, 0);
    q.flags = 0;
    syscall2(SYS_SIGALTSTACK, 0, (uint64_t)&q);
    check(q.flags == SS_DISABLE, "C: SS_DISABLE turns it off");

    /* D. frame cannot be written: the child dies by SIGSEGV */
    int64_t child = syscall1(SYS_FORK, 0);
    if (child == 0) {
        install(SIGUSR1, (uint64_t)on_usr2, 0);
        int64_t me = syscall1(SYS_GETPID, 0);
        register uint64_t bad __asm__("rbx") = 0x500000000ULL;
        __asm__ volatile (
            "mov %%rbx, %%rsp\n"
            "mov $62, %%eax\n"
            "syscall\n"
            "mov $2, %%eax\n"
            "xor %%edi, %%edi\n"
            "syscall\n"
            "1: jmp 1b\n"
            :: "r"(bad), "D"(me), "S"((uint64_t)SIGUSR1) : "rax", "rcx", "r11", "memory");
    }
    int32_t st = 0;
    int64_t r = syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&st, 0);
    check(r == child && (st & 0x7f) == SIGSEGV, "D: undeliverable signal kills with SIGSEGV");

    /* E. shared mapping of a read-only fd */
    static const char path[] = "hello112-ro";
    int64_t wfd = syscall3(SYS_OPEN, (uint64_t)path, 2 | 64 | 512, 0666);
    check(wfd >= 0, "E: create file");
    static const char page_data[16] = "hello112 data";
    syscall3(SYS_WRITE, (uint64_t)wfd, (uint64_t)page_data, sizeof(page_data));
    syscall1(SYS_CLOSE, (uint64_t)wfd);
    int64_t rfd = syscall3(SYS_OPEN, (uint64_t)path, 0, 0);
    check(rfd >= 0, "E: reopen read-only");
    int64_t sm = syscall6(SYS_MMAP, 0, 4096, 1, 0x01, (uint64_t)rfd, 0);
    check(sm > 0, "E: MAP_SHARED PROT_READ of a read-only fd");
    if (sm > 0) {
        check(syscall3(SYS_MPROTECT, (uint64_t)sm, 4096, 3) == -EACCES, "E: mprotect(PROT_WRITE) is EACCES");
        check(syscall3(SYS_MPROTECT, (uint64_t)sm, 4096, 1) == 0, "E: mprotect(PROT_READ) still allowed");
        syscall2(SYS_MUNMAP, (uint64_t)sm, 4096);
    }
    syscall1(SYS_CLOSE, (uint64_t)rfd);
    syscall1(SYS_UNLINK, (uint64_t)path);

    /* F. file growth after mmap; past-EOF access is SIGBUS */
    static const char gpath[] = "hello112-grow";
    static char block[4096];
    for (int i = 0; i < 4096; i++) block[i] = 'a';
    int64_t gfd = syscall3(SYS_OPEN, (uint64_t)gpath, 2 | 64 | 512, 0666);
    check(gfd >= 0, "F: create file");
    syscall3(SYS_WRITE, (uint64_t)gfd, (uint64_t)block, 4096);
    int64_t gm = syscall6(SYS_MMAP, 0, 3 * 4096, 1, 0x01, (uint64_t)gfd, 0);
    check(gm > 0, "F: map 3 pages of a 1-page file");
    if (gm > 0) {
        volatile char *gp = (volatile char *)gm;
        check(gp[0] == 'a', "F: first page served");
        for (int i = 0; i < 4096; i++) block[i] = 'b';
        syscall3(SYS_WRITE, (uint64_t)gfd, (uint64_t)block, 4096);
        check(gp[4096] == 'b', "F: page added after mmap is served");
        int64_t c = syscall1(SYS_FORK, 0);
        if (c == 0) {
            (void)gp[2 * 4096];
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        int32_t gst = 0;
        syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&gst, 0);
        check((gst & 0x7f) == 7, "F: page still past EOF raises SIGBUS");
        syscall2(SYS_MUNMAP, (uint64_t)gm, 3 * 4096);
    }
    syscall1(SYS_CLOSE, (uint64_t)gfd);
    syscall1(SYS_UNLINK, (uint64_t)gpath);

    /* G. mincore / msync */
    int64_t am = syscall6(SYS_MMAP, 0, 2 * 4096, 3, 0x22, (uint64_t)-1, 0);
    check(am > 0, "G: map 2 anonymous pages");
    if (am > 0) {
        unsigned char vec[2] = { 0xff, 0xff };
        ((volatile char *)am)[0] = 1;
        syscall6(28, (uint64_t)am + 4096, 4096, 4 /* MADV_DONTNEED */, 0, 0, 0);
        check(syscall3(SYS_MINCORE, (uint64_t)am, 2 * 4096, (uint64_t)vec) == 0, "G: mincore succeeds");
        check((vec[0] & 1) == 1, "G: touched page is resident");
        check(syscall3(SYS_MSYNC, (uint64_t)am, 4096, 4 | 1) == -22, "G: msync MS_SYNC|MS_ASYNC is EINVAL");
        check(syscall3(SYS_MSYNC, (uint64_t)am, 4096, 0x40) == -22, "G: msync unknown flag is EINVAL");
        check(syscall3(SYS_MSYNC, (uint64_t)am, 4096, 4) == 0, "G: msync MS_SYNC succeeds");
        syscall2(SYS_MUNMAP, (uint64_t)am, 2 * 4096);
    }

    /* H. brk vs un-faulted file mapping */
    uint64_t brk0 = (uint64_t)syscall1(7, 0);
    uint64_t above = (brk0 + 0x10000 + 4095) & ~4095ULL;
    static const char hpath[] = "hello112-brk";
    int64_t hfd = syscall3(SYS_OPEN, (uint64_t)hpath, 2 | 64 | 512, 0666);
    syscall3(SYS_WRITE, (uint64_t)hfd, (uint64_t)block, 4096);
    int64_t hm = syscall6(SYS_MMAP, above, 4096, 1, 0x02 | 0x10 /* PRIVATE|FIXED */, (uint64_t)hfd, 0);
    check(hm == (int64_t)above, "H: file mapped just above the break");
    if (hm == (int64_t)above) {
        uint64_t got = (uint64_t)syscall1(7, above + 2 * 4096);
        check(got == brk0, "H: brk refuses to grow across the mapping");
        check(((volatile char *)hm)[0] == 'b', "H: mapping still serves the file");
        syscall2(SYS_MUNMAP, (uint64_t)hm, 4096);
    }
    syscall1(SYS_CLOSE, (uint64_t)hfd);
    syscall1(SYS_UNLINK, (uint64_t)hpath);

    /* I. full region table + adjacent non-mergeable mapping */
    {
        static int64_t maps[80];
        static uint64_t prots[80];
        int n = 0;
        uint64_t base = 0x300000000ULL;
        while (n < 80) {
            uint64_t prot = (n & 1) ? 1 : 3;
            int64_t r = syscall6(SYS_MMAP, base + (uint64_t)n * 4096, 4096, prot, 0x22 | 0x10, (uint64_t)-1, 0);
            if (r < 0) break;
            maps[n] = r;
            prots[n] = prot;
            n++;
        }
        check(n > 0 && n < 80, "I: region table fills up");
        if (n > 0) {
            uint64_t other = prots[n - 1] == 3 ? 1 : 3;
            int64_t r = syscall6(SYS_MMAP, base + (uint64_t)n * 4096, 4096, other, 0x22, (uint64_t)-1, 0);
            check(r == -ENOMEM, "I: unmergeable adjacent hint is ENOMEM (no panic)");
            if (r > 0) syscall2(SYS_MUNMAP, (uint64_t)r, 4096);
            int64_t same = syscall6(SYS_MMAP, base + (uint64_t)n * 4096, 4096, prots[n - 1], 0x22, (uint64_t)-1, 0);
            check(same == (int64_t)(base + (uint64_t)n * 4096), "I: mergeable adjacent hint still succeeds");
            if (same > 0) syscall2(SYS_MUNMAP, (uint64_t)same, 4096);
        }
        for (int i = 0; i < n; i++) syscall2(SYS_MUNMAP, (uint64_t)maps[i], 4096);
    }

    /* J. epoll registration vs fork + close of the registering copy */
    {
        int32_t pfd[2] = { -1, -1 };
        int64_t ep = syscall1(SYS_EPOLL_CREATE1, 0);
        check(syscall1(SYS_PIPE, (uint64_t)pfd) == 0 && ep >= 0, "J: pipe + epoll_create1");
        struct { uint32_t events; uint64_t data; } ev = { 1 /* EPOLLIN */, 77 }, out = { 0, 0 };
        check(syscall4_(SYS_EPOLL_CTL, (uint64_t)ep, 1 /* ADD */, (uint64_t)pfd[0], (uint64_t)&ev) == 0, "J: register pipe read end");
        int64_t c = syscall1(SYS_FORK, 0);
        if (c == 0) {
            /* child keeps pfd[0]; wait until the parent closed its copy */
            int64_t ts[2] = { 0, 100 * 1000000 };
            syscall2(SYS_NANOSLEEP, (uint64_t)ts, 0);
            int64_t n = syscall4_(SYS_EPOLL_WAIT, (uint64_t)ep, (uint64_t)&out, 1, 2000);
            syscall1(SYS_EXIT, (n == 1 && out.data == 77) ? 0 : 1);
            for (;;) {}
        }
        syscall1(SYS_CLOSE, (uint64_t)pfd[0]);
        int64_t ts2[2] = { 0, 200 * 1000000 };
        syscall2(SYS_NANOSLEEP, (uint64_t)ts2, 0);
        syscall3(SYS_WRITE, (uint64_t)pfd[1], (uint64_t)"x", 1);
        int32_t jst = 0;
        syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&jst, 0);
        check((jst & 0x7f) == 0 && ((jst >> 8) & 0xff) == 0, "J: child sees EPOLLIN after the parent closed its copy");
        syscall1(SYS_CLOSE, (uint64_t)pfd[1]);
        syscall1(SYS_CLOSE, (uint64_t)ep);
    }

    print(failures == 0 ? "hello112: PASS\n" : "hello112: FAIL\n");
    print("hello112 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
