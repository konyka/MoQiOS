/// hello46: file-backed mmap (MAP_PRIVATE) with demand paging (G2).
///
/// Writes a known pattern to /tmp (tmpfs), mmaps it MAP_PRIVATE, then checks:
///   1. Contents are served correctly on demand — after close(fd), proving
///      the mapping does not depend on the descriptor staying open.
///   2. The tail of the last partial page is zero-filled.
///   3. Writes through the mapping are private: pread shows the file itself
///      unchanged (COW on the shared backing frame).
///   4. In a forked child (which inherits the region metadata but no faulted
///      pages), a never-touched page demand-faults correctly from the file,
///      and a whole page past EOF raises SIGSEGV (waitpid status 139).

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

static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
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

#define SYS_WRITE   1
#define SYS_EXIT    2
#define SYS_WAITPID 6
#define SYS_MMAP    8
#define SYS_OPEN    9
#define SYS_CLOSE   11
#define SYS_MUNMAP  12
#define SYS_PREAD   17
#define SYS_FORK    57

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define O_RDWR_CREAT_TRUNC 0x242 /* O_RDWR | O_CREAT | O_TRUNC */
#define O_RDONLY      0x0
#define PAGE          4096

/* 2.5 pages: pages 0-1 full, page 2 partial (1808 bytes), page 3 wholly EOF. */
#define FILE_LEN 10000
#define MAP_LEN  (4 * PAGE)

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello46: FAIL (");
    print(why);
    print(")\nhello46 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static uint8_t pattern(uint64_t i) {
    return (uint8_t)((i * 31 + 7) & 0xFF);
}

static void make_file(void) {
    static uint8_t buf[PAGE];
    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/h46.dat", O_RDWR_CREAT_TRUNC, 0);
    if (fd < 0) fail("open for write");
    uint64_t done = 0;
    while (done < FILE_LEN) {
        uint64_t chunk = FILE_LEN - done;
        if (chunk > PAGE) chunk = PAGE;
        for (uint64_t i = 0; i < chunk; i++) buf[i] = pattern(done + i);
        if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)buf, chunk) != (int64_t)chunk)
            fail("write pattern");
        done += chunk;
    }
    syscall1(SYS_CLOSE, (uint64_t)fd);
}

void _start(void) {
    print("hello46: file-backed mmap (MAP_PRIVATE) test\n");

    make_file();

    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/h46.dat", O_RDONLY, 0);
    if (fd < 0) fail("open for mmap");

    const int64_t base = syscall6(SYS_MMAP, 0, MAP_LEN, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE, (uint64_t)fd, 0);
    if (base <= 0) fail("mmap");

    /* The mapping must not depend on the descriptor staying open. */
    syscall1(SYS_CLOSE, (uint64_t)fd);

    volatile uint8_t *p = (volatile uint8_t *)base;

    /* 1. Demand-paged contents: page 0 fully, plus the partial page 2.
          Page 1 is deliberately left untouched for the child's fault test. */
    for (uint64_t i = 0; i < PAGE; i++) {
        if (p[i] != pattern(i)) fail("page 0 contents");
    }
    for (uint64_t i = 2 * PAGE; i < FILE_LEN; i++) {
        if (p[i] != pattern(i)) fail("page 2 contents");
    }

    /* 2. Tail of the last partial page must be zero-filled. */
    for (uint64_t i = FILE_LEN; i < 3 * PAGE; i++) {
        if (p[i] != 0) fail("EOF tail not zeroed");
    }

    /* 3. Writes through the mapping are private (COW), file stays unchanged. */
    p[0] = 0xAA;
    p[9000] = 0xBB;
    p[FILE_LEN - 1] = 0xCC;

    const int64_t vfd = syscall3(SYS_OPEN, (uint64_t)"/tmp/h46.dat", O_RDONLY, 0);
    if (vfd < 0) fail("open for pread");
    uint8_t check[16];
    if (syscall4(SYS_PREAD, (uint64_t)vfd, (uint64_t)check, 16, 0) != 16)
        fail("pread head");
    for (uint64_t i = 0; i < 16; i++) {
        if (check[i] != pattern(i)) fail("file changed by MAP_PRIVATE write (head)");
    }
    if (syscall4(SYS_PREAD, (uint64_t)vfd, (uint64_t)check, 4, 9000) != 4)
        fail("pread mid");
    if (check[0] != pattern(9000)) fail("file changed by MAP_PRIVATE write (mid)");
    /* One byte before EOF a 4-byte read must come back short (1 byte). */
    if (syscall4(SYS_PREAD, (uint64_t)vfd, (uint64_t)check, 4, FILE_LEN - 1) != 1)
        fail("pread tail");
    if (check[0] != pattern(FILE_LEN - 1)) fail("file changed by MAP_PRIVATE write (tail)");
    syscall1(SYS_CLOSE, (uint64_t)vfd);

    /* ...but the mapping itself must show the private writes. */
    if (p[0] != 0xAA || p[9000] != 0xBB || p[FILE_LEN - 1] != 0xCC)
        fail("private writes not visible through mapping");

    /* 4. Child: demand fault on the page the parent never touched (page 1),
          then SIGSEGV on a whole page past EOF (page 3). */
    const int64_t child = syscall1(SYS_FORK, 0);
    if (child < 0) fail("fork");
    if (child == 0) {
        for (uint64_t i = PAGE; i < 2 * PAGE; i++) {
            if (p[i] != pattern(i)) syscall1(SYS_EXIT, 1);
        }
        p[3 * PAGE] = 0xFF; /* whole page past EOF — must SIGSEGV */
        syscall1(SYS_EXIT, 1); /* reached only if the fault was not delivered */
        for (;;) {}
    }
    int64_t status = 0;
    syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);
    if (status == 1) fail("child demand fault on inherited region");
    if (status != 139) fail("past-EOF page did not SIGSEGV");

    if (syscall3(SYS_MUNMAP, (uint64_t)base, MAP_LEN, 0) != 0) fail("munmap");

    print("hello46: PASS (file mmap demand paging, COW, EOF SIGSEGV)\n");
    print("hello46 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
