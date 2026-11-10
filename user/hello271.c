/* hello271: after fork() the child inherits the descriptors its parent opened before the fork, a pipe and a regular file; writes through them
 * reach the parent and the file. (Regression guard: pipe2 fills two 32-bit ints, so the descriptors are read as int32_t.) */
#include <stdint.h>
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"

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
#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_READ 10
#define SYS_CLOSE 11
#define SYS_OPEN 9
#define SYS_PIPE2 250
#define SYS_FORK 57
#define SYS_WAITPID 6
#define SYS_UNLINK 111

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello271:   ok   " : "hello271:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

void _start(void) {
    print("hello271: a fork()ed child inherits its parent's descriptors\n");
    /* pipe created before the fork: the child writes, the parent reads */
    int32_t p[2];
    check(syscall2(SYS_PIPE2, (uint64_t)p, 0) == 0, "pipe2");
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        char c = 'p';
        int64_t w = syscall3(SYS_WRITE, (uint64_t)p[1], (uint64_t)&c, 1);
        syscall1(SYS_EXIT, w == 1 ? 0 : 1);
        for (;;) {}
    }
    char got = 0;
    int64_t r = syscall3(SYS_READ, (uint64_t)p[0], (uint64_t)&got, 1);
    int64_t st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    check(r == 1 && got == 'p', "the child's write through a pipe made before fork() reaches the parent");
    check(st == 0, "and the child's write returned 1, not EBADF");
    syscall1(SYS_CLOSE, (uint64_t)p[0]);
    syscall1(SYS_CLOSE, (uint64_t)p[1]);
    /* file created before the fork: the child writes to the inherited descriptor, the parent reads the file back */
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h271");
    int64_t f = syscall3(SYS_OPEN, (uint64_t)"/tmp/h271", 0x241, 0644);
    check(f >= 0, "create the file");
    int64_t k2 = syscall1(SYS_FORK, 0);
    if (k2 == 0) {
        char c = 'f';
        int64_t w = syscall3(SYS_WRITE, (uint64_t)f, (uint64_t)&c, 1);
        syscall1(SYS_EXIT, w == 1 ? 0 : 1);
        for (;;) {}
    }
    int64_t st2 = 0;
    syscall3(SYS_WAITPID, (uint64_t)k2, (uint64_t)&st2, 0);
    syscall1(SYS_CLOSE, (uint64_t)f);
    int64_t rf = syscall3(SYS_OPEN, (uint64_t)"/tmp/h271", 0, 0);
    char fb = 0;
    int64_t fr = rf >= 0 ? syscall3(SYS_READ, (uint64_t)rf, (uint64_t)&fb, 1) : -1;
    if (rf >= 0) syscall1(SYS_CLOSE, (uint64_t)rf);
    check(st2 == 0 && fr == 1 && fb == 'f', "the child's write through an inherited file descriptor lands in the file");
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h271");
    print(failures == 0 ? "hello271: PASS\n" : "hello271: FAIL\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
