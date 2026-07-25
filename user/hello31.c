/// hello31: per-task TLS base (x86_64 FS_BASE)
///
/// FS_BASE was written by clone(CLONE_SETTLS) directly onto the CPU running the
/// caller, and no task ever saved or restored it. So the base was effectively a
/// property of the CPU rather than of the thread: whoever set it changed it for
/// the task that was running, and the value then stayed for every task scheduled
/// afterwards on that CPU.
///
/// This checks the property that fixes it — a task's TLS base belongs to the
/// task. Each process points FS at its own TLS block, writes a distinct value
/// through %fs, lets the other process run, and reads it back.

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
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

/* MoQiOS syscall numbers. */
#define SYS_WRITE      1
#define SYS_EXIT       2
#define SYS_FORK       57
#define SYS_WAITPID    6
#define SYS_MMAP       8
#define SYS_SCHED_YIELD 24
#define SYS_ARCH_PRCTL 472

#define ARCH_SET_FS 0x1002
#define ARCH_GET_FS 0x1003

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define PAGE 4096

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_byte(unsigned char b) {
    const char hi = (char)((b >> 4) < 10 ? '0' + (b >> 4) : 'a' + (b >> 4) - 10);
    const char lo = (char)((b & 0xF) < 10 ? '0' + (b & 0xF) : 'a' + (b & 0xF) - 10);
    char buf[2];
    buf[0] = hi;
    buf[1] = lo;
    syscall3(SYS_WRITE, 1, (uint64_t)buf, 2);
}

static void print_hex(uint64_t v) {
    print("0x");
    print_byte((unsigned char)(v >> 56));
    print_byte((unsigned char)(v >> 48));
    print_byte((unsigned char)(v >> 40));
    print_byte((unsigned char)(v >> 32));
    print_byte((unsigned char)(v >> 24));
    print_byte((unsigned char)(v >> 16));
    print_byte((unsigned char)(v >> 8));
    print_byte((unsigned char)v);
}

/// Read and write the 8 bytes at %fs:0 — the classic TLS self-pointer slot.
static inline uint64_t fs_read0(void) {
    uint64_t v;
    __asm__ volatile ("movq %%fs:0, %0" : "=r"(v) :: "memory");
    return v;
}

static inline void fs_write0(uint64_t v) {
    __asm__ volatile ("movq %0, %%fs:0" :: "r"(v) : "memory");
}

void _start(void) {
    print("hello31: TLS base test\n");

    int failures = 0;

    /// A page per process to serve as a TLS block. The child inherits this
    /// mapping through fork but gets its own copy of the page on write.
    const int64_t tls = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (tls <= 0) {
        print("hello31: FAIL (no TLS page)\n");
        print("hello31 done\n");
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }

    if (syscall2(SYS_ARCH_PRCTL, ARCH_SET_FS, (uint64_t)tls) != 0) {
        print("hello31: FAIL (arch_prctl SET_FS refused)\n");
        failures++;
    }

    /// SET_FS must be readable back, and %fs must actually reach the block.
    uint64_t got = 0;
    if (syscall2(SYS_ARCH_PRCTL, ARCH_GET_FS, (uint64_t)&got) != 0 || got != (uint64_t)tls) {
        print("hello31: FAIL (GET_FS mismatch)\n");
        failures++;
    }

    fs_write0(0xA1A1A1A1A1A1A1A1ULL);
    if (*(volatile uint64_t *)tls != 0xA1A1A1A1A1A1A1A1ULL) {
        print("hello31: FAIL (%fs:0 did not reach the TLS page)\n");
        failures++;
    }

    const int64_t child = syscall1(SYS_FORK, 0);
    if (child < 0) {
        print("hello31: FAIL (fork failed)\n");
        failures++;
    } else if (child == 0) {
        /// Child: fork must have carried the TLS base over, since the address
        /// space is a copy. Then point FS at a block of its own and stamp it.
        uint64_t inherited = 0;
        int child_bad = 0;
        if (syscall2(SYS_ARCH_PRCTL, ARCH_GET_FS, (uint64_t)&inherited) != 0 ||
            inherited != (uint64_t)tls) {
            print("hello31: FAIL (child did not inherit TLS base)\n");
            child_bad = 1;
        }
        if (fs_read0() != 0xA1A1A1A1A1A1A1A1ULL) {
            print("hello31: FAIL (child TLS content wrong)\n");
            child_bad = 1;
        }

        const int64_t child_tls = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                           MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (child_tls <= 0) {
            print("hello31: FAIL (child TLS page)\n");
            child_bad = 1;
        } else {
            if (syscall2(SYS_ARCH_PRCTL, ARCH_SET_FS, (uint64_t)child_tls) != 0) {
                print("hello31: FAIL (child SET_FS refused)\n");
                child_bad = 1;
            }
            fs_write0(0xC2C2C2C2C2C2C2C2ULL);
            /// Yield so the parent runs with the child's base still loaded on
            /// this CPU, then confirm nothing moved it underneath us.
            syscall1(SYS_SCHED_YIELD, 0);
            if (fs_read0() != 0xC2C2C2C2C2C2C2C2ULL) {
                print("hello31: FAIL (child lost its own TLS)\n");
                child_bad = 1;
            }
        }
        if (!child_bad) print("hello31: child TLS ok\n");
        syscall1(SYS_EXIT, child_bad ? 1 : 0);
        for (;;) {}
    } else {
        /// Parent: let the child install its base, then check ours survived.
        syscall1(SYS_SCHED_YIELD, 0);
        int64_t status = 0;
        syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);

        uint64_t after = 0;
        if (syscall2(SYS_ARCH_PRCTL, ARCH_GET_FS, (uint64_t)&after) != 0 || after != (uint64_t)tls) {
            print("hello31: FAIL (parent TLS base changed)\n");
            failures++;
        }
        if (fs_read0() != 0xA1A1A1A1A1A1A1A1ULL) {
            print("hello31: FAIL (parent reads through the wrong TLS base)\n");
            failures++;
        }
        if (status != 0) {
            print("hello31: FAIL (child reported a problem)\n");
            failures++;
        }
    }

    print("hello31: fs=");
    print_hex(fs_read0());
    print("\n");

    if (failures == 0) {
        print("hello31: TLS PASS\n");
    } else {
        print("hello31: TLS FAIL\n");
    }

    print("hello31 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
