/// hello120: mseal(2).
///
///   A. Argument rules: flags must be 0 (EINVAL), addr page-aligned (EINVAL),
///      len 0 is a no-op, an unmapped range is ENOMEM.
///   B. A sealed anonymous mapping still reads and writes, but munmap,
///      mprotect, mremap and a MAP_FIXED mmap over it fail with EPERM and
///      leave the data intact. A range that only partly overlaps the seal is
///      refused as a whole.
///   C. Neighbouring unsealed pages of the same mapping stay changeable.
///   D. A forked child inherits the seal.

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

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_MMAP      8
#define SYS_MUNMAP    12
#define SYS_MREMAP    25
#define SYS_FORK      57
#define SYS_MPROTECT  164
#define SYS_MSEAL     462
#define PROT_RW       3
#define PROT_R        1
#define MAP_PRIV_ANON 0x22
#define MAP_FIXED     0x10
#define MREMAP_MAYMOVE 1
#define EPERM_        1
#define EINVAL_       22
#define ENOMEM_       12
#define PAGE          4096

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello120:   ok   " : "hello120:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

void _start(void) {
    print("hello120: mseal\n");
    int64_t m = syscall6(SYS_MMAP, 0, 4 * PAGE, PROT_RW, MAP_PRIV_ANON, (uint64_t)-1, 0);
    check(m > 0, "setup: mmap 4 pages");
    if (m <= 0) goto out;
    volatile char *p = (volatile char *)m;
    p[0] = 'S';
    p[PAGE] = 'T';
    p[3 * PAGE] = 'N';
    uint64_t a = (uint64_t)m;

    /* A */
    check(syscall3(SYS_MSEAL, a, PAGE, 1) == -EINVAL_, "A: non-zero flags are EINVAL");
    check(syscall3(SYS_MSEAL, a + 1, PAGE, 0) == -EINVAL_, "A: an unaligned address is EINVAL");
    check(syscall3(SYS_MSEAL, a, 0, 0) == 0, "A: len 0 is a no-op");
    check(syscall3(SYS_MSEAL, 0x7000000000ULL, PAGE, 0) == -ENOMEM_, "A: an unmapped range is ENOMEM");

    /* B: seal pages 0..1 */
    check(syscall3(SYS_MSEAL, a, 2 * PAGE, 0) == 0, "B: mseal the first two pages");
    p[1] = 'x';
    check(p[0] == 'S' && p[1] == 'x' && p[PAGE] == 'T', "B: the sealed pages still read and write");
    check(syscall2(SYS_MUNMAP, a, PAGE) == -EPERM_, "B: munmap of a sealed page is EPERM");
    check(syscall3(SYS_MPROTECT, a, PAGE, PROT_R) == -EPERM_, "B: mprotect of a sealed page is EPERM");
    check(syscall6(SYS_MREMAP, a, 2 * PAGE, 3 * PAGE, MREMAP_MAYMOVE, 0, 0) == -EPERM_, "B: mremap of a sealed range is EPERM");
    check(syscall6(SYS_MMAP, a, PAGE, PROT_RW, MAP_PRIV_ANON | MAP_FIXED, (uint64_t)-1, 0) == -EPERM_, "B: MAP_FIXED over a sealed page is EPERM");
    check(syscall2(SYS_MUNMAP, a + PAGE, 2 * PAGE) == -EPERM_, "B: a range that partly overlaps the seal is refused");
    check(p[0] == 'S' && p[PAGE] == 'T' && p[2 * PAGE] == 0, "B: the data survived every refused call");

    /* C */
    check(syscall3(SYS_MPROTECT, a + 3 * PAGE, PAGE, PROT_R) == 0 && p[3 * PAGE] == 'N', "C: an unsealed neighbour can still be re-protected");
    check(syscall2(SYS_MUNMAP, a + 2 * PAGE, PAGE) == 0, "C: an unsealed neighbour can still be unmapped");

    /* D */
    {
        int64_t kid = syscall1(SYS_FORK, 0);
        if (kid == 0) {
            int ok = syscall2(SYS_MUNMAP, a, PAGE) == -EPERM_ && p[0] == 'S';
            syscall1(SYS_EXIT, ok ? 0 : 1);
            for (;;) {}
        }
        int32_t st = -1;
        syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
        check(kid > 0 && st == 0, "D: a forked child inherits the seal");
    }

out:
    print(failures == 0 ? "hello120: PASS\n" : "hello120: FAIL\n");
    print("hello120 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
