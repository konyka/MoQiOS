/// hello36: race a user buffer out from under a syscall that is copying it
///
/// copyFromUser/copyToUser walk the page tables before entering a guarded x86
/// copy instruction. Nothing holds the mapping still between those operations;
/// a second thread can unmap the range, and the copy must return short via the
/// page-fault fixup instead of taking the machine down.
///
/// Until hello35 there was no way to run two tasks in one address space from
/// user code, so this window could only be argued about. Now it can be tested.
///
/// The writer thread keeps a large buffer in flight through write(); the racer
/// thread unmaps and immediately remaps it at the same address. Remapping is
/// what makes this a race rather than a plainly invalid pointer: most of the
/// time the buffer is perfectly valid and the syscall must succeed.

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

static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8)
                      : "rcx", "r11", "memory");
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

#define SYS_WRITE  1
#define SYS_EXIT   2
#define SYS_OPEN   9
#define SYS_CLOSE  11
#define SYS_MMAP   8
#define SYS_MUNMAP 12
#define SYS_CLONE  243

#define CLONE_VM     0x100
#define CLONE_FS     0x200
#define CLONE_FILES  0x400
#define CLONE_THREAD 0x10000

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_FIXED     0x10
#define MAP_ANONYMOUS 0x20

#define O_WRONLY_CREAT 0x41

#define STACK_SIZE (16 * 4096)
/// Large enough that the page-table walk plus the copy stay busy for a while,
/// which is the window the racer has to hit.
#define BUF_PAGES 64
#define BUF_SIZE  (BUF_PAGES * 4096)

#define ROUNDS 400

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_dec(int64_t v) {
    char buf[24];
    int pos = 0;
    if (v < 0) { print("-"); v = -v; }
    if (v == 0) { print("0"); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char t = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = t; }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

static volatile uint64_t buf_addr = 0;
static volatile int racer_done = 0;
static volatile int writer_done = 0;

void _start(void) {
    print("hello36: copy-vs-munmap race\n");

    const int64_t stack = syscall6(SYS_MMAP, 0, STACK_SIZE, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    const int64_t region = syscall6(SYS_MMAP, 0, BUF_SIZE, PROT_READ | PROT_WRITE,
                                    MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (stack <= 0 || region <= 0) {
        print("hello36: FAIL (no memory)\n");
        print("hello36 done\n");
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }
    buf_addr = (uint64_t)region;

    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/race", O_WRONLY_CREAT, 0666);
    if (fd < 0) {
        print("hello36: FAIL (no file)\n");
        print("hello36 done\n");
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }

    const int64_t tid = syscall5(SYS_CLONE,
                                 CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_THREAD,
                                 (uint64_t)(stack + STACK_SIZE - 16), 0, 0, 0);
    if (tid == 0) {
        /// Racer. Unmap and immediately restore, over and over, so the writer
        /// mostly sees a valid buffer and occasionally loses it mid-copy.
        for (int i = 0; i < ROUNDS * 4 && !writer_done; i++) {
            syscall2(SYS_MUNMAP, buf_addr, BUF_SIZE);
            syscall6(SYS_MMAP, buf_addr, BUF_SIZE, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, (uint64_t)-1, 0);
        }
        racer_done = 1;
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
    if (tid < 0) {
        print("hello36: FAIL (clone=");
        print_dec(tid);
        print(")\n");
        print("hello36 done\n");
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }

    int64_t full = 0, partial = 0, refused = 0;
    for (int i = 0; i < ROUNDS; i++) {
        const int64_t n = syscall3(SYS_WRITE, (uint64_t)fd, buf_addr, BUF_SIZE);
        if (n == BUF_SIZE) full++;
        else if (n > 0) partial++;
        else refused++;
    }
    writer_done = 1;

    /// Reaching this line at all is the result: a kernel that faults inside its
    /// own copy never gets here.
    print("hello36:   writes full=");
    print_dec(full);
    print(" partial=");
    print_dec(partial);
    print(" refused=");
    print_dec(refused);
    print("\n");

    int spins = 0;
    while (!racer_done && spins < 100000) spins++;

    syscall1(SYS_CLOSE, (uint64_t)fd);
    print("hello36: PASS (survived the race)\n");
    print("hello36 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
