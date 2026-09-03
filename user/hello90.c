// hello90 - raw sendfile/splice offsets, FIFO, and error acceptance.
#include <stdint.h>

static inline int64_t syscall1(uint64_t n, uint64_t a) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall3(uint64_t n, uint64_t a, uint64_t b, uint64_t c) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "r"(x) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall4(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    register uint64_t y __asm__("r10") = d;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "r"(x), "r"(y) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall6(uint64_t n, uint64_t a, uint64_t b, uint64_t c,
                               uint64_t d, uint64_t e, uint64_t f) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    register uint64_t y __asm__("r10") = d;
    register uint64_t z __asm__("r8") = e;
    register uint64_t w __asm__("r9") = f;
    __asm__ volatile ("syscall" : "=a"(r)
                      : "a"(n), "D"(a), "S"(b), "r"(x), "r"(y), "r"(z), "r"(w)
                      : "rcx", "r11", "memory");
    return r;
}

#define SYS_WRITE 1
#define SYS_OPEN 9
#define SYS_READ 10
#define SYS_CLOSE 11
#define SYS_UNLINK 111
#define SYS_PIPE 22
#define SYS_LSEEK 197
#define SYS_FSYNC 74
#define SYS_SENDFILE 144
#define SYS_SPLICE 145
#define SYS_EXIT 2

#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 64
#define O_TRUNC 512
#define SEEK_SET 0
#define SEEK_CUR 1
#define EBADF 9
#define EINVAL 22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello90: FAIL ");
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

static int64_t open_raw(const char *path, uint64_t flags) {
    return syscall3(SYS_OPEN, (uint64_t)path, flags, 0666);
}

static int write_all(int64_t fd, const char *buf, uint64_t len) {
    uint64_t done = 0;
    while (done < len) {
        int64_t n = syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)(buf + done), len - done);
        if (n <= 0) return 0;
        done += (uint64_t)n;
    }
    return 1;
}

static int read_exact(int64_t fd, char *buf, uint64_t len) {
    uint64_t done = 0;
    while (done < len) {
        int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)(buf + done), len - done);
        if (n <= 0) return 0;
        done += (uint64_t)n;
    }
    return 1;
}

static int same(const char *a, const char *b, uint64_t len) {
    for (uint64_t i = 0; i < len; i++) if (a[i] != b[i]) return 0;
    return 1;
}

