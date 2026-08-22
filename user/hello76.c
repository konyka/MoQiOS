// hello76 - raw sync_file_range(2) bounded-range acceptance.

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
#define SYS_SYNC_FILE_RANGE 290

#define O_RDONLY 0
#define O_RDWR_CREAT_TRUNC 0x242
#define EINVAL 22
#define EBADF 9

#define SYNC_FILE_RANGE_WAIT_BEFORE 1
#define SYNC_FILE_RANGE_WRITE 2
#define SYNC_FILE_RANGE_WAIT_AFTER 4

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello76: FAIL ");
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
    print("hello76: start\n");

    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"sync_file_range.txt", O_RDWR_CREAT_TRUNC, 0666);
    failures += check(fd >= 0, "open regular ext2 file");
    if (fd >= 0) {
        const char data[] = "sync-file-range-bounded-data";
        const uint64_t flags = SYNC_FILE_RANGE_WAIT_BEFORE | SYNC_FILE_RANGE_WRITE | SYNC_FILE_RANGE_WAIT_AFTER;
        failures += check(syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)data, sizeof(data) - 1) == (int64_t)(sizeof(data) - 1),
                          "write regular file");
        failures += check(syscall4(SYS_SYNC_FILE_RANGE, (uint64_t)fd, 0, sizeof(data) - 1, flags) == 0,
                          "valid regular file range");
        failures += check(syscall4(SYS_SYNC_FILE_RANGE, (uint64_t)fd, sizeof(data), 0, flags) == 0,
                          "zero length bounded no-op");
        failures += check(syscall4(SYS_SYNC_FILE_RANGE, (uint64_t)fd, 0, 1, 8) == -EINVAL,
                          "unknown flags");
        failures += check(syscall4(SYS_SYNC_FILE_RANGE, (uint64_t)fd, (uint64_t)-4L, 8, flags) == -EINVAL,
                          "offset and nbytes overflow");
        failures += check(syscall4(SYS_SYNC_FILE_RANGE, (uint64_t)fd, (uint64_t)-1L, 0, flags) == -EINVAL,
                          "negative offset is invalid even for empty range");
        failures += check(syscall4(SYS_SYNC_FILE_RANGE, (uint64_t)-1L, 0, 1, flags) == -EBADF,
                          "invalid fd");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)fd) == 0, "close regular file");
    }

    int32_t pipe_fds[2] = {-1, -1};
    failures += check(syscall1(SYS_PIPE, (uint64_t)pipe_fds) == 0, "create pipe");
    if (pipe_fds[0] >= 0) {
        failures += check(syscall4(SYS_SYNC_FILE_RANGE, (uint64_t)pipe_fds[0], 0, 1, 0) == -EINVAL,
                          "pipe unsupported error");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)pipe_fds[0]) == 0, "close pipe read fd");
    }
    if (pipe_fds[1] >= 0) failures += check(syscall1(SYS_CLOSE, (uint64_t)pipe_fds[1]) == 0, "close pipe write fd");

    int64_t devfd = syscall3(SYS_OPEN, (uint64_t)"/dev/null", O_RDONLY, 0);
    failures += check(devfd >= 0, "open device");
    if (devfd >= 0) {
        failures += check(syscall4(SYS_SYNC_FILE_RANGE, (uint64_t)devfd, 0, 1, 0) == -EINVAL,
                          "device unsupported error");
        failures += check(syscall1(SYS_CLOSE, (uint64_t)devfd) == 0, "close device");
    }

    if (failures == 0) print("hello76: PASS (bounded sync_file_range #290)\nhello76 done\n");
    else print("hello76: FAILURES\nhello76 done\n");
    exit_raw(failures != 0);
}
