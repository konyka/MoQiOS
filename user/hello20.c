/// hello20: ext2 filesystem test
///
/// Tests ext2 read-only filesystem:
///   - Open a file from the ext2 disk (/test.txt)
///   - Read its contents
///   - Print the contents
///   - Close the file

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_OPEN  9
#define SYS_READ  10
#define SYS_CLOSE 11

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
    print("hello20: ext2 test\n");

    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"ext2test.txt", 0, 0);
    print("hello20: open=");
    print_dec(fd);
    print("\n");

    if (fd >= 0) {
        char buf[256];
        int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 255);
        if (n > 0) {
            syscall3(SYS_WRITE, 1, (uint64_t)buf, n);
        }
    }

    print("hello20 done\n");
    syscall1(2, 0);
    for (;;) {}
}
