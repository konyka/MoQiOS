/// hello53: devfs device-node framework end-to-end proof.
///
///   1. getdents64("/dev") enumerates every registered node:
///      null, zero, full, random, urandom, kmsg, pci, tty.
///   2. /dev/null: write reports the full count, read is instant EOF (0).
///   3. /dev/zero: read returns a fully zeroed buffer.
///   4. /dev/full: write fails with -ENOSPC.
///   5. /dev/tty: a write round-trips to the serial console (return value
///      is the byte count; the marker line is visible on the console).
///      The read-back is skipped when the arch has no console input queue
///      (-ENOTTY); on x86_64 the PS/2 keyboard ring answers, which may
///      legitimately be empty (0) under QEMU.
///
/// Prints "hello53: PASS" on success, "hello53: FAIL <tag>" + exit(1)
/// otherwise, and always ends with "hello53 done" on the success path.

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

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_OPEN        9
#define SYS_READ        10
#define SYS_CLOSE       11
#define SYS_GETDENTS64  173

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2

#define ENOSPC 28
#define ENOTTY 25

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *tag) {
    print("hello53: FAIL ");
    print(tag);
    print("\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static int str_eq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

/* linux_dirent64: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name[] */
struct dirent64 {
    uint64_t ino;
    uint64_t off;
    uint16_t reclen;
    uint8_t  type;
    char     name[];
};

static const char *const expected[] = {
    "null", "zero", "full", "random", "urandom", "kmsg", "pci", "tty",
};
#define N_EXPECTED 8

static char dent_buf[1024];

void _start(void) {
    /* ── 1. getdents64("/dev") finds every registered node ─────────── */
    int64_t dfd = syscall3(SYS_OPEN, (uint64_t)"/dev", O_RDONLY, 0);
    if (dfd < 0) fail("open /dev");

    uint32_t found = 0;
    for (;;) {
        int64_t n = syscall3(SYS_GETDENTS64, (uint64_t)dfd, (uint64_t)dent_buf, sizeof(dent_buf));
        if (n < 0) fail("getdents64 /dev");
        if (n == 0) break;
        int64_t pos = 0;
        while (pos < n) {
            const struct dirent64 *d = (const struct dirent64 *)(dent_buf + pos);
            for (int i = 0; i < N_EXPECTED; i++) {
                if (str_eq(d->name, expected[i])) found |= (uint32_t)1 << i;
            }
            if (d->reclen == 0) fail("getdents64 zero reclen");
            pos += d->reclen;
        }
    }
    syscall1(SYS_CLOSE, (uint64_t)dfd);
    if (found != (uint32_t)((1 << N_EXPECTED) - 1)) fail("getdents64 missing node");

    /* ── 2. /dev/null: write discards, read is EOF ─────────────────── */
    {
        int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/dev/null", O_RDWR, 0);
        if (fd < 0) fail("open /dev/null");
        static const char msg[] = "into the void";
        if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)msg, sizeof(msg) - 1) != (int64_t)(sizeof(msg) - 1))
            fail("write /dev/null");
        char c;
        if (syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&c, 1) != 0)
            fail("read /dev/null not EOF");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* ── 3. /dev/zero: read zero-fills the buffer ──────────────────── */
    {
        int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/dev/zero", O_RDONLY, 0);
        if (fd < 0) fail("open /dev/zero");
        uint8_t buf[32];
        for (int i = 0; i < 32; i++) buf[i] = 0xA5;
        if (syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, sizeof(buf)) != (int64_t)sizeof(buf))
            fail("read /dev/zero count");
        for (int i = 0; i < 32; i++) {
            if (buf[i] != 0) fail("read /dev/zero nonzero");
        }
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* ── 4. /dev/full: write fails with -ENOSPC ────────────────────── */
    {
        int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/dev/full", O_WRONLY, 0);
        if (fd < 0) fail("open /dev/full");
        if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"x", 1) != -ENOSPC)
            fail("write /dev/full not ENOSPC");
        char c;
        if (syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&c, 1) != 0)
            fail("read /dev/full not EOF");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    /* ── 5. /dev/tty: write reaches the console ────────────────────── */
    {
        int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/dev/tty", O_RDWR, 0);
        if (fd < 0) fail("open /dev/tty");
        static const char marker[] = "hello53: /dev/tty write visible\n";
        if (syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)marker, sizeof(marker) - 1) != (int64_t)(sizeof(marker) - 1))
            fail("write /dev/tty");
        char c;
        int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)&c, 1);
        if (n == -ENOTTY) {
            /* No console input queue on this arch — read-back skipped. */
        } else if (n < 0) {
            fail("read /dev/tty");
        }
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }

    print("hello53: PASS\n");
    print("hello53 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
