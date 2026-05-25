/// hello24: ext2 unlink test
///
/// Tests:
///   1. Create a file /unlinktest.txt via open(O_CREAT)
///   2. Write some data to it
///   3. Close it
///   4. Verify it exists by opening it for read
///   5. Close it again
///   6. Unlink it via syscall #111
///   7. Verify it's gone by trying to open it (should fail)

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
#define SYS_UNLINK 111

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
    print("hello24: ext2 unlink test\n");

    // Step 1: Create file (O_WRONLY | O_CREAT = 0x41)
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"unlinktest.txt", 0x41, 0);
    print("hello24: create=");
    print_dec(fd);
    print("\n");

    if (fd < 0) {
        print("hello24: create failed\n");
        print("hello24 done\n");
        syscall1(2, 0);
        for (;;) {}
    }

    // Step 2: Write data
    const char *data = "unlink me!";
    int len = 0;
    while (data[len]) len++;
    int64_t n = syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)data, len);
    print("hello24: write=");
    print_dec(n);
    print("\n");
    syscall1(SYS_CLOSE, (uint64_t)fd);

    // Step 3: Verify exists (open for read)
    fd = syscall3(SYS_OPEN, (uint64_t)"unlinktest.txt", 0, 0);
    print("hello24: verify exists: fd=");
    print_dec(fd);
    print("\n");

    if (fd >= 0) {
        char buf[64];
        int64_t rn = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 63);
        if (rn > 0) {
            buf[rn] = 0;
            print("hello24: content: ");
            syscall3(SYS_WRITE, 1, (uint64_t)buf, rn);
            print("\n");
        }
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    // Step 4: Unlink
    int64_t ret = syscall1(SYS_UNLINK, (uint64_t)"unlinktest.txt");
    print("hello24: unlink=");
    print_dec(ret);
    print("\n");

    // Step 5: Verify gone (open should fail)
    fd = syscall3(SYS_OPEN, (uint64_t)"unlinktest.txt", 0, 0);
    print("hello24: verify gone: fd=");
    print_dec(fd);
    print("\n");

    if (fd < 0) {
        print("hello24: PASS (file deleted)\n");
    } else {
        print("hello24: FAIL (file still exists)\n");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    print("hello24 done\n");
    syscall1(2, 0);
    for (;;) {}
}
