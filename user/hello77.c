// hello77 - raw readahead(2) bounded ext2/FAT32 acceptance.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_OPEN 9
#define SYS_WRITE 1
#define SYS_READ 10
#define SYS_CLOSE 11
#define SYS_PIPE 22
#define SYS_READAHEAD 291

#define EINVAL 22
#define EBADF 9

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello77: FAIL ");
        print(name);
        print("\n");
        return 1;
    }
    return 0;
}

__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(SYS_EXIT, (uint64_t)status);
    for (;;) {}
}

void _start(void) {
    int failures = 0;
    char buf[8];
    print("hello77: start\n");

    const char data[] = "Hello from readahead";
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"readahead77.txt", 0x41, 0);
    failures += check(fd >= 0, "create regular ext2/FAT32 file");
    if (fd >= 0) {
        failures += check(syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)data, sizeof(data) - 1) == (int64_t)(sizeof(data) - 1),
                          "seed regular ext2/FAT32 file");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)fd) == 0, "close seeded file");
        fd = syscall3(SYS_OPEN, (uint64_t)"readahead77.txt", 0, 0);
        failures += check(fd >= 0, "reopen regular ext2/FAT32 file");
    }
    if (fd >= 0) {
        failures += check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 5) == 5,
                          "initial read");
        failures += check(buf[0] == 'H' && buf[1] == 'e' && buf[2] == 'l' && buf[3] == 'l' && buf[4] == 'o',
                          "initial contents");
        failures += check(syscall3(SYS_READAHEAD, (uint64_t)fd, 0, 1) == 0,
                          "valid regular ext2/FAT32 prefetch");
        failures += check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 5) == 5,
                          "read after prefetch");
        failures += check(buf[0] == ' ' && buf[1] == 'f' && buf[2] == 'r' && buf[3] == 'o' && buf[4] == 'm',
                          "fd offset unchanged");
        failures += check(syscall3(SYS_READAHEAD, (uint64_t)fd, 0, 0) == 0,
                          "zero count");
        failures += check(syscall3(SYS_READAHEAD, (uint64_t)-1L, 0, 1) == -EBADF,
                          "invalid fd");
        failures += check(syscall3(SYS_READAHEAD, (uint64_t)fd, (uint64_t)-1L, 1) == -EINVAL,
                          "offset overflow");
        failures += check(syscall3(SYS_READAHEAD, (uint64_t)fd, (uint64_t)-1L, 0) == -EINVAL,
                          "negative offset is invalid for empty range");
        failures += check(syscall3(SYS_READAHEAD, (uint64_t)fd, 0, 32 * 4096 + 1) == -EINVAL,
                          "over 32 page cap");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)fd) == 0, "close regular file");
    }

    int32_t pipe_fds[2] = {-1, -1};
    failures += check(syscall1(SYS_PIPE, (uint64_t)pipe_fds) == 0, "create pipe");
    if (pipe_fds[0] >= 0) {
        failures += check(syscall3(SYS_READAHEAD, (uint64_t)pipe_fds[0], 0, 1) == -EINVAL,
                          "pipe unsupported error");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)pipe_fds[0]) == 0, "close pipe read fd");
    }
    if (pipe_fds[1] >= 0) failures += check(syscall1(SYS_CLOSE, (uint64_t)pipe_fds[1]) == 0, "close pipe write fd");

    int64_t devfd = syscall3(SYS_OPEN, (uint64_t)"/dev/null", 0, 0);
    failures += check(devfd >= 0, "open device");
    if (devfd >= 0) {
        failures += check(syscall3(SYS_READAHEAD, (uint64_t)devfd, 0, 1) == -EINVAL,
                          "device unsupported error");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)devfd) == 0, "close device");
    }

    if (failures == 0) print("hello77: PASS (bounded ext2 readahead #291)\nhello77 done\n");
    else print("hello77: FAILURES\nhello77 done\n");
    exit_raw(failures != 0);
}
