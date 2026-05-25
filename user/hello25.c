/// hello25: ext2 multi-level path test
///
/// Tests file operations in subdirectories:
///   1. Create a file in /testdir/subfile.txt (testdir pre-created by hello23)
///   2. Write data to it
///   3. Read it back and verify
///   4. Unlink it
///   5. Verify it's gone

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
    print("hello25: ext2 multi-level path test\n");

    // Step 1: Create file in subdirectory (O_WRONLY | O_CREAT = 0x41)
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"testdir/subfile.txt", 0x41, 0);
    print("hello25: create testdir/subfile.txt=");
    print_dec(fd);
    print("\n");

    if (fd < 0) {
        print("hello25: create failed (ext2 not active or testdir missing?)\n");
        print("hello25 done\n");
        syscall1(2, 0);
        for (;;) {}
    }

    // Step 2: Write data
    const char *data = "hello from subdir!";
    int len = 0;
    while (data[len]) len++;
    int64_t n = syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)data, len);
    print("hello25: write=");
    print_dec(n);
    print("\n");
    syscall1(SYS_CLOSE, (uint64_t)fd);

    // Step 3: Read back
    fd = syscall3(SYS_OPEN, (uint64_t)"testdir/subfile.txt", 0, 0);
    print("hello25: reopen=");
    print_dec(fd);
    print("\n");

    if (fd >= 0) {
        char buf[64];
        int64_t rn = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 63);
        if (rn > 0) {
            buf[rn] = 0;
            print("hello25: content: ");
            syscall3(SYS_WRITE, 1, (uint64_t)buf, rn);
            print("\n");
        }
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    // Step 4: Unlink
    int64_t ret = syscall1(SYS_UNLINK, (uint64_t)"testdir/subfile.txt");
    print("hello25: unlink=");
    print_dec(ret);
    print("\n");

    // Step 5: Verify gone
    fd = syscall3(SYS_OPEN, (uint64_t)"testdir/subfile.txt", 0, 0);
    print("hello25: verify gone: fd=");
    print_dec(fd);
    print("\n");

    if (fd < 0) {
        print("hello25: PASS (subdirectory file deleted)\n");
    } else {
        print("hello25: FAIL (file still exists)\n");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    print("hello25 done\n");
    syscall1(2, 0);
    for (;;) {}
}
