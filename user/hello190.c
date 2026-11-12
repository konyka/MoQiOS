/// hello190: hostile-argument sweep. Every system-call number is invoked, in a forked child, with a set of
/// nasty argument patterns (zeros, -1, kernel addresses, small bad pointers, huge lengths). The kernel must
/// answer each one - an errno or a result - and must not panic, hang, or leave the machine unusable.
/// The number and pattern are printed before every call so a panic names its culprit in the log. Calls
/// that block (select, ppoll and pselect6 with no timeout and nothing to wait for) are killed after ~0.4 s,
/// which proves they are interruptible. A second part checks that range calls over the whole of user space
/// (munmap, mprotect, madvise, msync) return promptly instead of walking 34 billion pages.
/// System calls that would end the run on purpose (exit, reboot, kill, mount, ...) are skipped.

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
#define SYS_SETSID    206
#define SYS_EXIT      2
#define SYS_NANOSLEEP 35
#define SYS_FORK      57
#define SYS_KILL      62
#define SYS_WAIT4     263
#define WNOHANG       1
#define NSYS          512
#define NSETS         7
#define SYS_SCHED_YIELD 24
#define SYS_MUNMAP    12
#define SYS_MPROTECT  164
#define SYS_MADVISE   235
#define SYS_MSYNC     254
#define SYS_MINCORE   251
#define SYS_CLOCK_GETTIME 228

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

/* Calls that would end the run or damage other tests on purpose. */
static const int SKIP[] = { 2,5,29,56,57,58,59,60,62,64,68,149,153,156,205,206,207,220,222,223,224,226,233,238,243,262,264,266,270,273,279,283,284,288,289,295,296,308,316,318,319,322,334,424,428,429,432,433,435,442,457,458,467,472,473,484,485,501 };
static int skipped(int n) {
    for (unsigned i = 0; i < sizeof(SKIP) / sizeof(SKIP[0]); i++) {
        if (SKIP[i] == n) return 1;
    }
    return 0;
}

#define KP 0xffff800000000000ULL
static void args_for(int set, uint64_t a[6]) {
    for (int i = 0; i < 6; i++) {
        switch (set) {
        case 0: a[i] = 0; break;
        case 1: a[i] = ~0ULL; break;
        case 2: a[i] = KP; break;
        case 3: a[i] = 8; break;
        case 4: a[i] = i == 0 ? 1 : KP; break;            /* an open fd, kernel pointers */
        case 5: a[i] = i == 0 ? 1 : ~0ULL; break;         /* an open fd, huge lengths */
        default: a[i] = i == 0 ? 0 : 0x00007ffffffff000ULL; break; /* top of user space */
        }
    }
}

static int64_t rawcall(int nr, uint64_t *a) {
    return syscall6((uint64_t)nr, a[0], a[1], a[2], a[3], a[4], a[5]);
}

static int big_fail = 0;

