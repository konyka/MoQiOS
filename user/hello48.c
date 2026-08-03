/// hello48: MAP_SHARED file-backed mmap (H1).
///
///   (a) tmpfs: parent mmaps a file MAP_SHARED|PROT_WRITE and forks; the
///       child writes through its inherited mapping, and the parent reads
///       the child's bytes through its own mapping afterwards — shared
///       visibility with no syscalls in between (demand-faulted on both
///       sides AFTER the fork, so the test also covers the fork path).
///   (b) ext2: create/extend /h48_shared.dat, MAP_SHARED|PROT_WRITE it,
///       write a pattern through the mapping, msync, then pread through a
///       separate fd and verify the pattern landed on disk.
///   (c) ramdisk: MAP_SHARED|PROT_WRITE must fail with EROFS (-30);
///       MAP_SHARED read-only is allowed and serves the file's bytes.

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
#define SYS_MSYNC   26
#define SYS_FORK    57

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_SHARED    0x01
#define MS_SYNC       0x4
#define O_RDONLY      0x0
#define O_RDWR_CREAT_TRUNC 0x242 /* O_RDWR | O_CREAT | O_TRUNC */
#define PAGE          4096
#define EROFS         30

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello48: FAIL (");
    print(why);
    print(")\nhello48 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static uint8_t seed_pattern(uint64_t i) {
    return (uint8_t)((i * 13 + 3) & 0xFF);
}

static uint8_t child_pattern(uint64_t i) {
    return (uint8_t)(0xA0 + (i & 0x3F));
}

static uint8_t disk_pattern(uint64_t i) {
    return (uint8_t)((i * 7 + 0x55) & 0xFF);
}

/* (a) tmpfs shared visibility across fork. */
static void test_tmpfs_shared(void) {
    static uint8_t buf[PAGE];
    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/h48.dat", O_RDWR_CREAT_TRUNC, 0);
    if (fd < 0) fail("tmpfs open");
    for (uint64_t i = 0; i < PAGE; i++) buf[i] = seed_pattern(i);
    if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)buf, PAGE) != PAGE)
        fail("tmpfs seed write");

    const int64_t base = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, (uint64_t)fd, 0);
    if (base <= 0) fail("tmpfs MAP_SHARED mmap");
    syscall1(SYS_CLOSE, (uint64_t)fd); /* mapping must not need the fd */

    volatile uint8_t *p = (volatile uint8_t *)base;

    const int64_t child = syscall1(SYS_FORK, 0);
    if (child < 0) fail("fork");
    if (child == 0) {
        /* First touch is in the child: demand fault must hand it the shared
           tmpfs frame, writable, with no COW copy. */
        for (uint64_t i = 0; i < 256; i++) p[i] = child_pattern(i);
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
    int64_t status = 0;
    syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);
    if (status != 0) fail("child exit status");

    /* Parent's own mapping (its first touch too) must show the child's
       writes — pure shared-memory visibility, no msync/read in between. */
    for (uint64_t i = 0; i < 256; i++) {
        if (p[i] != child_pattern(i)) fail("tmpfs shared write not visible");
    }
    /* ...and the bytes the child did not touch must still be the seed. */
    for (uint64_t i = 256; i < 512; i++) {
        if (p[i] != seed_pattern(i)) fail("tmpfs seed bytes corrupted");
    }

    if (syscall3(SYS_MUNMAP, (uint64_t)base, PAGE, 0) != 0) fail("tmpfs munmap");
    print("hello48: tmpfs shared ok\n");
}

/* (b) ext2 shared write-through to disk. */
static void test_ext2_shared(void) {
    static uint8_t buf[PAGE];
    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/h48_shared.dat", O_RDWR_CREAT_TRUNC, 0);
    if (fd < 0) fail("ext2 open");
    for (uint64_t i = 0; i < PAGE; i++) buf[i] = seed_pattern(i);
    if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)buf, PAGE) != PAGE)
        fail("ext2 seed write");

    const int64_t base = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, (uint64_t)fd, 0);
    if (base <= 0) fail("ext2 MAP_SHARED mmap");
    syscall1(SYS_CLOSE, (uint64_t)fd); /* the fault path must survive close */

    /* Verify the seed came through the mapping (demand fault), then
       overwrite the whole page through the mapping. */
    volatile uint8_t *p = (volatile uint8_t *)base;
    for (uint64_t i = 0; i < 64; i++) {
        if (p[i] != seed_pattern(i)) fail("ext2 seed readback via mapping");
    }
    for (uint64_t i = 0; i < PAGE; i++) p[i] = disk_pattern(i);

    if (syscall3(SYS_MSYNC, (uint64_t)base, PAGE, MS_SYNC) != 0)
        fail("msync");
    if (syscall3(SYS_MUNMAP, (uint64_t)base, PAGE, 0) != 0)
        fail("ext2 munmap");

    /* A separate fd must see the pattern — i.e. it reached the disk. */
    const int64_t vfd = syscall3(SYS_OPEN, (uint64_t)"/h48_shared.dat", O_RDONLY, 0);
    if (vfd < 0) fail("ext2 reopen");
    if (syscall4(SYS_PREAD, (uint64_t)vfd, (uint64_t)buf, PAGE, 0) != PAGE)
        fail("pread");
    for (uint64_t i = 0; i < PAGE; i++) {
        if (buf[i] != disk_pattern(i)) fail("ext2 shared write not on disk");
    }
    syscall1(SYS_CLOSE, (uint64_t)vfd);
    print("hello48: ext2 shared ok\n");
}

/* (c) ramdisk: writable shared → EROFS; read-only shared works. */
static void test_ramdisk_shared(void) {
    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)"hello2", O_RDONLY, 0);
    if (fd < 0) fail("ramdisk open hello2");

    const int64_t bad = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, (uint64_t)fd, 0);
    if (bad != -EROFS) fail("ramdisk MAP_SHARED|PROT_WRITE not EROFS");

    const int64_t base = syscall6(SYS_MMAP, 0, PAGE, PROT_READ,
                                  MAP_SHARED, (uint64_t)fd, 0);
    if (base <= 0) fail("ramdisk MAP_SHARED read-only mmap");
    volatile uint8_t b = *((volatile uint8_t *)base); /* must not fault */
    (void)b;
    if (syscall3(SYS_MUNMAP, (uint64_t)base, PAGE, 0) != 0)
        fail("ramdisk munmap");

    syscall1(SYS_CLOSE, (uint64_t)fd);
    print("hello48: ramdisk EROFS ok\n");
}

void _start(void) {
    print("hello48: MAP_SHARED file mmap test\n");

    test_tmpfs_shared();
    test_ext2_shared();
    test_ramdisk_shared();

    print("hello48: PASS\n");
    print("hello48 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