void _start(void) {
    // Relative paths resolve on the writable FAT32/ext2 disk fixture, unlike
    // /tmp, which is tmpfs and unsupported by sendfile/splice.
    static const char source_path[] = "hello90-source";
    static const char target_path[] = "hello90-target";
    static const char source[] = "0123456789abcdef";
    static const char target[] = "................";
    char out[16];
    int failures = 0;
    int64_t source_fd = -1, target_fd = -1;
    int32_t p[2] = {-1, -1};
    int32_t q[2] = {-1, -1};
    int64_t offset;

    print("hello90: start\n");
    source_fd = open_raw(source_path, O_RDWR | O_CREAT | O_TRUNC);
    target_fd = open_raw(target_path, O_RDWR | O_CREAT | O_TRUNC);
    failures += check(source_fd >= 0 && target_fd >= 0, "open disk fixture files");
    if (source_fd >= 0 && target_fd >= 0) {
        failures += check(write_all(source_fd, source, sizeof(source) - 1), "write source");
        failures += check(write_all(target_fd, target, sizeof(target) - 1), "write target");
        // sendfile/splice read the FAT32 backing store, not its dirty writeback cache.
        failures += check(syscall1(SYS_FSYNC, source_fd) == 0 && syscall1(SYS_FSYNC, target_fd) == 0,
                          "flush fixture files");
        failures += check(syscall3(SYS_LSEEK, source_fd, 0, SEEK_SET) == 0 &&
                          syscall3(SYS_LSEEK, target_fd, 0, SEEK_SET) == 0, "rewind files");
    }

    failures += check(syscall1(SYS_PIPE, (uint64_t)p) == 0, "create sendfile pipe");
    offset = 2;
    failures += check(syscall4(SYS_SENDFILE, p[1], source_fd, (uint64_t)&offset, 5) == 5 && offset == 7 &&
                      syscall3(SYS_LSEEK, source_fd, 0, SEEK_CUR) == 0, "sendfile explicit offset");
    failures += check(read_exact(p[0], out, 5) && same(out, "23456", 5), "sendfile bytes");
    syscall1(SYS_CLOSE, (uint64_t)p[0]); syscall1(SYS_CLOSE, (uint64_t)p[1]); p[0] = p[1] = -1;

    failures += check(syscall1(SYS_PIPE, (uint64_t)p) == 0, "create file splice pipe");
    offset = 1;
    failures += check(syscall6(SYS_SPLICE, source_fd, (uint64_t)&offset, p[1], 0, 4, 0) == 4 && offset == 5 &&
                      syscall3(SYS_LSEEK, source_fd, 0, SEEK_CUR) == 0, "splice file input offset");
    failures += check(read_exact(p[0], out, 4) && same(out, "1234", 4), "splice file bytes");
    syscall1(SYS_CLOSE, (uint64_t)p[0]); syscall1(SYS_CLOSE, (uint64_t)p[1]); p[0] = p[1] = -1;

    failures += check(syscall1(SYS_PIPE, (uint64_t)p) == 0 && syscall1(SYS_PIPE, (uint64_t)q) == 0,
                      "create FIFO pipes");
    failures += check(write_all(p[1], "FIFO", 4) && write_all(p[1], "-90", 3), "write FIFO input");
    failures += check(syscall6(SYS_SPLICE, p[0], 0, q[1], 0, 7, 0) == 7, "splice pipe to pipe");
    failures += check(read_exact(q[0], out, 7) && same(out, "FIFO-90", 7), "splice FIFO bytes");
    syscall1(SYS_CLOSE, (uint64_t)p[0]); syscall1(SYS_CLOSE, (uint64_t)p[1]);
    syscall1(SYS_CLOSE, (uint64_t)q[0]); syscall1(SYS_CLOSE, (uint64_t)q[1]); p[0] = p[1] = q[0] = q[1] = -1;

    failures += check(syscall1(SYS_PIPE, (uint64_t)p) == 0, "create output pipe");
    failures += check(write_all(p[1], "XYZ", 3), "write output input");
    offset = 3;
    failures += check(syscall6(SYS_SPLICE, p[0], 0, target_fd, (uint64_t)&offset, 3, 0) == 3 && offset == 6 &&
                      syscall3(SYS_LSEEK, target_fd, 0, SEEK_CUR) == 0, "splice output offset");
    failures += check(syscall1(SYS_FSYNC, target_fd) == 0, "flush splice output");
    syscall3(SYS_LSEEK, target_fd, 0, SEEK_SET);
    failures += check(read_exact(target_fd, out, 16) && same(out, "...XYZ..........", 16), "splice output bytes");
    syscall1(SYS_CLOSE, (uint64_t)p[0]); syscall1(SYS_CLOSE, (uint64_t)p[1]); p[0] = p[1] = -1;

    failures += check(syscall4(SYS_SENDFILE, 999, source_fd, 0, 1) == -EBADF, "sendfile invalid fd");
    failures += check(syscall6(SYS_SPLICE, 999, 0, target_fd, 0, 1, 0) == -EBADF, "splice invalid fd");
    failures += check(syscall1(SYS_PIPE, (uint64_t)p) == 0, "create error pipe");
    offset = 0;
    failures += check(syscall6(SYS_SPLICE, p[0], (uint64_t)&offset, p[1], 0, 1, 0) == -EINVAL,
                      "splice offset on pipe");
    failures += check(syscall6(SYS_SPLICE, p[0], 0, p[1], 0, 1, 0x80000000ULL) == -EINVAL,
                      "splice invalid flags");
    syscall1(SYS_CLOSE, (uint64_t)p[0]); syscall1(SYS_CLOSE, (uint64_t)p[1]); p[0] = p[1] = -1;

    int64_t unreadable = open_raw(source_path, O_WRONLY);
    failures += check(unreadable >= 0, "open unreadable source");
    if (unreadable >= 0) {
        failures += check(syscall1(SYS_PIPE, (uint64_t)p) == 0, "create unreadable-source pipe");
        failures += check(syscall4(SYS_SENDFILE, p[1], unreadable, 0, 1) == -EBADF,
                          "sendfile unreadable source");
        syscall1(SYS_CLOSE, (uint64_t)p[0]); syscall1(SYS_CLOSE, (uint64_t)p[1]); p[0] = p[1] = -1;
        syscall1(SYS_CLOSE, (uint64_t)unreadable);
    }
    syscall1(SYS_CLOSE, (uint64_t)source_fd); syscall1(SYS_CLOSE, (uint64_t)target_fd);
    syscall1(SYS_UNLINK, (uint64_t)source_path);
    syscall1(SYS_UNLINK, (uint64_t)target_path);
    if (failures) exit_raw(1);
    print("hello90: PASS\n");
    print("hello90 done\n");
    exit_raw(0);
}
