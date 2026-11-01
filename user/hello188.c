/// hello188: mmap / munmap / mprotect / madvise / msync / mincore / mlock / mremap errnos, checked against real Linux.
/// Only the errno (or success) is compared: a successful mmap returns an address, which is normalised to 0.

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
#define SYS_MMAP      8
#define SYS_OPEN      9
#define SYS_CLOSE     11
#define SYS_MUNMAP    12
#define SYS_PIPE      22
#define SYS_MREMAP    25
#define SYS_SOCKETPAIR 53
#define SYS_UNLINK    87
#define SYS_MPROTECT  164
#define SYS_FTRUNCATE 211
#define SYS_MADVISE   235
#define SYS_MINCORE   251
#define SYS_MLOCK     252
#define SYS_MUNLOCK   253
#define SYS_MSYNC     254
#define SYS_MLOCKALL  271
#define SYS_MUNLOCKALL 272
#define SYS_EPOLL_CREATE1 146
#define SYS_EVENTFD2  169
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2
#define O_CREAT  0x40
#define O_DIRECTORY 0x10000

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello188:   ok   " : "hello188:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void print_num(int64_t x) {
    char r[24]; int m = 0; char o[40]; int k = 0;
    if (x < 0) { o[k++] = '-'; x = -x; }
    if (x == 0) r[m++] = '0';
    while (x > 0) { r[m++] = '0' + x % 10; x /= 10; }
    while (m > 0) o[k++] = r[--m];
    o[k++] = '\n'; o[k] = 0;
    print(o);
}

/* A successful call is 0; a failure is -errno. */
static int64_t norm(int64_t r) { return (r < 0 && r > -4096) ? r : 0; }
static int64_t MMAP(uint64_t a, uint64_t l, int64_t p, int64_t f, int64_t fd, int64_t o) {
    return norm(syscall6(SYS_MMAP, a, l, (uint64_t)p, (uint64_t)f, (uint64_t)fd, (uint64_t)o));
}
static int64_t MUNMAP(uint64_t a, uint64_t l) { return norm(syscall2(SYS_MUNMAP, a, l)); }
static int64_t MPROTECT(uint64_t a, uint64_t l, int64_t p) { return norm(syscall3(SYS_MPROTECT, a, l, (uint64_t)p)); }
static int64_t MADVISE(uint64_t a, uint64_t l, int64_t v) { return norm(syscall3(SYS_MADVISE, a, l, (uint64_t)v)); }
static int64_t MSYNC(uint64_t a, uint64_t l, int64_t f) { return norm(syscall3(SYS_MSYNC, a, l, (uint64_t)f)); }
static int64_t MINCORE(uint64_t a, uint64_t l, const void *v) { return norm(syscall3(SYS_MINCORE, a, l, (uint64_t)v)); }
static int64_t MLOCK(uint64_t a, uint64_t l) { return norm(syscall2(SYS_MLOCK, a, l)); }
static int64_t MUNLOCK(uint64_t a, uint64_t l) { return norm(syscall2(SYS_MUNLOCK, a, l)); }
static int64_t MLOCKALL(int64_t f) { return norm(syscall1(SYS_MLOCKALL, (uint64_t)f)); }
static int64_t MUNLOCKALL(void) { return norm(syscall1(SYS_MUNLOCKALL, 0)); }
static int64_t MREMAP(uint64_t a, uint64_t o, uint64_t n, int64_t f, uint64_t na) {
    return norm(syscall5(SYS_MREMAP, a, o, n, (uint64_t)f, na));
}

/* Return values from real Linux, in the order of the table in _start. */
static const int64_t EXPECT[] = {
-22, -22, -22, 0, 0, 0, 0, 0, -9, 0, 0, -13, 0, 0, -13, -13, -22, -75, -13, -19, -19, -19, -19, -19, 0, -12, -12, -12, -22, -12, -12, -17, -17, 0, 0, 0, 0, 0, 0, -22, -22, -22, 0, 0, -22, -22, -22, 0, 0, -22, -12, -12, -22, -22, -12, -12, -13, 0, 0, 0, 0, -22, -22, -12, -12, -12, 0, 0, -12, -22, 0, -22, -22, -22, -22, 0, -12, 0, 0, 0, 0, -22, -12, -14, 0, 0, 0, -12, -12, 0, -22, -22, -22, 0, -22, -14, -22, -22, 0, -22, -22, -22
};
static int idx = 0;
#define T(label, expr) do { \
        int64_t v_ = (expr); \
        if (v_ != EXPECT[idx]) { print("hello188:   got "); print_num(v_); } \
        check(v_ == EXPECT[idx], label); idx++; \
    } while (0)

