/// hello29: getdents64 short-buffer test
///
/// Reads the same directory twice: once with a buffer large enough to take
/// every entry in one call, then with a buffer that holds only one entry per
/// call. Both must report the same number of entries.
///
/// The regression this guards: the resume offset was taken from the last entry
/// the filesystem *produced* rather than the last one actually copied out, so
/// every entry that did not fit was skipped and the short-buffer walk silently
/// returned a shorter directory.
///
/// Only tmpfs directories are reachable: the VFS has no path that hands back a
/// descriptor for an ext2 directory, so the ext2 arm of getdents64 cannot be
/// exercised from user space yet.

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

#define SYS_WRITE      1
#define SYS_EXIT       2
#define SYS_OPEN       9
#define SYS_CLOSE      11
#define SYS_GETDENTS64 173

#define DIR_PATH "/tmp"
#define NFILES   6
#define BIG_BUF  512
#define SMALL_BUF 48

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

/// Walk DIR_PATH with `bufsz`-byte reads, returning the entry count or -1.
static int64_t count_entries(uint64_t bufsz) {
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)DIR_PATH, 0, 0);
    if (fd < 0) return -1;

    char buf[BIG_BUF];
    int64_t total = 0;
    /// Bounded so a broken resume offset cannot hang the smoke run.
    for (int round = 0; round < 100; round++) {
        int64_t n = syscall3(SYS_GETDENTS64, (uint64_t)fd, (uint64_t)buf, bufsz);
        if (n <= 0) break;

        int64_t off = 0;
        while (off + 19 <= n) {
            int reclen = (unsigned char)buf[off + 16] | ((unsigned char)buf[off + 17] << 8);
            if (reclen <= 0) break;
            total++;
            off += reclen;
        }
    }

    syscall1(SYS_CLOSE, (uint64_t)fd);
    return total;
}

void _start(void) {
    print("hello29: getdents64 short-buffer test\n");

    /// Distinct names, built in place to keep the program free of pointer
    /// tables. Enough entries that SMALL_BUF needs several rounds.
    char path[] = DIR_PATH "/gd_x.txt";
    const int tag = sizeof(DIR_PATH "/gd_") - 1;
    int created = 0;
    for (int i = 0; i < NFILES; i++) {
        path[tag] = (char)('a' + i);
        int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, 0x41, 0);
        if (fd >= 0) {
            created++;
            syscall1(SYS_CLOSE, (uint64_t)fd);
        }
    }
    print("hello29: created=");
    print_dec(created);
    print("\n");

    int64_t big = count_entries(BIG_BUF);
    print("hello29: entries(");
    print_dec(BIG_BUF);
    print(")=");
    print_dec(big);
    print("\n");

    int64_t small = count_entries(SMALL_BUF);
    print("hello29: entries(");
    print_dec(SMALL_BUF);
    print(")=");
    print_dec(small);
    print("\n");

    if (big <= 0) {
        print("hello29: SKIP (no readable directory)\n");
    } else if (small == big) {
        print("hello29: PASS (short buffer returned every entry)\n");
    } else {
        print("hello29: FAIL (short buffer dropped entries)\n");
    }

    print("hello29 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
