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

#define SYS_WRITE  1
#define SYS_OPEN   9
#define SYS_CLOSE  11
#define SYS_MKDIR  123

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_dec(int64_t v) {
    char buf[20];
    int pos = 0;
    if (v < 0) { syscall3(SYS_WRITE, 1, (uint64_t)"-", 1); v = -v; }
    if (v == 0) { syscall3(SYS_WRITE, 1, (uint64_t)"0", 1); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char tmp = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = tmp; }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

void _start(void) {
    print("hello23: mkdir test\n");

    int64_t r = syscall2(SYS_MKDIR, (uint64_t)"testdir", 0x1FF);
    print("hello23: mkdir=");
    print_dec(r);
    print("\n");

    if (r != 0) {
        print("hello23: mkdir failed\n");
        goto done;
    }

    int64_t r2 = syscall2(SYS_MKDIR, (uint64_t)"testdir", 0x1FF);
    print("hello23: mkdir-again=");
    print_dec(r2);
    print(" (idempotent)\n");

    int64_t r3 = syscall2(SYS_MKDIR, (uint64_t)"anotherdir", 0x1FF);
    print("hello23: mkdir2=");
    print_dec(r3);
    print("\n");

    print("hello23: mkdir OK\n");

done:
    print("hello23 done\n");
    syscall1(2, 0);
    for (;;) {}
}
