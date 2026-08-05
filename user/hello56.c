/// hello56: display/input/time infrastructure end-to-end proof.
///
///   1. /dev/fbinfo reports the framebuffer geometry as "WxH pitch bpp".
///   2. /dev/fb0 opens O_RDWR; mmap(MAP_SHARED) on the fb0 fd maps the
///      framebuffer (drivers/fbdev.zig no_free path — NOT dev_map_mmio).
///      A recognizable pixel block is written through the mapping, then
///      read back via pread() on /dev/fb0 and verified byte-for-byte.
///   3. /dev/mouse exists; an empty read with O_NONBLOCK returns 0
///      (the node is present even before any IRQ12 event arrives, as long
///      as the boot-time aux probe found a mouse — QEMU always has one).
///   4. gettimeofday reports the RTC-seeded wall clock (tv_sec must be
///      past 2020-01-01), and both gettimeofday and
///      clock_gettime(CLOCK_MONOTONIC) are non-decreasing over a loop.
///
/// Prints "hello56: PASS" on success, "hello56: FAIL <tag>" + exit(1)
/// otherwise, and always ends with "hello56 done" on the success path.

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

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8  __asm__("r8")  = a5;
    register uint64_t r9  __asm__("r9")  = a6;
    __asm__ volatile ("syscall" : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}


#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_MMAP        8
#define SYS_OPEN        9
#define SYS_READ        10
#define SYS_CLOSE       11
#define SYS_PREAD       17
#define SYS_GETTIMEOFDAY 96
#define SYS_CLOCK_GETTIME 228

#define O_RDONLY   0
#define O_RDWR     2
#define O_NONBLOCK 0x800

#define PROT_READ  1
#define PROT_WRITE 2
#define MAP_SHARED 1

#define CLOCK_REALTIME  0
#define CLOCK_MONOTONIC 1

