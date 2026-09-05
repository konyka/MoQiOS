// hello92 - self-only process_vm_readv/writev safety and page-boundary checks.
#include <stdint.h>

typedef struct {
    uint64_t base;
    uint64_t len;
} iovec_t;

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
#define SYS_EXIT 2
#define SYS_GETPID 4
#define SYS_MMAP 8
#define SYS_MUNMAP 12
#define SYS_MPROTECT 164
#define SYS_PROCESS_VM_READV 283
#define SYS_PROCESS_VM_WRITEV 284
#define PAGE 4096UL
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_RW (PROT_READ | PROT_WRITE)
#define MAP_PRIVATE 0x02
#define MAP_ANONYMOUS 0x20
#define EFAULT 14
#define EINVAL 22
#define EPERM 1

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello92: FAIL ");
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

static int all_bytes(const uint8_t *buf, uint8_t value, uint64_t len) {
    for (uint64_t i = 0; i < len; i++) {
        if (buf[i] != value) return 0;
    }
    return 1;
}

void _start(void) {
    int failures = 0;
    const uint64_t len = 32;
    const int64_t pid = syscall1(SYS_GETPID, 0);
    uint8_t *source = (uint8_t *)syscall6(SYS_MMAP, 0, 2 * PAGE, PROT_RW,
                                          MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    uint8_t *destination = (uint8_t *)syscall6(SYS_MMAP, 0, 2 * PAGE, PROT_RW,
                                                MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    uint8_t *readonly = (uint8_t *)syscall6(SYS_MMAP, 0, PAGE, PROT_RW,
                                             MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    uint8_t *unmapped = (uint8_t *)syscall6(SYS_MMAP, 0, PAGE, PROT_RW,
                                             MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    uint8_t *partial_destination = (uint8_t *)syscall6(SYS_MMAP, 0, 2 * PAGE, PROT_RW,
                                                        MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if ((uint64_t)source < PAGE || (uint64_t)destination < PAGE ||
        (uint64_t)readonly < PAGE || (uint64_t)unmapped < PAGE ||
        (uint64_t)partial_destination < PAGE)
        exit_raw(1);

    for (uint64_t i = 0; i < len; i++) {
        source[PAGE - 8 + i] = (uint8_t)(0x30 + i);
        destination[PAGE - 8 + i] = 0;
        readonly[i] = 0x5a;
    }
    iovec_t local = {(uint64_t)(destination + PAGE - 8), len};
    iovec_t remote = {(uint64_t)(source + PAGE - 8), len};
    print("hello92: start\n");

    failures += check(syscall6(SYS_PROCESS_VM_READV, (uint64_t)pid,
                                (uint64_t)&local, 1, (uint64_t)&remote, 1, 0) == (int64_t)len,
                      "self readv succeeds across page boundary");
    failures += check(destination[PAGE - 8] == 0x30 && destination[PAGE + 23] == 0x4f,
                      "readv copied both pages");

    for (uint64_t i = 0; i < len; i++) destination[PAGE - 8 + i] = 0x5a;
    failures += check(syscall6(SYS_PROCESS_VM_READV, (uint64_t)pid,
                               (uint64_t)&local, 1, (uint64_t)&remote, 1, 1) == -EINVAL &&
                      all_bytes(destination + PAGE - 8, 0x5a, len),
                      "invalid flags do not mutate destination");
    failures += check(syscall6(SYS_PROCESS_VM_READV, (uint64_t)pid,
                               (uint64_t)&local, 17, (uint64_t)&remote, 1, 0) == -EFAULT &&
                      all_bytes(destination + PAGE - 8, 0x5a, len),
                      "invalid count does not mutate destination");

    for (uint64_t i = 0; i < len; i++) destination[PAGE - 8 + i] = (uint8_t)(0xa0 + i);
    failures += check(syscall6(SYS_PROCESS_VM_WRITEV, (uint64_t)pid,
                               (uint64_t)&local, 1, (uint64_t)&remote, 1, 0) == (int64_t)len,
                      "self writev succeeds across page boundary");
    failures += check(source[PAGE - 8] == 0xa0 && source[PAGE + 23] == 0xbf,
                      "writev copied both pages");

    failures += check(syscall6(SYS_PROCESS_VM_READV, (uint64_t)(pid + 1),
                               (uint64_t)&local, 1, (uint64_t)&remote, 1, 0) == -EPERM,
                      "non-self target is rejected");
    failures += check(syscall6(SYS_PROCESS_VM_READV, (uint64_t)pid,
                               0, 1, (uint64_t)&remote, 1, 0) == -EFAULT,
                      "invalid local iovec pointer is rejected");

    failures += check(syscall3(SYS_MPROTECT, (uint64_t)readonly, PAGE, PROT_READ) == 0,
                      "readonly mapping setup succeeds");
    iovec_t readonly_local = {(uint64_t)readonly, len};
    failures += check(syscall6(SYS_PROCESS_VM_READV, (uint64_t)pid,
                                (uint64_t)&readonly_local, 1, (uint64_t)&remote, 1, 0) == -EFAULT,
                      "readonly readv destination returns EFAULT");
    failures += check(all_bytes(readonly, 0x5a, len), "readonly destination is unchanged");

    failures += check(syscall2(SYS_MUNMAP, (uint64_t)unmapped, PAGE) == 0,
                      "unmapped destination setup succeeds");
    iovec_t unmapped_local = {(uint64_t)unmapped, len};
    failures += check(syscall6(SYS_PROCESS_VM_READV, (uint64_t)pid,
                                (uint64_t)&unmapped_local, 1, (uint64_t)&remote, 1, 0) == -EFAULT,
                      "unmapped readv destination returns EFAULT");

    for (uint64_t i = 0; i < PAGE; i++) source[i] = 0xc3;
    for (uint64_t i = 0; i < PAGE; i++) source[PAGE + i] = 0xd4;
    failures += check(syscall2(SYS_MUNMAP, (uint64_t)(partial_destination + PAGE), PAGE) == 0,
                      "partial-copy destination setup succeeds");
    iovec_t partial_local = {(uint64_t)partial_destination, 2 * PAGE};
    iovec_t partial_remote = {(uint64_t)source, 2 * PAGE};
    failures += check(syscall6(SYS_PROCESS_VM_READV, (uint64_t)pid,
                                (uint64_t)&partial_local, 1, (uint64_t)&partial_remote, 1, 0) == PAGE,
                      "readv reports a positive partial copy");
    failures += check(all_bytes(partial_destination, 0xc3, PAGE),
                      "partial readv transfers the mapped first page");
    failures += check(syscall2(SYS_MUNMAP, (uint64_t)partial_destination, PAGE) == 0,
                      "partial-copy destination cleanup succeeds");

    iovec_t bad_local = {0, len};
    failures += check(syscall6(SYS_PROCESS_VM_WRITEV, (uint64_t)pid,
                               (uint64_t)&bad_local, 1, (uint64_t)&remote, 1, 0) == -EFAULT,
                      "invalid writev source pointer returns EFAULT");

    syscall2(SYS_MUNMAP, (uint64_t)source, 2 * PAGE);
    syscall2(SYS_MUNMAP, (uint64_t)destination, 2 * PAGE);
    syscall2(SYS_MUNMAP, (uint64_t)readonly, PAGE);
    if (failures != 0) exit_raw(1);
    print("hello92: PASS\n");
    print("hello92 done\n");
    exit_raw(0);
}
