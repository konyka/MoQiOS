/// hello49: user 2MiB huge-page anonymous mmap (I1).
///
///   (a) mmap 4MiB anonymous RW — the kernel picks a 2MiB-aligned base and
///       maps the two full blocks as 2MiB PDEs when contiguous frames are
///       available (4K fallback is transparent either way). Write every
///       4096th byte plus the full first/last pages, verify contents.
///   (b) mprotect the first 1MiB PROT_READ — partially covers huge block 0,
///       so the kernel demotes it to 4K PTEs. Data must survive the demote;
///       writes to the second MiB (same former block) must still work.
///   (c) munmap the last 2MiB (whole huge block 1 — freed directly).
///   (d) fork: the COW clone walk demotes any remaining huge blocks in the
///       parent; the child reads the pattern from the first MiB.
///   (e) munmap the rest.

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

#define SYS_WRITE    1
#define SYS_EXIT     2
#define SYS_WAITPID  6
#define SYS_MMAP     8
#define SYS_MUNMAP   12
#define SYS_FORK     57
#define SYS_MPROTECT 164

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define PAGE   4096ULL
#define MIB2   (2 * 1024 * 1024ULL)
#define LEN    (2 * MIB2)          /* 4MiB = 1024 pages = 2 huge blocks */
#define NPAGES (LEN / PAGE)

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello49: FAIL (");
    print(why);
    print(")\nhello49 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static uint8_t pattern(uint64_t i) {
    return (uint8_t)((i * 13 + 0x42) & 0xFF);
}

/* Verify the bytes written in (a) over pages [first_page, last_page). */
static void verify_range(volatile uint8_t *p, uint64_t first_page, uint64_t last_page) {
    for (uint64_t i = first_page; i < last_page; i++) {
        if (p[i * PAGE] != pattern(i)) {
            char buf[64];
            int n = 0;
            const char *pfx = "hello49: mismatch at page ";
            while (pfx[n]) { buf[n] = pfx[n]; n++; }
            uint64_t v = i; char tmp[20]; int t = 0;
            if (!v) tmp[t++] = '0';
            while (v) { tmp[t++] = '0' + (v % 10); v /= 10; }
            while (t) buf[n++] = tmp[--t];
            const char *mid = " got ";
            for (int k = 0; mid[k]; k++) buf[n++] = mid[k];
            v = p[i * PAGE]; t = 0;
            if (!v) tmp[t++] = '0';
            while (v) { tmp[t++] = '0' + (v % 10); v /= 10; }
            while (t) buf[n++] = tmp[--t];
            const char *mid2 = " want ";
            for (int k = 0; mid2[k]; k++) buf[n++] = mid2[k];
            v = pattern(i); t = 0;
            if (!v) tmp[t++] = '0';
            while (v) { tmp[t++] = '0' + (v % 10); v /= 10; }
            while (t) buf[n++] = tmp[--t];
            buf[n++] = '\n';
            syscall3(SYS_WRITE, 1, (uint64_t)buf, (uint64_t)n);
            fail("boundary byte mismatch");
        }
    }
}

void _start(void) {
    print("hello49: user huge-page mmap test\n");

    /* (a) 4MiB anonymous mapping, eager + huge-eligible. */
    const int64_t base = syscall6(SYS_MMAP, 0, LEN, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (base <= 0) fail("mmap 4MiB");
    volatile uint8_t *p = (volatile uint8_t *)base;

    for (uint64_t i = 0; i < NPAGES; i++) p[i * PAGE] = pattern(i);
    /* Offset-0 bytes are owned by the boundary pattern above; fill the rest. */
    for (uint64_t i = 1; i < PAGE; i++) {
        p[i] = pattern(i);                       /* full first page */
        p[LEN - PAGE + i] = pattern(i);          /* full last page */
    }
    verify_range(p, 0, NPAGES);
    for (uint64_t i = 1; i < PAGE; i++) {
        if (p[i] != pattern(i)) fail("first page contents");
        if (p[LEN - PAGE + i] != pattern(i)) fail("last page contents");
    }
    print("hello49: mmap+verify ok\n");

    /* (b) mprotect the first 1MiB read-only — demotes huge block 0. */
    if (syscall3(SYS_MPROTECT, (uint64_t)base, MIB2 / 2, PROT_READ) != 0)
        fail("mprotect first 1MiB");
    verify_range(p, 0, NPAGES); /* data must survive the demote */
    for (uint64_t i = 1; i < PAGE; i++) {
        if (p[i] != pattern(i)) fail("first page after demote");
    }
    /* Second MiB (same former huge block) is still writable. */
    p[300 * PAGE] = 0x5A;
    p[511 * PAGE + 123] = 0xA5;
    if (p[300 * PAGE] != 0x5A || p[511 * PAGE + 123] != 0xA5)
        fail("write after demote");
    print("hello49: mprotect demote ok\n");

    /* (c) munmap the last 2MiB (whole huge block 1). */
    if (syscall3(SYS_MUNMAP, (uint64_t)base + MIB2, MIB2, 0) != 0)
        fail("munmap last 2MiB");
    print("hello49: partial munmap ok\n");

    /* (d) fork — the COW clone walk demotes remaining huge blocks. */
    const int64_t child = syscall1(SYS_FORK, 0);
    if (child < 0) fail("fork");
    if (child == 0) {
        /* Read the pattern from the first (read-only) MiB. */
        for (uint64_t i = 0; i < MIB2 / 2 / PAGE; i++) {
            if (p[i * PAGE] != pattern(i)) syscall1(SYS_EXIT, 1);
        }
        for (uint64_t i = 1; i < PAGE; i++) {
            if (p[i] != pattern(i)) syscall1(SYS_EXIT, 1);
        }
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
    int64_t status = 0;
    syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);
    if (status != 0) fail("child readback after fork");
    /* Parent's own data intact after demote — boundary bytes still match the
     * pattern, except page 300 which we deliberately overwrote with 0x5A. */
    for (uint64_t i = 0; i < NPAGES / 2; i++) {
        const uint8_t want = (i == 300) ? 0x5A : pattern(i);
        if (p[i * PAGE] != want) fail("parent data after fork");
    }
    print("hello49: fork COW ok\n");

    /* (e) munmap the rest. */
    if (syscall3(SYS_MUNMAP, (uint64_t)base, MIB2, 0) != 0)
        fail("munmap rest");

    print("hello49: PASS\n");
    print("hello49 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
