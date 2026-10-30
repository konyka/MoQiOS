/// hello131: mmap / munmap / mprotect / mremap / brk argument and errno rules.

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
static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_OPEN      9
#define SYS_CLOSE     11
#define SYS_BRK       7
#define SYS_MMAP      8
#define SYS_MUNMAP    12
#define SYS_MREMAP    25
#define SYS_MPROTECT  164
#define SYS_MADVISE   28
#define SYS_MSYNC     26

#define PROT_NONE  0
#define PROT_READ  1
#define PROT_WRITE 2
#define PROT_EXEC  4
#define MAP_SHARED    0x01
#define MAP_PRIVATE   0x02
#define MAP_FIXED     0x10
#define MAP_ANON      0x20
#define MREMAP_MAYMOVE 1
#define PAGE 4096

#define ENOMEM_ 12
#define EACCES_ 13
#define EBADF_  9
#define EINVAL_ 22
#define ENODEV_ 19
#define EFAULT_ 14

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello131:   ok   " : "hello131:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int64_t mmap_anon(uint64_t len, uint64_t prot) {
    return syscall6(SYS_MMAP, 0, len, prot, MAP_PRIVATE | MAP_ANON, (uint64_t)-1, 0);
}

void _start(void) {
    print("hello131: memory-mapping argument rules\n");

    /* A: mmap argument validation */
    check(syscall6(SYS_MMAP, 0, 0, PROT_READ, MAP_PRIVATE | MAP_ANON, (uint64_t)-1, 0) == -EINVAL_, "A: length 0 is EINVAL");
    check(syscall6(SYS_MMAP, 0, PAGE, PROT_READ, 0, (uint64_t)-1, 0) == -EINVAL_, "A: neither MAP_SHARED nor MAP_PRIVATE is EINVAL");
    check(syscall6(SYS_MMAP, 0, PAGE, PROT_READ, MAP_SHARED | MAP_PRIVATE | MAP_ANON, (uint64_t)-1, 0) == -EINVAL_, "A: both MAP_SHARED and MAP_PRIVATE is EINVAL");
    check(syscall6(SYS_MMAP, 0, PAGE, 0x100, MAP_PRIVATE | MAP_ANON, (uint64_t)-1, 0) == -EINVAL_, "A: unknown PROT bits are EINVAL");
    check(syscall6(SYS_MMAP, 0x1001, PAGE, PROT_READ, MAP_PRIVATE | MAP_ANON | MAP_FIXED, (uint64_t)-1, 0) == -EINVAL_, "A: MAP_FIXED with an unaligned address is EINVAL");
    check(syscall6(SYS_MMAP, 0, PAGE, PROT_READ, MAP_PRIVATE, 999, 0) == -EBADF_, "A: a file mapping with a bad fd is EBADF");
    check(syscall6(SYS_MMAP, 0, 0x7FFFFFFFFFFFF000ULL, PROT_READ, MAP_PRIVATE | MAP_ANON, (uint64_t)-1, 0) == -ENOMEM_, "A: an absurd length is ENOMEM");
    {
        int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/dev/null", 0, 0);
        int64_t r = syscall6(SYS_MMAP, 0, PAGE, PROT_READ, MAP_PRIVATE, (uint64_t)fd, 0);
        check(fd >= 0 && r < 0 && r != -1, "A: mapping a device that cannot be mapped has a specific errno");
        if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
        fd = syscall3(SYS_OPEN, (uint64_t)"hello2", 0, 0);
        check(fd >= 0 && syscall6(SYS_MMAP, 0, PAGE, PROT_READ, MAP_PRIVATE, (uint64_t)fd, 123) == -EINVAL_, "A: an unaligned file offset is EINVAL");
        if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* B: munmap */
    int64_t m = mmap_anon(3 * PAGE, PROT_READ | PROT_WRITE);
    check(m > 0, "B: map three pages");
    check(syscall2(SYS_MUNMAP, (uint64_t)m + 1, PAGE) == -EINVAL_, "B: munmap with an unaligned address is EINVAL");
    check(syscall2(SYS_MUNMAP, (uint64_t)m, 0) == -EINVAL_, "B: munmap with length 0 is EINVAL");
    check(syscall2(SYS_MUNMAP, (uint64_t)m + PAGE, PAGE) == 0, "B: unmap the middle page");
    check(syscall2(SYS_MUNMAP, (uint64_t)m + PAGE, PAGE) == 0, "B: unmapping an already unmapped range succeeds");
    check(syscall2(SYS_MUNMAP, (uint64_t)m, 3 * PAGE) == 0, "B: unmap the rest (a hole in the range is fine)");

    /* C: mprotect */
    m = mmap_anon(2 * PAGE, PROT_READ | PROT_WRITE);
    check(syscall3(SYS_MPROTECT, (uint64_t)m + 1, PAGE, PROT_READ) == -EINVAL_, "C: mprotect with an unaligned address is EINVAL");
    check(syscall3(SYS_MPROTECT, (uint64_t)m, PAGE, 0x100) == -EINVAL_, "C: mprotect with unknown PROT bits is EINVAL");
    check(syscall3(SYS_MPROTECT, (uint64_t)m, 0, PROT_READ) == 0, "C: mprotect with length 0 is a no-op");
    check(syscall3(SYS_MPROTECT, 0x10000000ULL, PAGE, PROT_READ) == -ENOMEM_, "C: mprotect on an unmapped range is ENOMEM");
    check(syscall3(SYS_MPROTECT, (uint64_t)m, PAGE, PROT_READ) == 0, "C: make a page read-only");
    check(syscall3(SYS_MPROTECT, (uint64_t)m, 4 * PAGE, PROT_READ) == -ENOMEM_, "C: a range that runs past the mapping is ENOMEM");
    syscall2(SYS_MUNMAP, (uint64_t)m, 2 * PAGE);

    /* D: mremap */
    m = mmap_anon(PAGE, PROT_READ | PROT_WRITE);
    check(syscall5(SYS_MREMAP, (uint64_t)m + 1, PAGE, 2 * PAGE, MREMAP_MAYMOVE, 0) == -EINVAL_, "D: mremap with an unaligned address is EINVAL");
    check(syscall5(SYS_MREMAP, (uint64_t)m, PAGE, 0, MREMAP_MAYMOVE, 0) == -EINVAL_, "D: mremap to length 0 is EINVAL");
    check(syscall5(SYS_MREMAP, 0x10000000ULL, PAGE, 2 * PAGE, MREMAP_MAYMOVE, 0) == -EFAULT_, "D: mremap of an unmapped range is EFAULT");
    check(syscall5(SYS_MREMAP, (uint64_t)m, PAGE, 2 * PAGE, 0x8, 0) == -EINVAL_, "D: unknown mremap flags are EINVAL");
    {
        int64_t g = syscall5(SYS_MREMAP, (uint64_t)m, PAGE, 3 * PAGE, MREMAP_MAYMOVE, 0);
        check(g > 0, "D: growing with MREMAP_MAYMOVE works");
        if (g > 0) { *(volatile char *)g = 'x'; *(volatile char *)(g + 2 * PAGE) = 'y'; }
        if (g > 0) m = g;
    }
    syscall2(SYS_MUNMAP, (uint64_t)m, 3 * PAGE);

    /* E: brk */
    int64_t cur = syscall1(SYS_BRK, 0);
    check(cur > 0, "E: brk(0) returns the current break");
    check(syscall1(SYS_BRK, (uint64_t)cur + 8192) == cur + 8192, "E: brk grows");
    check(syscall1(SYS_BRK, (uint64_t)cur) == cur, "E: brk shrinks back");
    check(syscall1(SYS_BRK, 0x1000) == cur, "E: an absurdly low break is refused (returns the current break)");

    print(failures == 0 ? "hello131: PASS\n" : "hello131: FAIL\n");
    print("hello131 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