void _start(void) {
    print("hello188: memory-management errno conformance (expected values from real Linux)\n");
    const char *F = "/tmp/h188f";
    syscall1(SYS_UNLINK, (uint64_t)F);
    int32_t pp[2] = { -1, -1 }, sv[2] = { -1, -1 };
    syscall1(SYS_PIPE, (uint64_t)pp);
    int64_t p0 = pp[0];
    int64_t rf = syscall3(SYS_OPEN, (uint64_t)F, O_CREAT | O_RDWR, 0644);
    syscall2(SYS_FTRUNCATE, (uint64_t)rf, 8192);
    int64_t ro = syscall3(SYS_OPEN, (uint64_t)F, O_RDONLY, 0);
    int64_t wo = syscall3(SYS_OPEN, (uint64_t)F, O_WRONLY, 0);
    int64_t dir = syscall3(SYS_OPEN, (uint64_t)"/tmp", O_RDONLY | O_DIRECTORY, 0);
    syscall4(SYS_SOCKETPAIR, 1, 1, 0, (uint64_t)sv);
    int64_t sv0 = sv[0];
    int64_t efd = syscall2(SYS_EVENTFD2, 0, 0);
    int64_t ep = syscall1(SYS_EPOLL_CREATE1, 0);
    int64_t nul = syscall3(SYS_OPEN, (uint64_t)"/dev/null", O_RDWR, 0);
    uint64_t base = (uint64_t)syscall6(SYS_MMAP, 0x200000000ULL, 0x400000, 3, 0x32, (uint64_t)-1, 0);
    uint64_t romap = (uint64_t)syscall6(SYS_MMAP, 0, 4096, 1, 0x01, (uint64_t)ro, 0);
    uint64_t romap_priv = (uint64_t)syscall6(SYS_MMAP, 0, 4096, 1, 0x02, (uint64_t)ro, 0);
    static unsigned char vec[16];
    check(base == 0x200000000ULL && romap < (uint64_t)-4096 && romap_priv < (uint64_t)-4096 && p0 >= 0 && rf >= 0 && ro >= 0 && wo >= 0 && dir >= 0 && sv0 >= 0 && efd >= 0 && ep >= 0 && nul >= 0, "setup: descriptors and mappings");
    T("mmap: len 0", MMAP(0, 0, 3, 0x22, -1, 0));
    T("mmap: anon with neither SHARED nor PRIVATE", MMAP(0, 4096, 3, 0x20, -1, 0));
    T("mmap: anon with both SHARED and PRIVATE", MMAP(0, 4096, 3, 0x23, -1, 0));
    T("mmap: anon private", MMAP(0, 4096, 3, 0x22, -1, 0));
    T("mmap: anon shared", MMAP(0, 4096, 3, 0x21, -1, 0));
    T("mmap: anon PROT_NONE", MMAP(0, 4096, 0, 0x22, -1, 0));
    T("mmap: unknown prot bits", MMAP(0, 4096, 0x100, 0x22, -1, 0));
    T("mmap: PROT_GROWSDOWN", MMAP(0, 4096, 3 | 0x01000000, 0x22, -1, 0));
    T("mmap: bad fd", MMAP(0, 4096, 3, 0x02, 99, 0));
    T("mmap: file private", MMAP(0, 4096, 3, 0x02, rf, 0));
    T("mmap: file shared rw on rdwr file", MMAP(0, 4096, 3, 0x01, rf, 0));
    T("mmap: file shared rw on rdonly file", MMAP(0, 4096, 3, 0x01, ro, 0));
    T("mmap: file private rw on rdonly file", MMAP(0, 4096, 3, 0x02, ro, 0));
    T("mmap: file shared read on rdonly file", MMAP(0, 4096, 1, 0x01, ro, 0));
    T("mmap: file shared rw on wronly file", MMAP(0, 4096, 3, 0x01, wo, 0));
    T("mmap: file private read on wronly file", MMAP(0, 4096, 1, 0x02, wo, 0));
    T("mmap: file offset not page aligned", MMAP(0, 4096, 3, 0x02, rf, 100));
    T("mmap: file negative offset", MMAP(0, 4096, 3, 0x02, rf, -4096));
    T("mmap: directory", MMAP(0, 4096, 1, 0x02, dir, 0));
    T("mmap: pipe", MMAP(0, 4096, 1, 0x02, p0, 0));
    T("mmap: socket", MMAP(0, 4096, 1, 0x02, sv0, 0));
    T("mmap: eventfd", MMAP(0, 4096, 1, 0x02, efd, 0));
    T("mmap: epoll", MMAP(0, 4096, 1, 0x02, ep, 0));
    T("mmap: /dev/null", MMAP(0, 4096, 1, 0x02, nul, 0));
    T("mmap: past end of file", MMAP(0, 4096, 1, 0x02, rf, 1 << 20));
    T("mmap: huge length", MMAP(0, 0x7fffffffffff0000UL, 3, 0x22, -1, 0));
    T("mmap: length overflowing", MMAP(0, -1UL, 3, 0x22, -1, 0));
    T("mmap: length -4096", MMAP(0, -4096UL, 3, 0x22, -1, 0));
    T("mmap: MAP_FIXED unaligned", MMAP(0x10000001, 4096, 3, 0x32, -1, 0));
    T("mmap: MAP_FIXED kernel address", MMAP(0xffff800000000000UL, 4096, 3, 0x32, -1, 0));
    T("mmap: MAP_FIXED beyond user space", MMAP(0x7ffffffff000UL, 8192, 3, 0x32, -1, 0));
    T("mmap: MAP_FIXED_NOREPLACE over a mapping", MMAP(base, 4096, 3, 0x100022, -1, 0));
    T("mmap: MAP_FIXED_NOREPLACE free", MMAP(base + 0x100000, 4096, 3, 0x100022, -1, 0));
    T("mmap: MAP_FIXED over a mapping", MMAP(base, 4096, 3, 0x32, -1, 0));
    T("mmap: MAP_GROWSDOWN", MMAP(0, 4096, 3, 0x122, -1, 0));
    T("mmap: MAP_STACK", MMAP(0, 4096, 3, 0x20022, -1, 0));
    T("mmap: MAP_POPULATE", MMAP(0, 4096, 3, 0x8022, -1, 0));
    T("mmap: MAP_NORESERVE", MMAP(0, 4096, 3, 0x4022, -1, 0));
    T("mmap: anon with an fd and offset (MAP_ANON ignores them)", MMAP(0, 4096, 3, 0x22, rf, 4096));
    T("mmap: anon with unaligned offset", MMAP(0, 4096, 3, 0x22, -1, 100));
    T("munmap: len 0", MUNMAP(base, 0));
    T("munmap: unaligned address", MUNMAP(base + 1, 4096));
    T("munmap: unaligned length is rounded up", MUNMAP(base + 0x200000, 1));
    T("munmap: unmapped range", MUNMAP(0x30000000, 4096));
    T("munmap: kernel address", MUNMAP(0xffff800000000000UL, 4096));
    T("munmap: beyond user space", MUNMAP(0x7ffffffff000UL, 8192));
    T("munmap: length overflowing", MUNMAP(base, -1UL));
    T("munmap: address 0", MUNMAP(0, 4096));
    T("mprotect: len 0", MPROTECT(base, 0, 1));
    T("mprotect: unaligned address", MPROTECT(base + 1, 4096, 1));
    T("mprotect: unmapped range", MPROTECT(0x30000000, 4096, 1));
    T("mprotect: partly unmapped range", MPROTECT(base, 0x1000000, 1));
    T("mprotect: unknown prot bits", MPROTECT(base, 4096, 0x100));
    T("mprotect: PROT_GROWSDOWN|PROT_GROWSUP", MPROTECT(base, 4096, 0x03000001));
    T("mprotect: kernel address", MPROTECT(0xffff800000000000UL, 4096, 1));
    T("mprotect: length overflowing", MPROTECT(base, -1UL, 1));
    T("mprotect: shared read-only file to writable", MPROTECT(romap, 4096, 3));
    T("mprotect: private read-only file to writable", MPROTECT(romap_priv, 4096, 3));
    T("mprotect: valid", MPROTECT(base, 4096, 1));
    T("mprotect: PROT_NONE", MPROTECT(base, 4096, 0));
    T("madvise: len 0", MADVISE(base, 0, 4));
    T("madvise: unaligned address", MADVISE(base + 1, 4096, 4));
    T("madvise: unknown advice", MADVISE(base, 4096, 9999));
    T("madvise: unmapped range DONTNEED", MADVISE(0x30000000, 4096, 4));
    T("madvise: unmapped range WILLNEED", MADVISE(0x30000000, 4096, 3));
    T("madvise: unmapped range NORMAL", MADVISE(0x30000000, 4096, 0));
    T("madvise: DONTNEED valid", MADVISE(base, 4096, 4));
    T("madvise: NORMAL valid", MADVISE(base, 4096, 0));
    T("madvise: kernel address", MADVISE(0xffff800000000000UL, 4096, 4));
    T("madvise: length overflowing", MADVISE(base, -1UL, 4));
    T("madvise: MADV_FREE on private anon", MADVISE(base, 4096, 8));
    T("madvise: MADV_REMOVE on private anon", MADVISE(base, 4096, 9));
    T("msync: unaligned address", MSYNC(base + 1, 4096, 4));
    T("msync: both SYNC and ASYNC", MSYNC(base, 4096, 1 | 4));
    T("msync: unknown flag", MSYNC(base, 4096, 8));
    T("msync: no flags", MSYNC(base, 4096, 0));
    T("msync: unmapped range", MSYNC(0x30000000, 4096, 4));
    T("msync: len 0", MSYNC(base, 0, 4));
    T("msync: valid", MSYNC(base, 4096, 4));
    T("msync: ASYNC valid", MSYNC(base, 4096, 1));
    T("msync: INVALIDATE valid", MSYNC(base, 4096, 2));
    T("mincore: unaligned address", MINCORE(base + 1, 4096, vec));
    T("mincore: unmapped range", MINCORE(0x30000000, 4096, vec));
    T("mincore: bad vec", MINCORE(base, 4096, (void*)8));
    T("mincore: len 0", MINCORE(base, 0, vec));
    T("mincore: valid", MINCORE(base, 4096, vec));
    T("mlock: len 0", MLOCK(base, 0));
    T("mlock: unmapped range", MLOCK(0x30000000, 4096));
    T("munlock: unmapped range", MUNLOCK(0x30000000, 4096));
    T("munlock: valid", MUNLOCK(base, 4096));
    T("mlockall: no flags", MLOCKALL(0));
    T("mlockall: unknown flag", MLOCKALL(8));
    T("mlockall: MCL_ONFAULT only", MLOCKALL(4));
    T("munlockall", MUNLOCKALL());
    T("mremap: bad old address", MREMAP(base + 1, 4096, 8192, 0, 0));
    T("mremap: unmapped old range", MREMAP(0x30000000, 4096, 8192, 0, 0));
    T("mremap: new size 0", MREMAP(base, 4096, 0, 0, 0));
    T("mremap: unknown flag", MREMAP(base, 4096, 8192, 8, 0));
    T("mremap: MAYMOVE shrink", MREMAP(base, 8192, 4096, 1, 0));
    T("mremap: FIXED without MAYMOVE", MREMAP(base, 4096, 4096, 2, base + 0x400000));
    T("mremap: old size 0 on private", MREMAP(base, 0, 4096, 1, 0));
    T("mremap: new size overflowing", MREMAP(base, 4096, -1UL, 1, 0));
    check(idx == (int)(sizeof(EXPECT) / sizeof(EXPECT[0])), "every table entry was exercised");

    syscall1(SYS_UNLINK, (uint64_t)F);
    print(failures == 0 ? "hello188: PASS\n" : "hello188: FAIL\n");
    print("hello188 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
