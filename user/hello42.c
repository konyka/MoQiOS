/// hello42: pread64/pwrite64 validate fd before access and don't mutate shared offset.

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

static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE  1
#define SYS_EXIT   2
#define SYS_OPEN   9
#define SYS_READ   10
#define SYS_CLOSE  11
#define SYS_PREAD  17
#define SYS_PWRITE 18

#define O_WRONLY_CREAT 0x41

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello42: FAIL (");
    print(why);
    print(")\nhello42 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    char buf[16];

    // Test 1: pread/pwrite validate fd before indexing fds[]
    if (syscall4(SYS_PREAD, 64, (uint64_t)buf, 1, 0) != -9) fail("pread OOB fd");
    if (syscall4(SYS_PWRITE, 64, (uint64_t)buf, 1, 0) != -9) fail("pwrite OOB fd");

    // Test 2: pread/pwrite return EBADF for closed fd
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/ptest", O_WRONLY_CREAT, 0666);
    if (fd < 0) fail("open file");
    if (syscall1(SYS_CLOSE, (uint64_t)fd) != 0) fail("close file");
    int64_t ret = syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)buf, 1, 0);
    if (ret != -9 && ret != -1)
        fail("pread closed fd");
    ret = syscall4(SYS_PWRITE, (uint64_t)fd, (uint64_t)buf, 1, 0);
    if (ret != -9 && ret != -1)
        fail("pwrite closed fd");

    // Test 3: pread/pwrite return ESPIPE for stdin/stdout/stderr
    if (syscall4(SYS_PREAD, 0, (uint64_t)buf, 1, 0) != -29) fail("pread stdin ESPIPE");
    if (syscall4(SYS_PWRITE, 1, (uint64_t)"x", 1, 0) != -29) fail("pwrite stdout ESPIPE");

    // Test 4: pread/pwrite don't mutate shared offset
    fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/ptest", O_WRONLY_CREAT, 0666);
    if (fd < 0) fail("reopen file");
    if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"0123456789", 10) != 10) fail("write data");
    if (syscall1(SYS_CLOSE, (uint64_t)fd) != 0) fail("close writer");

    fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/ptest", 0, 0);
    if (fd < 0) fail("open for read");

    // Read first 2 bytes normally (offset=0 -> 2)
    if (syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 2) != 2) fail("read initial");
    if (buf[0] != '0' || buf[1] != '1') fail("read initial content");

    // pread at offset 5 should NOT change the shared offset
    if (syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)buf, 3, 5) != 3) fail("pread at 5");
    if (buf[0] != '5' || buf[1] != '6' || buf[2] != '7') fail("pread content");

    // Next normal read should continue from offset 2, not 5 or 8
    if (syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 2) != 2) fail("read after pread");
    if (buf[0] != '2' || buf[1] != '3') fail("offset preserved");

    // pwrite at offset 7 should NOT change the shared offset
    if (syscall4(SYS_PWRITE, (uint64_t)fd, (uint64_t)"XY", 2, 7) != -9) fail("pwrite readonly fd");

    if (syscall1(SYS_CLOSE, (uint64_t)fd) != 0) fail("close reader");

    // Test 5: pwrite doesn't mutate shared offset on writable fd
    fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/ptest2", O_WRONLY_CREAT, 0666);
    if (fd < 0) fail("open ptest2");
    if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"abcd", 4) != 4) fail("write ptest2");

    // pwrite at offset 1 shouldn't move the current offset (4)
    if (syscall4(SYS_PWRITE, (uint64_t)fd, (uint64_t)"XY", 2, 1) != 2) fail("pwrite at 1");

    // Next write should append at offset 4, not 1 or 3
    if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"ef", 2) != 2) fail("write after pwrite");

    if (syscall1(SYS_CLOSE, (uint64_t)fd) != 0) fail("close ptest2");

    // Verify final content: "aXYdef" (pwrite replaced 'bc' with 'XY', write appended 'ef')
    fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/ptest2", 0, 0);
    if (fd < 0) fail("open ptest2 verify");
    if (syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 6) != 6) fail("read ptest2 verify");
    if (buf[0] != 'a' || buf[1] != 'X' || buf[2] != 'Y' || buf[3] != 'd' || buf[4] != 'e' || buf[5] != 'f')
        fail("ptest2 final content");
    if (syscall1(SYS_CLOSE, (uint64_t)fd) != 0) fail("close verify");

    print("hello42: PASS\nhello42 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
