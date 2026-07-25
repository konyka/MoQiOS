/// hello30: brk growth, page hygiene, and shrink
///
/// Three properties, each of which was broken:
///   1. Growing the break returns the requested address and the new pages are
///      usable.
///   2. Freshly broken-in pages read as zero. The physical allocator does not
///      clear pages, so a break that skips zeroing hands the process whatever
///      the previous owner left in that frame.
///   3. Shrinking the break returns. The growth loop iterated
///      `old_page..new_page`, so a smaller address reversed the range and
///      panicked the kernel on an integer overflow.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
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

/* MoQiOS syscall numbers: not the Linux set (12 is munmap here, not brk). */
#define SYS_WRITE  1
#define SYS_EXIT   2
#define SYS_BRK    7
#define SYS_MMAP   8
#define SYS_MUNMAP 12

#define PROT_READ      0x1
#define PROT_WRITE     0x2
#define MAP_PRIVATE    0x02
#define MAP_ANONYMOUS  0x20

#define PAGE 4096

void _start(void);

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

/// One byte as two hex digits, per syscall. Emitting a byte at a time keeps the
/// compiler from vectorizing a nibble loop into SSE constant-pool loads, which
/// this kernel's user images do not survive.
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

/// Every page in [addr, addr+len) reads as zero, and the range is writable.
static int range_is_zero_and_writable(uint64_t addr, uint64_t len) {
    volatile unsigned char *p = (volatile unsigned char *)addr;
    for (uint64_t i = 0; i < len; i++) {
        if (p[i] != 0) return 0;
    }
    p[0] = 0x5A;
    p[len - 1] = 0xA5;
    return p[0] == 0x5A && p[len - 1] == 0xA5;
}

void _start(void) {
    print("hello30: brk/mmap test\n");

    int failures = 0;

    const int64_t start = syscall1(SYS_BRK, 0);
    print("hello30: brk(0)=");
    print_hex((uint64_t)start);
    print("\n");

    if (start <= 0) {
        print("hello30: FAIL (no initial break)\n");
        failures++;
    } else {
        /// 1. Growing the break must return the requested address. The old
        ///    range check required the break to stay under the 8MB stack top,
        ///    which no ELF image can satisfy, so this returned the old break.
        const uint64_t grown = (uint64_t)start + 2 * PAGE;
        const int64_t got = syscall1(SYS_BRK, grown);
        print("hello30: grow=");
        print_hex((uint64_t)got);
        print("\n");
        if ((uint64_t)got != grown) {
            print("hello30: FAIL (brk grow refused)\n");
            failures++;
        } else {
            /// 2. The physical allocator hands out dirty frames, so a break that
            ///    skips zeroing leaks the previous owner's data.
            const uint64_t heap = ((uint64_t)start + PAGE - 1) & ~(uint64_t)(PAGE - 1);
            if (!range_is_zero_and_writable(heap, PAGE)) {
                print("hello30: FAIL (heap page not zeroed/writable)\n");
                failures++;
            }
        }

        /// 3. Shrinking must return rather than panic the kernel: the growth
        ///    loop ran `old_page..new_page` unconditionally, and a smaller
        ///    address reversed the range.
        print("hello30: shrinking...\n");
        const int64_t back = syscall1(SYS_BRK, (uint64_t)start);
        print("hello30: shrink=");
        print_hex((uint64_t)back);
        print("\n");
        if ((uint64_t)back != (uint64_t)start) {
            print("hello30: FAIL (brk shrink refused)\n");
            failures++;
        }
    }

    /// 4. Anonymous mmap must place two usable, zeroed pages.
    const int64_t m = syscall6(SYS_MMAP, 0, 2 * PAGE, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    print("hello30: mmap=");
    print_hex((uint64_t)m);
    print("\n");
    if (m <= 0) {
        print("hello30: FAIL (mmap refused)\n");
        failures++;
    } else {
        if (!range_is_zero_and_writable((uint64_t)m, 2 * PAGE)) {
            print("hello30: FAIL (mmap pages not zeroed/writable)\n");
            failures++;
        }
        if (syscall2(SYS_MUNMAP, (uint64_t)m, 2 * PAGE) != 0) {
            print("hello30: FAIL (munmap refused)\n");
            failures++;
        }
    }

    /// 5. A hint without MAP_FIXED is advisory. Point it at this program's own
    ///    code: honouring it would overwrite the page executing this test and
    ///    strand the frame underneath. The kernel must place the mapping
    ///    elsewhere and leave the code intact.
    const uint64_t own_code = (uint64_t)&_start & ~(uint64_t)(PAGE - 1);
    const int64_t h = syscall6(SYS_MMAP, own_code, PAGE, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    print("hello30: hint=");
    print_hex((uint64_t)h);
    print("\n");
    if (h <= 0) {
        print("hello30: FAIL (hinted mmap refused)\n");
        failures++;
    } else if ((uint64_t)h == own_code) {
        print("hello30: FAIL (hint honoured over live code)\n");
        failures++;
    } else {
        /// Still executing, so the code page survived.
        if (syscall2(SYS_MUNMAP, (uint64_t)h, PAGE) != 0) {
            print("hello30: FAIL (munmap of hinted mapping refused)\n");
            failures++;
        }
    }

    if (failures == 0) {
        print("hello30: brk/mmap PASS\n");
    } else {
        print("hello30: brk/mmap FAIL\n");
    }

    print("hello30 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