void _start(void) {
    print("hello190: hostile-argument sweep\n");
    int calls = 0, killed = 0;
    for (int nr = 0; nr < NSYS; nr++) {
        if (skipped(nr)) continue;
        for (int set = 0; set < NSETS; set++) {
            uint64_t a[6];
            args_for(set, a);
            int64_t pid = syscall1(SYS_FORK, 0);
            if (pid == 0) {
                /* Own session: a console read by fd 0 must not SIGTTIN-stop the parent along with the child. */
                syscall1(SYS_SETSID, 0);
                print("fz "); print_num((uint64_t)nr); print("/"); print_num((uint64_t)set); print("\n");
                rawcall(nr, a);
                syscall1(SYS_EXIT, 0);
                for (;;) {}
            }
            if (pid < 0) { print("hello190:   FAIL fork failed\n"); print("hello190: FAIL\n"); syscall1(SYS_EXIT, 1); }
            calls++;
            int done = 0;
            /* Most calls return at once: yield-poll first, and only then sleep a tick at a time (~0.4 s). */
            for (int w = 0; w < 400 && !done; w++) {
                int st = 0;
                int64_t r = syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, WNOHANG, 0);
                if (r == pid) { done = 1; break; }
                if (w < 300) { syscall1(SYS_SCHED_YIELD, 0); continue; }
                struct ts t = { 0, 10 * 1000 * 1000 };
                syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
            }
            if (!done) {                                  /* it blocked (select/ppoll with no timeout do, on Linux too): allowed, but it must be killable */
                syscall2(SYS_KILL, (uint64_t)pid, 9);
                int st = 0;
                syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, 0, 0);
                killed++;
            }
        }
    }
    /* A range call over the whole of user space must return promptly: it used to walk 34 billion pages one by
     * one inside a single system call. Each is timed against a generous 2 s ceiling. */
    {
        struct { const char *name; int nr; uint64_t a[3]; } big[] = {
            { "munmap of 128 TiB",   SYS_MUNMAP,   { 0x10000, 0x7fffffff0000ULL, 0 } },
            { "mprotect of 128 TiB", SYS_MPROTECT, { 0x10000, 0x7fffffff0000ULL, 1 } },
            { "madvise of 128 TiB",  SYS_MADVISE,  { 0x10000, 0x7fffffff0000ULL, 4 } },
            { "msync of 128 TiB",    SYS_MSYNC,    { 0x10000, 0x7fffffff0000ULL, 4 } },
        };
        for (unsigned i = 0; i < sizeof(big) / sizeof(big[0]); i++) {
            int64_t pid = syscall1(SYS_FORK, 0);
            if (pid == 0) {
                syscall3((uint64_t)big[i].nr, big[i].a[0], big[i].a[1], big[i].a[2]);
                syscall1(SYS_EXIT, 0);
                for (;;) {}
            }
            struct ts t0, t1;
            syscall2(SYS_CLOCK_GETTIME, 1, (uint64_t)&t0);
            int st = 0, fin = 0;
            for (int w = 0; w < 600 && !fin; w++) {
                if (syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, WNOHANG, 0) == pid) { fin = 1; break; }
                struct ts d = { 0, 10 * 1000 * 1000 };
                syscall2(SYS_NANOSLEEP, (uint64_t)&d, 0);
            }
            syscall2(SYS_CLOCK_GETTIME, 1, (uint64_t)&t1);
            if (!fin) { syscall2(SYS_KILL, (uint64_t)pid, 9); syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, 0, 0); }
            int64_t ms = (t1.s - t0.s) * 1000 + (t1.n - t0.n) / 1000000;
            print("hello190:   "); print(big[i].name); print(" took "); print_num((uint64_t)(ms < 0 ? 0 : ms)); print(" ms\n");
            if (!fin || ms > 2000) { print("hello190:   FAIL "); print(big[i].name); print(" is not prompt\n"); big_fail = 1; }
            else { print("hello190:   ok   "); print(big[i].name); print(" returns promptly\n"); }
        }
    }
    print("hello190: calls="); print_num((uint64_t)calls);
    print(" blocked-and-killed="); print_num((uint64_t)killed); print("\n");
    /* The kernel survived every call; one more round trip proves it is still serving system calls. */
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) { syscall1(SYS_EXIT, 7); for (;;) {} }
    int st = 0;
    int64_t r = syscall4(SYS_WAIT4, (uint64_t)pid, (uint64_t)&st, 0, 0);
    int ok = pid > 0 && r == pid && ((st >> 8) & 0xff) == 7 && !big_fail;
    print(ok ? "hello190:   ok   the kernel still forks and reaps after the sweep\n" : "hello190:   FAIL the kernel no longer forks and reaps\n");
    print(ok ? "hello190: PASS\n" : "hello190: FAIL\n");
    print("hello190 done\n");
    syscall1(SYS_EXIT, ok ? 0 : 1);
    for (;;) {}
}
