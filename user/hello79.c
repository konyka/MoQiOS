// hello79 - raw fallocate(2) mode boundary acceptance.

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
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx)
                      : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_OPEN 9
#define SYS_CLOSE 11
#define SYS_PIPE 22
#define SYS_FSTAT 110
#define SYS_FALLOCATE 274

#define O_RDONLY 0
#define O_RDWR_CREAT_TRUNC 0x242
#define EBADF 9
#define EINVAL 22
#define EOPNOTSUPP 95
#define EACCES 13

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello79: FAIL ");
        print(name);
        print("\n");
        return 1;
    }
    return 0;
}

static int64_t file_size(int64_t fd, uint8_t *stat_buf) {
    if (syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)stat_buf) != 0) return -1;
    int64_t size = 0;
    for (int i = 0; i < 8; i++) size |= (int64_t)stat_buf[48 + i] << (i * 8);
    return size;
}

__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(SYS_EXIT, (uint64_t)status);
    for (;;) {}
}

void _start(void) {
    int failures = 0;
    uint8_t stat_buf[144];
    print("hello79: start\n");

    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"fallocate79.txt", O_RDWR_CREAT_TRUNC, 0666);
    failures += check(fd >= 0, "open regular file");
    if (fd >= 0) {
        const char data[] = "hello79 fallocate data";
        failures += check(syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)data, sizeof(data) - 1) == (int64_t)(sizeof(data) - 1),
                          "seed regular file");
        int64_t initial_size = file_size(fd, stat_buf);
        failures += check(initial_size == (int64_t)(sizeof(data) - 1), "read initial size");
        failures += check(syscall4(SYS_FALLOCATE, (uint64_t)fd, 0, 0, sizeof(data) - 1) == -EOPNOTSUPP,
                          "mode zero rejects non-ext2 regular file");
        int64_t allocated_size = file_size(fd, stat_buf);
        failures += check(allocated_size == initial_size, "mode zero preserves covered size");
        failures += check(syscall4(SYS_FALLOCATE, (uint64_t)fd, 1, 0, 4096) == -EOPNOTSUPP,
                          "keep size for unsupported mode one");
        failures += check(file_size(fd, stat_buf) == allocated_size, "unsupported mode preserves size");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)fd) == 0, "close regular file");
    }

    failures += check(syscall4(SYS_FALLOCATE, (uint64_t)-1L, 0, 0, 1) == -EBADF, "invalid fd");

    int64_t rofd = syscall3(SYS_OPEN, (uint64_t)"fallocate79.txt", O_RDONLY, 0);
    if (rofd >= 0) {
        int64_t roret = syscall4(SYS_FALLOCATE, (uint64_t)rofd, 0, 0, 1);
        failures += check(roret == -EACCES || roret == -EOPNOTSUPP,
                          "read-only fd cannot fallocate");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)rofd) == 0, "close read-only file");
    }

    int32_t pipe_fds[2] = {-1, -1};
    failures += check(syscall1(SYS_PIPE, (uint64_t)pipe_fds) == 0, "create pipe");
    if (pipe_fds[0] >= 0) {
        int64_t ret = syscall4(SYS_FALLOCATE, (uint64_t)pipe_fds[0], 0, 0, 1);
        failures += check(ret < 0, "pipe unsupported error");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)pipe_fds[0]) == 0, "close pipe read fd");
    }
    if (pipe_fds[1] >= 0) failures += check(syscall1(SYS_CLOSE, (uint64_t)pipe_fds[1]) == 0, "close pipe write fd");

    int64_t devfd = syscall3(SYS_OPEN, (uint64_t)"/dev/null", O_RDONLY, 0);
    failures += check(devfd >= 0, "open device");
    if (devfd >= 0) {
        int64_t ret = syscall4(SYS_FALLOCATE, (uint64_t)devfd, 0, 0, 1);
        failures += check(ret < 0, "device unsupported error");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)devfd) == 0, "close device");
    }

    if (failures == 0) print("hello79: PASS (raw fallocate mode boundary #274)\nhello79 done\n");
    else print("hello79: FAILURES\nhello79 done\n");
    exit_raw(failures != 0);
}
