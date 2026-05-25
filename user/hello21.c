/// hello21: ext2 write test
///
/// Tests ext2 write support:
///   - Create a new file on ext2 (/writetest.txt)
///   - Write data to it
///   - Read it back
///   - Verify the contents match

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
    print("hello21: ext2 write test\n");

    // Try to create a new file (O_WRONLY | O_CREAT = 0x01 | 0x40 = 0x41)
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"writetest.txt", 0x41, 0);
    print("hello21: create=");
    print_dec(fd);
    print("\n");

    if (fd < 0) {
        print("hello21: create failed (ext2 not active?)\n");
        print("hello21 done\n");
        syscall1(2, 0);
        for (;;) {}
    }

    // Write test data
    const char *data = "Hello from ext2 write!";
    int len = 0;
    while (data[len]) len++;
    int64_t n = syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)data, len);
    print("hello21: write=");
    print_dec(n);
    print("\n");

    // Close the file
    syscall1(SYS_CLOSE, (uint64_t)fd);

    // Re-open and read back
    fd = syscall3(SYS_OPEN, (uint64_t)"writetest.txt", 0, 0);
    print("hello21: reopen=");
    print_dec(fd);
    print("\n");

    if (fd >= 0) {
        char buf[256];
        int64_t rn = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 255);
        if (rn > 0) {
            buf[rn] = 0;
            print("hello21: read back: ");
            syscall3(SYS_WRITE, 1, (uint64_t)buf, rn);
            print("\n");

            // Verify
            int match = 1;
            if (rn != len) match = 0;
            else {
                for (int i = 0; i < len; i++) {
                    if (buf[i] != data[i]) { match = 0; break; }
                }
            }
            print("hello21: verify=");
            print_dec(match ? 1 : 0);
            print("\n");
        }
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    print("hello21 done\n");
    syscall1(2, 0);
    for (;;) {}
}
