// hello95 - user-copy fault acceptance: the last discarded copyFromUser
// results in mount/umount2/vmsplice/setitimer must surface EFAULT instead of
// consuming zero-filled or uninitialized kernel buffers. Bad pointers are an
// mmap'd-then-munmap'd page (the hello40/hello92 unmapped-page technique).
#include <stdint.h>

static inline int64_t syscall1(uint64_t n, uint64_t a) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a) : "rcx", "r11", "memory");
    return r;
}

static inline int64_t syscall2(uint64_t n, uint64_t a, uint64_t b) {
    int64_t r;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "rcx", "r11", "memory");
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

static inline int64_t syscall6(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f) {
    int64_t r;
    register uint64_t x __asm__("rdx") = c;
    register uint64_t y __asm__("r10") = d;
    register uint64_t z __asm__("r8") = e;
    register uint64_t w __asm__("r9") = f;
    __asm__ volatile ("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "r"(x), "r"(y), "r"(z), "r"(w) : "rcx", "r11", "memory");
    return r;
}

#define SYS_READ      10
#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_MMAP      8
#define SYS_MUNMAP    12
#define SYS_PIPE      22
#define SYS_SETITIMER 38
#define SYS_MOUNT     288
#define SYS_UMOUNT2   289
#define SYS_VMSPLICE  294

#define PROT_READ     1
#define PROT_WRITE    2
#define MAP_PRIVATE   2
#define MAP_ANONYMOUS 0x20
#define PAGE          4096
#define EFAULT        14

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello95: FAIL ");
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
    print("hello95: start\n");

    /* Unmapped but in-range page: any user copy from it must fault. */
    const int64_t bad = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (bad <= 0) exit_raw(1);
    if (syscall2(SYS_MUNMAP, (uint64_t)bad, PAGE) != 0) exit_raw(1);

    /* vmsplice: an iovec array on an unmapped page must be EFAULT, not a
     * garbage base/len pair read from an uninitialized kernel stack buffer. */
    int32_t pipe_fds[2] = { -1, -1 }; /* kernel pipe writes two u32 fds */
    failures += check(syscall1(SYS_PIPE, (uint64_t)pipe_fds) == 0, "create vmsplice pipe");
    const uint64_t pipe_rd = (uint64_t)(uint32_t)pipe_fds[0];
    const uint64_t pipe_wr = (uint64_t)(uint32_t)pipe_fds[1];
    failures += check(syscall4(SYS_VMSPLICE, pipe_wr, (uint64_t)bad, 1, 0) == -EFAULT,
                      "vmsplice with unmapped iov returns EFAULT");

    /* vmsplice positive: a valid iovec still splices into the pipe. */
    {
        const char *msg = "hello95-vmsplice";
        uint64_t len = 0;
        while (msg[len]) len++;
        int64_t iov[2] = { (int64_t)msg, (int64_t)len };
        failures += check(syscall4(SYS_VMSPLICE, pipe_wr, (uint64_t)iov, 1, 0) == (int64_t)len,
                          "vmsplice valid iov writes all bytes");
        char buf[32];
        for (uint64_t i = 0; i < sizeof(buf); i++) buf[i] = 0;
        failures += check(syscall3(SYS_READ, pipe_rd, (uint64_t)buf, len) == (int64_t)len,
                          "vmsplice payload readable from pipe");
    }

    /* setitimer: an unreadable new_value must be EFAULT instead of arming a
     * garbage timer from an uninitialized kernel buffer. Disarm immediately
     * afterwards so a pre-fix kernel cannot kill this test with SIGALRM. */
    int64_t zero_itimer[4] = { 0, 0, 0, 0 };
    failures += check(syscall3(SYS_SETITIMER, 0, (uint64_t)bad, 0) == -EFAULT,
                      "setitimer with unmapped new_value returns EFAULT");
    failures += check(syscall3(SYS_SETITIMER, 0, (uint64_t)zero_itimer, 0) == 0,
                      "setitimer valid zero value disarms");

    /* umount2: target is mandatory; an unreadable target must be EFAULT. */
    failures += check(syscall2(SYS_UMOUNT2, (uint64_t)bad, 0) == -EFAULT,
                      "umount2 with unmapped target returns EFAULT");

    /* mount: bad target / bad non-null source / bad non-null fstype are all
     * EFAULT; only a null source or fstype may be skipped. */
    failures += check(syscall4(SYS_MOUNT, (uint64_t)"x", (uint64_t)bad, (uint64_t)"tmpfs", 0) == -EFAULT,
                      "mount with unmapped target returns EFAULT");
    failures += check(syscall4(SYS_MOUNT, (uint64_t)bad, (uint64_t)"/mnt_h95_badsrc", (uint64_t)"tmpfs", 0) == -EFAULT,
                      "mount with unmapped source returns EFAULT");
    syscall2(SYS_UMOUNT2, (uint64_t)"/mnt_h95_badsrc", 0); /* pre-fix cleanup */
    failures += check(syscall4(SYS_MOUNT, (uint64_t)"x", (uint64_t)"/mnt_h95_badfst", (uint64_t)bad, 0) == -EFAULT,
                      "mount with unmapped fstype returns EFAULT");
    syscall2(SYS_UMOUNT2, (uint64_t)"/mnt_h95_badfst", 0); /* pre-fix cleanup */

    /* mount/umount positive round-trip with valid pointers. */
    failures += check(syscall4(SYS_MOUNT, (uint64_t)"hello95", (uint64_t)"/mnt_hello95", (uint64_t)"tmpfs", 0) == 0,
                      "mount with valid pointers succeeds");
    failures += check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt_hello95", 0) == 0,
                      "umount2 with valid target succeeds");

    if (failures != 0) exit_raw(1);
    print("hello95: PASS\n");
    print("hello95 done\n");
    exit_raw(0);
}
