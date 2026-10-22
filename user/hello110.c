/// hello110: madvise(MADV_DONTNEED) drops anonymous pages.
///
/// MADV_DONTNEED used to be a silent no-op (it only cleared a region flag),
/// so a private anonymous range kept its old bytes. Linux semantics, which
/// allocators rely on to recycle memory, are: the mapping stays valid and
/// the next access to a private anonymous page reads zeros.
///
///   A. write 0xAB over 4 pages, DONTNEED the middle two, read back:
///      the dropped pages are zero, the untouched ones still 0xAB.
///   B. the dropped pages are still mapped and writable afterwards.
///   C. DONTNEED on an unmapped range is ENOMEM; a misaligned address EINVAL.

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
static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE   1
#define SYS_EXIT    2
#define SYS_MMAP    8
#define SYS_MUNMAP  12
#define SYS_MADVISE 28

#define PROT_RW         3
#define MAP_PRIVATE_ANON 0x22
#define MADV_DONTNEED   4
#define PAGE 4096

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello110:   ok   " : "hello110:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int all_bytes(volatile uint8_t *p, uint64_t n, uint8_t v) {
    for (uint64_t i = 0; i < n; i++)
        if (p[i] != v) return 0;
    return 1;
}

void _start(void) {
    print("hello110: madvise(MADV_DONTNEED) drops anonymous pages\n");

    int64_t m = syscall6(SYS_MMAP, 0, 4 * PAGE, PROT_RW, MAP_PRIVATE_ANON, (uint64_t)-1, 0);
    check(m > 0, "mmap 4 anonymous pages");
    if (m > 0) {
        volatile uint8_t *p = (volatile uint8_t *)m;
        for (uint64_t i = 0; i < 4 * PAGE; i++) p[i] = 0xAB;

        /* A. drop pages 1 and 2 */
        check(syscall3(SYS_MADVISE, (uint64_t)m + PAGE, 2 * PAGE, MADV_DONTNEED) == 0, "A: MADV_DONTNEED accepted");
        check(all_bytes(p, PAGE, 0xAB), "A: page 0 untouched");
        check(all_bytes(p + PAGE, 2 * PAGE, 0), "A: dropped pages read back zero");
        check(all_bytes(p + 3 * PAGE, PAGE, 0xAB), "A: page 3 untouched");

        /* B. still mapped and writable */
        p[PAGE + 7] = 0x5A;
        check(p[PAGE + 7] == 0x5A, "B: dropped page is writable again");

        /* C. error boundaries */
        check(syscall3(SYS_MADVISE, (uint64_t)m + 1, PAGE, MADV_DONTNEED) == -22, "C: misaligned address is EINVAL");
        syscall2(SYS_MUNMAP, (uint64_t)m, 4 * PAGE);
        check(syscall3(SYS_MADVISE, (uint64_t)m, PAGE, MADV_DONTNEED) == -12, "C: unmapped range is ENOMEM");
    }

    print(failures == 0 ? "hello110: PASS\n" : "hello110: FAIL\n");
    print("hello110 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
