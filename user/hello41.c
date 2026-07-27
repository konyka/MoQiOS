/// hello41: copy_file_range validates fds and restores explicit offsets.

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

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE           1
#define SYS_EXIT            2
#define SYS_OPEN            9
#define SYS_READ            10
#define SYS_CLOSE           11
#define SYS_COPY_FILE_RANGE 184

#define O_WRONLY_CREAT 0x41

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello41: FAIL (");
    print(why);
    print(")\nhello41 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    if (syscall6(SYS_COPY_FILE_RANGE, 64, 0, 1, 0, 1, 0) != -9) fail("out-of-range fd EBADF");
    if (syscall6(SYS_COPY_FILE_RANGE, 1, 0, 1, 0, 1, 0) != -22) fail("special fd EINVAL");

    int64_t src = syscall3(SYS_OPEN, (uint64_t)"/tmp/cfr-src", O_WRONLY_CREAT, 0);
    if (src < 0 || syscall3(SYS_WRITE, (uint64_t)src, (uint64_t)"abcdef", 6) != 6) fail("create source");
    if (syscall1(SYS_CLOSE, (uint64_t)src) != 0) fail("close source writer");
    if (syscall6(SYS_COPY_FILE_RANGE, (uint64_t)src, 0, 1, 0, 1, 0) != -9) fail("closed fd EBADF");

    src = syscall3(SYS_OPEN, (uint64_t)"/tmp/cfr-src", 0, 0);
    int64_t dst = syscall3(SYS_OPEN, (uint64_t)"/tmp/cfr-dst", O_WRONLY_CREAT, 0);
    if (src < 0 || dst < 0) fail("open files");

    uint64_t in_offset = 1;
    uint64_t out_offset = 0;
    if (syscall6(SYS_COPY_FILE_RANGE, (uint64_t)src, (uint64_t)&in_offset,
                 (uint64_t)dst, (uint64_t)&out_offset, 3, 0) != 3) fail("explicit offset copy");
    if (in_offset != 4 || out_offset != 3) fail("explicit offset writeback");

    char source[4] = { 0, 0, 0, 0 };
    if (syscall3(SYS_READ, (uint64_t)src, (uint64_t)source, 3) != 3 ||
        source[0] != 'a' || source[1] != 'b' || source[2] != 'c') fail("input offset rollback");
    if (syscall3(SYS_WRITE, (uint64_t)dst, (uint64_t)"Z", 1) != 1) fail("output offset rollback");

    uint64_t failed_offset = 1;
    int64_t read_only = syscall3(SYS_OPEN, (uint64_t)"test.txt", 0, 0);
    if (read_only < 0) fail("open read-only target");
    if (syscall6(SYS_COPY_FILE_RANGE, (uint64_t)src, (uint64_t)&failed_offset,
                 (uint64_t)read_only, 0, 1, 0) != -1) fail("write failure result");
    if (syscall3(SYS_READ, (uint64_t)src, (uint64_t)source, 3) != 3 ||
        source[0] != 'd' || source[1] != 'e' || source[2] != 'f') fail("write failure rollback");
    syscall1(SYS_CLOSE, (uint64_t)read_only);

    syscall1(SYS_CLOSE, (uint64_t)src);
    syscall1(SYS_CLOSE, (uint64_t)dst);
    dst = syscall3(SYS_OPEN, (uint64_t)"/tmp/cfr-dst", 0, 0);
    char copied[4] = { 0, 0, 0, 0 };
    if (dst < 0 || syscall3(SYS_READ, (uint64_t)dst, (uint64_t)copied, 3) != 3 ||
        copied[0] != 'Z' || copied[1] != 'c' || copied[2] != 'd') fail("copied data");

    print("hello41: PASS\nhello41 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