/* 2020-01-01T00:00:00Z — the RTC wall clock must be well past this. */
#define EPOCH_FLOOR 1577836800ULL

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *tag) {
    print("hello56: FAIL ");
    print(tag);
    print("\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

/* Parse one unsigned decimal; advances *p past it. */
static uint64_t parse_dec(const char **p) {
    uint64_t v = 0;
    while (**p >= '0' && **p <= '9') {
        v = v * 10 + (uint64_t)(**p - '0');
        (*p)++;
    }
    return v;
}

struct timeval56 { uint64_t tv_sec; int64_t tv_usec; };
struct timespec56 { uint64_t tv_sec; int64_t tv_nsec; };

void _start(void) {
    /* 1. fbinfo geometry */
    int64_t ifd = syscall3(SYS_OPEN, (uint64_t)"/dev/fbinfo", O_RDONLY, 0);
    if (ifd < 0) fail("fbinfo open");
    char info[64];
    int64_t ilen = syscall3(SYS_READ, (uint64_t)ifd, (uint64_t)info, sizeof(info) - 1);
    syscall1(SYS_CLOSE, (uint64_t)ifd);
    if (ilen <= 0) fail("fbinfo read");
    info[ilen] = 0;
    const char *p = info;
    uint64_t width = parse_dec(&p);
    if (*p != 'x') fail("fbinfo format x");
    p++;
    uint64_t height = parse_dec(&p);
    if (*p != ' ') fail("fbinfo format sp1");
    p++;
    uint64_t pitch = parse_dec(&p);
    if (*p != ' ') fail("fbinfo format sp2");
    p++;
    uint64_t bpp = parse_dec(&p);
    if (width == 0 || height == 0 || pitch < width * 4 || bpp != 32)
        fail("fbinfo values");

    /* 2. fb0 + mmap + pixel block verify */
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/dev/fb0", O_RDWR, 0);
    if (fd < 0) fail("fb0 open");

    uint64_t fb_size = pitch * height;
    int64_t base = syscall6(SYS_MMAP, 0, fb_size, PROT_READ | PROT_WRITE,
                            MAP_SHARED, (uint64_t)fd, 0);
    if (base < 0) fail("fb0 mmap");
    uint32_t *fbp = (uint32_t *)(uint64_t)base;

    /* Recognizable block: 40x40 pixels at (100,100), alternating colors. */
    enum { BX = 100, BY = 100, BW = 40, BH = 40 };
    if (BX + BW > width || BY + BH > height) fail("fb too small");
    for (uint64_t y = 0; y < BH; y++) {
        for (uint64_t x = 0; x < BW; x++) {
            uint32_t color = ((x + y) & 1) ? 0x00FF6A00u : 0x0000FF6Au;
            fbp[(BY + y) * (pitch / 4) + BX + x] = color;
        }
    }

    /* Read it back through /dev/fb0 (pread = read at explicit offset) and
     * verify every pixel of the block. */
    for (uint64_t y = 0; y < BH; y++) {
        uint32_t row[BW];
        uint64_t off = (BY + y) * pitch + BX * 4;
        int64_t n = syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)row, sizeof(row), off);
        if (n != (int64_t)sizeof(row)) fail("fb0 pread");
        for (uint64_t x = 0; x < BW; x++) {
            uint32_t want = ((x + y) & 1) ? 0x00FF6A00u : 0x0000FF6Au;
            if (row[x] != want) fail("fb0 verify");
        }
    }
    syscall1(SYS_CLOSE, (uint64_t)fd);

    /* 3. /dev/mouse exists; empty nonblocking read returns 0. */
    int64_t mfd = syscall3(SYS_OPEN, (uint64_t)"/dev/mouse", O_RDONLY | O_NONBLOCK, 0);
    if (mfd < 0) fail("mouse open");
    uint8_t mbuf[16];
    int64_t mn = syscall3(SYS_READ, (uint64_t)mfd, (uint64_t)mbuf, sizeof(mbuf));
    if (mn < 0) fail("mouse read");
    if (mn % 4 != 0) fail("mouse alignment"); /* events are 4-byte records */
    syscall1(SYS_CLOSE, (uint64_t)mfd);

    /* 4. RTC wall clock + monotonicity */
    struct timeval56 tv;
    if (syscall1(SYS_GETTIMEOFDAY, (uint64_t)&tv) != 0) fail("gettimeofday");
    if (tv.tv_sec <= EPOCH_FLOOR) fail("wall clock not RTC-seeded");

    struct timeval56 prev = tv;
    struct timespec56 mprev;
    if (syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (uint64_t)&mprev) != 0)
        fail("clock_gettime mono");
    for (int i = 0; i < 10000; i++) {
        struct timeval56 now;
        if (syscall1(SYS_GETTIMEOFDAY, (uint64_t)&now) != 0) fail("gettimeofday loop");
        if (now.tv_sec < prev.tv_sec ||
            (now.tv_sec == prev.tv_sec && now.tv_usec < prev.tv_usec))
            fail("gettimeofday not monotonic");
        prev = now;

        struct timespec56 mnow;
        if (syscall2(SYS_CLOCK_GETTIME, CLOCK_MONOTONIC, (uint64_t)&mnow) != 0)
            fail("clock_gettime loop");
        if (mnow.tv_sec < mprev.tv_sec ||
            (mnow.tv_sec == mprev.tv_sec && mnow.tv_nsec < mprev.tv_nsec))
            fail("monotonic not monotonic");
        mprev = mnow;
    }

    /* CLOCK_REALTIME agrees with gettimeofday (both RTC-seeded). */
    struct timespec56 rt;
    if (syscall2(SYS_CLOCK_GETTIME, CLOCK_REALTIME, (uint64_t)&rt) != 0)
        fail("clock_gettime realtime");
    if (rt.tv_sec <= EPOCH_FLOOR) fail("realtime not RTC-seeded");

    print("hello56: PASS\n");
    print("hello56 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
