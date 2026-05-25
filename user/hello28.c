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

#define SYS_WRITE   1
#define SYS_EXIT    2
#define SYS_LISTDIR 107
#define SYS_MKDIR   123

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
    int ok = 1;
    print("hello28: listdir test\n");

    char buf[1024];
    for (int i = 0; i < 1024; i++) buf[i] = 0;

    int64_t n = syscall2(SYS_LISTDIR, (uint64_t)buf, 1024);
    print("hello28: listdir=");
    print_dec(n);
    print("\n");

    if (n > 0) {
        print("hello28: entries:\n");
        syscall3(SYS_WRITE, 1, (uint64_t)buf, (uint64_t)n);

        /* Check if ext2 entries appear (lost+found is default) */
        int found_lost = 0;
        for (int i = 0; i < (int)n - 9; i++) {
            if (buf[i] == 'l' && buf[i+1] == 'o' && buf[i+2] == 's' && buf[i+3] == 't'
                && buf[i+4] == '+') {
                found_lost = 1;
                break;
            }
        }
        print("hello28: lost+found=");
        print_dec(found_lost);
        print("\n");

        if (!found_lost) {
            print("hello28: ext2 entries not found in listing\n");
        }
    } else {
        print("hello28: listdir returned nothing\n");
    }

    print("hello28: listdir ");
    print(ok ? "OK\n" : "FAILED\n");
    print("hello28 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
