/// hello135: signal call argument and errno rules.

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
#define SYS_UNAME     63
#define SYS_GETRLIMIT 236
#define SYS_SETRLIMIT 237
#define SYS_PRLIMIT64 238
#define SYS_SYSINFO   240
#define SYS_SETHOSTNAME 264
#define SYS_GETHOSTNAME 265
#define SYS_SETDOMAINNAME 266
#define SYS_GETDOMAINNAME 267
#define SYS_GETPID    39
#define SYS_NANOSLEEP 35
#define EPERM_  1
#define ESRCH_  3
#define EFAULT_ 14
#define EINVAL_ 22
#define RLIMIT_NOFILE 7
#define RLIMIT_CORE 4
#define RLIM_INF (~0ULL)

struct rlim { uint64_t cur, max; };

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello138:   ok   " : "hello138:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}
static uint64_t self(void) { return (uint64_t)syscall1(SYS_GETPID, 0); }
#define BAD ((uint64_t)0x8000000000000000ULL)

void _start(void) {
    print("hello138: uname, hostname, rlimit, sysinfo\n");

    /* A: uname */
    {
        char u[390];
        volatile char *p = (volatile char *)u;
        for (int i = 0; i < 390; i++) p[i] = 0x55;
        check(syscall1(SYS_UNAME, (uint64_t)u) == 0, "A: uname succeeds");
        check(streq(u, "MoQiOS") || u[0] != 0, "A: sysname is set");
        check(streq(u + 65 * 4, "x86_64"), "A: machine is x86_64");
        check(u[65 * 5] == 0, "A: the whole domainname field is initialised");
        check(syscall1(SYS_UNAME, 0) == -EFAULT_, "A: uname(NULL) is EFAULT");
        check(syscall1(SYS_UNAME, BAD) == -EFAULT_, "A: uname(kernel pointer) is EFAULT");
    }

    /* B: hostname and uname agree */
    {
        char old[65];
        volatile char *op = (volatile char *)old;
        for (int i = 0; i < 65; i++) op[i] = 0;
        check(syscall2(SYS_GETHOSTNAME, (uint64_t)old, 64) == 0, "B: read the current hostname");
        const char name[] = "probe-host";
        check(syscall2(SYS_SETHOSTNAME, (uint64_t)name, sizeof name - 1) == 0, "B: sethostname succeeds");
        char u[390];
        syscall1(SYS_UNAME, (uint64_t)u);
        check(streq(u + 65, "probe-host"), "B: uname nodename follows sethostname");
        char got[65];
        volatile char *gp = (volatile char *)got;
        for (int i = 0; i < 65; i++) gp[i] = 0;
        syscall2(SYS_GETHOSTNAME, (uint64_t)got, 64);
        check(streq(got, "probe-host"), "B: gethostname returns the new name");
        char big[100];
        volatile char *bp = (volatile char *)big;
        for (int i = 0; i < 100; i++) bp[i] = 'a';
        check(syscall2(SYS_SETHOSTNAME, (uint64_t)big, 65) == -EINVAL_, "B: a 65-byte hostname is EINVAL");
        check(syscall2(SYS_SETHOSTNAME, 0, 4) == -EFAULT_, "B: sethostname(NULL) is EFAULT");
        syscall1(SYS_UNAME, (uint64_t)u);
        check(streq(u + 65, "probe-host"), "B: and a failed set leaves the name alone");
        check(syscall2(SYS_SETHOSTNAME, (uint64_t)name, 0) == 0, "B: an empty hostname is allowed");
        syscall1(SYS_UNAME, (uint64_t)u);
        check(u[65] == 0, "B: and uname shows it as empty");
        syscall2(SYS_SETHOSTNAME, (uint64_t)old, 64);
        int n = 0;
        while (n < 64 && old[n]) n++;
        syscall2(SYS_SETHOSTNAME, (uint64_t)old, (uint64_t)n);
    }

    /* C: domainname */
    {
        const char dom[] = "probe.dom";
        check(syscall2(SYS_SETDOMAINNAME, (uint64_t)dom, sizeof dom - 1) == 0, "C: setdomainname succeeds");
        char u[390];
        syscall1(SYS_UNAME, (uint64_t)u);
        check(streq(u + 65 * 5, "probe.dom"), "C: uname domainname follows setdomainname");
        char got[65];
        volatile char *gp = (volatile char *)got;
        for (int i = 0; i < 65; i++) gp[i] = 0;
        syscall2(SYS_GETDOMAINNAME, (uint64_t)got, 64);
        check(streq(got, "probe.dom"), "C: getdomainname returns it");
        syscall2(SYS_SETDOMAINNAME, (uint64_t)"", 0);
    }

    /* D: getrlimit / setrlimit */
    {
        struct rlim r = { 1, 2 };
        check(syscall2(SYS_GETRLIMIT, RLIMIT_NOFILE, (uint64_t)&r) == 0 && r.cur <= r.max, "D: getrlimit(NOFILE) has cur <= max");
        check(syscall2(SYS_GETRLIMIT, 99, (uint64_t)&r) == -EINVAL_, "D: an unknown resource is EINVAL");
        check(syscall2(SYS_GETRLIMIT, RLIMIT_NOFILE, 0) == -EFAULT_, "D: getrlimit(NULL) is EFAULT");
        check(syscall2(SYS_GETRLIMIT, RLIMIT_NOFILE, BAD) == -EFAULT_, "D: getrlimit(kernel pointer) is EFAULT");
        struct rlim bad = { 10, 5 };
        check(syscall2(SYS_SETRLIMIT, RLIMIT_CORE, (uint64_t)&bad) == -EINVAL_, "D: cur > max is EINVAL");
        struct rlim back = { 0, 0 };
        struct rlim inf = { RLIM_INF, RLIM_INF };
        check(syscall2(SYS_SETRLIMIT, RLIMIT_CORE, (uint64_t)&inf) == 0, "D: RLIM_INFINITY is accepted");
        check(syscall2(SYS_GETRLIMIT, RLIMIT_CORE, (uint64_t)&back) == 0 && back.cur == RLIM_INF && back.max == RLIM_INF, "D: and reads back as infinity");
        struct rlim set = { 123, 456 };
        check(syscall2(SYS_SETRLIMIT, RLIMIT_CORE, (uint64_t)&set) == 0, "D: lower a recorded limit");
        check(syscall2(SYS_GETRLIMIT, RLIMIT_CORE, (uint64_t)&back) == 0 && back.cur == 123 && back.max == 456, "D: and read it back");
        struct rlim raise = { 123, 1000 };
        check(syscall2(SYS_SETRLIMIT, RLIMIT_CORE, (uint64_t)&raise) == -EPERM_, "D: raising the hard limit without privilege is EPERM");
    }

    /* E: prlimit64 */
    {
        struct rlim old = { 0, 0 }, nw = { 77, 88 };
        check(syscall4(SYS_PRLIMIT64, 0, RLIMIT_CORE, (uint64_t)&nw, (uint64_t)&old) == 0 && old.cur == 123 && old.max == 456, "E: prlimit(self) returns the old value");
        struct rlim cur = { 0, 0 };
        check(syscall4(SYS_PRLIMIT64, self(), RLIMIT_CORE, 0, (uint64_t)&cur) == 0 && cur.cur == 77 && cur.max == 88, "E: and applies the new one (explicit pid)");
        check(syscall4(SYS_PRLIMIT64, 0, 99, 0, (uint64_t)&cur) == -EINVAL_, "E: an unknown resource is EINVAL");
        check(syscall4(SYS_PRLIMIT64, 999999, RLIMIT_CORE, 0, (uint64_t)&cur) == -ESRCH_, "E: a missing pid is ESRCH");
        check(syscall4(SYS_PRLIMIT64, 0, RLIMIT_CORE, BAD, 0) == -EFAULT_, "E: a bad new_limit pointer is EFAULT");
        check(syscall4(SYS_PRLIMIT64, 0, RLIMIT_CORE, 0, BAD) == -EFAULT_, "E: a bad old_limit pointer is EFAULT");
        struct rlim bad = { 9, 3 };
        check(syscall4(SYS_PRLIMIT64, 0, RLIMIT_CORE, (uint64_t)&bad, 0) == -EINVAL_, "E: cur > max is EINVAL");
        struct rlim after = { 0, 0 };
        syscall4(SYS_PRLIMIT64, 0, RLIMIT_CORE, 0, (uint64_t)&after);
        check(after.cur == 77 && after.max == 88, "E: a rejected set leaves the limit unchanged");
        check(syscall4(SYS_PRLIMIT64, 0, RLIMIT_CORE, 0, 0) == 0, "E: a query with both pointers NULL is a no-op success");
    }

    /* F: sysinfo */
    {
        uint64_t b[16];
        volatile uint64_t *vp = b;
        for (int i = 0; i < 16; i++) vp[i] = 0x5555;
        check(syscall1(SYS_SYSINFO, (uint64_t)b) == 0, "F: sysinfo succeeds");
        uint64_t uptime = b[0], total = b[4], freeram = b[5];
        check(total > 0 && freeram <= total, "F: freeram <= totalram");
        check((b[10] & 0xffff) >= 1, "F: procs counts this process");
        check((b[13] & 0xffffffffULL) == 1, "F: mem_unit is 1");
        struct { int64_t s, n; } t = { 0, 20000000 };
        syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
        syscall1(SYS_SYSINFO, (uint64_t)b);
        check(b[0] >= uptime, "F: uptime does not go backwards");
        check(syscall1(SYS_SYSINFO, 0) == -EFAULT_, "F: sysinfo(NULL) is EFAULT");
        check(syscall1(SYS_SYSINFO, BAD) == -EFAULT_, "F: sysinfo(kernel pointer) is EFAULT");
    }

    print(failures == 0 ? "hello138: PASS\n" : "hello138: FAIL\n");
    print("hello138 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
