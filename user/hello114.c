/// hello114: read-only ext4 and NTFS volumes on the second virtio disk.
///
/// The disk (tests/fixtures/fs/datadisk.img, vblk1) holds an MBR with
/// p1 = ext4 and p2 = NTFS, built by tools/fsfixtures/mkfixtures.sh.
///
///   A. mount ext4 (vblk1p1) at /mnt/e and NTFS (vblk1p2) at /mnt/n
///   B. read small / large / sparse files and compare against the generator
///   C. directories: getdents64 lists every entry; nested paths; chdir
///   D. stat sizes and types, readlink, relative paths from a volume cwd
///   E. every mutating call on a volume is EROFS, write-opens too
///   F. dup'd and forked descriptors read valid data
///   G. umount: an open fd fails afterwards, a reused slot never leaks data
///   H. error cases: bad device, wrong type, double mount, missing file

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

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_OPEN      9
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_FSTAT     110
#define SYS_PREAD     136
#define SYS_DUP       160
#define SYS_GETDENTS  173
#define SYS_LSEEK     197
#define SYS_FORK      57
#define SYS_MOUNT     288
#define SYS_UMOUNT2   289
#define SYS_CHDIR     80
#define SYS_READLINK  89
#define SYS_MKDIR     83
#define SYS_UNLINK    87
#define SYS_RENAME    82
#define SYS_RMDIR     84
#define SYS_CHMOD     90
#define SYS_SYMLINK   88
#define SYS_TRUNCATE  210

#define EROFS   30
#define ENOENT  2
#define ENODEV  19
#define EINVAL  22
#define EBUSY   16
#define ENOTDIR 20

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2
#define O_CREAT  0x40
#define O_TRUNC  0x200

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello114:   ok   " : "hello114:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}
static int strlen_(const char *s) { int n = 0; while (s[n]) n++; return n; }

static uint8_t big_byte(uint64_t i) { return (uint8_t)(i * 7 + i / 251); }

/* Reads `path` fully into `buf`; returns the byte count or a negative errno. */
static int64_t slurp(const char *path, uint8_t *buf, uint64_t cap) {
    int64_t fd = syscall2(SYS_OPEN, (uint64_t)path, O_RDONLY);
    if (fd < 0) return fd;
    uint64_t got = 0;
    for (;;) {
        int64_t n = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)(buf + got), cap - got);
        if (n < 0) { syscall1(SYS_CLOSE, (uint64_t)fd); return n; }
        if (n == 0) break;
        got += (uint64_t)n;
        if (got >= cap) break;
    }
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return (int64_t)got;
}

static uint8_t big[400000];

struct dirent64 { uint64_t ino; int64_t off; uint16_t reclen; uint8_t type; char name[]; };

/* Counts entries of a directory and marks which "file_N.txt" (N = 1..300) appear. */
static int list_dir(const char *path, int *has_sub, int *numbered, int *total, int *dot, int *dotdot) {
    static uint8_t seen[301];
    for (int i = 0; i < 301; i++) seen[i] = 0;
    *has_sub = 0; *numbered = 0; *total = 0; *dot = 0; *dotdot = 0;
    int64_t fd = syscall2(SYS_OPEN, (uint64_t)path, O_RDONLY);
    if (fd < 0) return (int)fd;
    static char buf[2048];
    for (;;) {
        int64_t n = syscall3(SYS_GETDENTS, (uint64_t)fd, (uint64_t)buf, sizeof(buf));
        if (n < 0) { syscall1(SYS_CLOSE, (uint64_t)fd); return (int)n; }
        if (n == 0) break;
        int64_t off = 0;
        while (off < n) {
            struct dirent64 *d = (struct dirent64 *)(buf + off);
            (*total)++;
            if (streq(d->name, ".")) (*dot)++;
            else if (streq(d->name, "..")) (*dotdot)++;
            else if (streq(d->name, "sub")) (*has_sub)++;
            else if (d->name[0] == 'f' && d->name[1] == 'i' && d->name[2] == 'l' && d->name[3] == 'e' && d->name[4] == '_') {
                int v = 0;
                for (const char *p = d->name + 5; *p >= '0' && *p <= '9'; p++) v = v * 10 + (*p - '0');
                if (v >= 1 && v <= 300 && !seen[v]) { seen[v] = 1; (*numbered)++; }
            }
            off += d->reclen;
        }
    }
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return 0;
}

struct kstat_t { uint64_t w[18]; };   /* matches the 144-byte struct stat layout */

void _start(void) {
    print("hello114: read-only ext4 and NTFS volumes\n");
    uint8_t small[64];

    /* H (first half): rejections that must leave nothing mounted */
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/nosuchdisk", (uint64_t)"/mnt/x", (uint64_t)"ext4", 0) == -ENODEV, "H: unknown device is ENODEV");
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p2", (uint64_t)"/mnt/x", (uint64_t)"ext4", 0) == -EINVAL, "H: NTFS partition mounted as ext4 is EINVAL");
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/x", (uint64_t)"ntfs", 0) == -EINVAL, "H: ext4 partition mounted as ntfs is EINVAL");
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p3", (uint64_t)"/mnt/x", (uint64_t)"ext4", 0) == -ENODEV, "H: empty partition slot is ENODEV");

    /* A */
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/e", (uint64_t)"ext4", 0) == 0, "A: mount ext4 vblk1p1 at /mnt/e");
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p2", (uint64_t)"/mnt/n", (uint64_t)"ntfs", 0) == 0, "A: mount ntfs vblk1p2 at /mnt/n");
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/e2", (uint64_t)"ext4", 0) == -EBUSY, "H: the same partition cannot be mounted twice");

    /* B */
    int64_t n = slurp("/mnt/e/small.txt", small, sizeof(small));
    check(n == 9 && small[0] == 'h' && small[8] == '\n', "B: ext4 small file content");
    n = slurp("/mnt/n/small.txt", small, sizeof(small));
    check(n == 9 && small[0] == 'h' && small[8] == '\n', "B: ntfs small file content");
    n = slurp("/mnt/n/SMALL.TXT", small, sizeof(small));
    check(n == 9, "B: ntfs names are case-insensitive");
    n = slurp("/mnt/e/empty.txt", small, sizeof(small));
    check(n == 0, "B: ext4 empty file reads 0 bytes");

    n = slurp("/mnt/e/big.bin", big, sizeof(big));
    int ok = (n == 300000);
    for (int64_t i = 0; ok && i < 300000; i++) if (big[i] != big_byte((uint64_t)i)) ok = 0;
    check(ok, "B: ext4 300000-byte file matches byte for byte");
    n = slurp("/mnt/n/big.bin", big, sizeof(big));
    ok = (n == 300000);
    for (int64_t i = 0; ok && i < 300000; i++) if (big[i] != big_byte((uint64_t)i)) ok = 0;
    check(ok, "B: ntfs 300000-byte non-resident file matches byte for byte");

    n = slurp("/mnt/e/sparse.bin", big, sizeof(big));
    ok = (n == 24 * 16384 + 5003) && big[0] == 'A' && big[100] == 0 && big[16384] == 'B' && big[24 * 16384 + 5000] == 'E';
    check(ok, "B: ext4 sparse file (holes read as zero)");
    n = slurp("/mnt/n/sparse.bin", big, sizeof(big));
    ok = (n == 24 * 16384 + 5003) && big[0] == 'A' && big[100] == 0 && big[16384] == 'B' && big[24 * 16384 + 5000] == 'E';
    check(ok, "B: ntfs sparse file (holes read as zero)");

    int64_t fd = syscall2(SYS_OPEN, (uint64_t)"/mnt/e/big.bin", O_RDONLY);
    uint8_t mid[16];
    check(fd >= 0 && syscall4(SYS_PREAD, (uint64_t)fd, (uint64_t)mid, 16, 123457) == 16 && mid[0] == big_byte(123457) && mid[15] == big_byte(123472), "B: pread at an unaligned offset");
    check(syscall3(SYS_LSEEK, (uint64_t)fd, 299990, 0) == 299990 && syscall3(SYS_READ, (uint64_t)fd, (uint64_t)mid, 16) == 10, "B: lseek near EOF then a short read");
    check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)mid, 16) == 0, "B: read at EOF returns 0");
    syscall1(SYS_CLOSE, (uint64_t)fd);

    /* C */
    int has_sub, numbered, total, dot, dotdot;
    int r = list_dir("/mnt/e/dir", &has_sub, &numbered, &total, &dot, &dotdot);
    check(r == 0 && numbered == 300 && has_sub == 1 && dot == 1 && dotdot == 1 && total == 303, "C: ext4 htree dir lists 300 files + sub + . + ..");
    r = list_dir("/mnt/n", &has_sub, &numbered, &total, &dot, &dotdot);
    check(r == 0 && dot == 1 && dotdot == 1, "C: ntfs root lists . and ..");
    n = slurp("/mnt/e/dir/sub/n.txt", small, sizeof(small));
    check(n == 7 && small[0] == 'n', "C: ext4 nested path");
    n = slurp("/mnt/e/dir/file_217.txt", small, sizeof(small));
    check(n == 4 && small[0] == '2' && small[1] == '1' && small[2] == '7', "C: ext4 lookup inside the htree directory");
    n = slurp("/mnt/n/file_with_a_long_name_number_99.txt", small, sizeof(small));
    check(n == 3 && small[0] == '9' && small[1] == '9', "C: ntfs lookup through the INDEX_ALLOCATION tree");
    n = slurp("/mnt/e/dir/../small.txt", small, sizeof(small));
    check(n == 9, "C: '..' resolves inside the volume");
    check(syscall1(SYS_CHDIR, (uint64_t)"/mnt/e/dir/sub") == 0, "C: chdir into a volume directory");
    n = slurp("n.txt", small, sizeof(small));
    check(n == 7 && small[0] == 'n', "C: relative open from a volume cwd");
    n = slurp("../file_5.txt", small, sizeof(small));
    check(n == 2 && small[0] == '5', "C: relative '..' from a volume cwd");
    check(syscall1(SYS_CHDIR, (uint64_t)"/mnt/e/small.txt") == -ENOTDIR, "C: chdir to a file is ENOTDIR");
    check(syscall1(SYS_CHDIR, (uint64_t)"/mnt/e/nope") == -ENOENT, "C: chdir to a missing directory is ENOENT");
    syscall1(SYS_CHDIR, (uint64_t)"/");

    /* D */
    fd = syscall2(SYS_OPEN, (uint64_t)"/mnt/e/big.bin", O_RDONLY);
    struct kstat_t st;
    check(fd >= 0 && syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)&st) == 0 && st.w[6] == 300000 && (st.w[3] & 0170000) == 0100000, "D: fstat size and S_IFREG");
    syscall1(SYS_CLOSE, (uint64_t)fd);
    fd = syscall2(SYS_OPEN, (uint64_t)"/mnt/e/dir", O_RDONLY);
    check(fd >= 0 && syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)&st) == 0 && (st.w[3] & 0170000) == 0040000, "D: fstat S_IFDIR");
    syscall1(SYS_CLOSE, (uint64_t)fd);
    char link[64];
    for (int i = 0; i < 64; i++) link[i] = 0;
    int64_t ln = syscall3(SYS_READLINK, (uint64_t)"/mnt/e/link", (uint64_t)link, 63);
    check(ln == 9 && streq(link, "small.txt"), "D: readlink on an ext4 symlink");
    n = slurp("/mnt/e/link", small, sizeof(small));
    check(n == 9 && small[0] == 'h', "D: opening a symlink follows it");
    check(syscall3(SYS_READLINK, (uint64_t)"/mnt/e/small.txt", (uint64_t)link, 63) == -EINVAL, "D: readlink on a regular file is EINVAL");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/e/missing.txt", O_RDONLY) == -ENOENT, "D: opening a missing file is ENOENT");

    /* E */
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/e/small.txt", O_WRONLY) == -EROFS, "E: open for writing is EROFS");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/n/small.txt", O_RDWR) == -EROFS, "E: ntfs open read-write is EROFS");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/e/new.txt", O_WRONLY | O_CREAT) == -EROFS, "E: O_CREAT is EROFS");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/e/small.txt", O_RDONLY | O_TRUNC) == -EROFS, "E: O_TRUNC is EROFS");
    check(syscall2(SYS_MKDIR, (uint64_t)"/mnt/e/d", 0755) == -EROFS, "E: mkdir is EROFS");
    check(syscall1(SYS_UNLINK, (uint64_t)"/mnt/e/small.txt") == -EROFS, "E: unlink is EROFS");
    check(syscall1(SYS_RMDIR, (uint64_t)"/mnt/e/dir") == -EROFS, "E: rmdir is EROFS");
    check(syscall2(SYS_RENAME, (uint64_t)"/mnt/e/small.txt", (uint64_t)"/mnt/e/x.txt") == -EROFS, "E: rename within a volume is EROFS");
    check(syscall2(SYS_RENAME, (uint64_t)"/hello114-src", (uint64_t)"/mnt/e/x.txt") == -EROFS, "E: rename into a volume is EROFS");
    check(syscall2(SYS_CHMOD, (uint64_t)"/mnt/e/small.txt", 0777) == -EROFS, "E: chmod is EROFS");
    check(syscall2(SYS_SYMLINK, (uint64_t)"x", (uint64_t)"/mnt/e/l2") == -EROFS, "E: symlink creation is EROFS");
    check(syscall2(SYS_TRUNCATE, (uint64_t)"/mnt/e/small.txt", 0) == -EROFS, "E: truncate is EROFS");
    fd = syscall2(SYS_OPEN, (uint64_t)"/mnt/e/small.txt", O_RDONLY);
    check(syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"x", 1) < 0, "E: write on a read-only fd fails");
    syscall1(SYS_CLOSE, (uint64_t)fd);
    n = slurp("/mnt/e/small.txt", small, sizeof(small));
    check(n == 9 && small[0] == 'h', "E: the file is unchanged after all of that");

    /* F */
    fd = syscall2(SYS_OPEN, (uint64_t)"/mnt/e/big.bin", O_RDONLY);
    int64_t fd2 = syscall1(SYS_DUP, (uint64_t)fd);
    uint8_t a[8], b[8];
    syscall3(SYS_READ, (uint64_t)fd, (uint64_t)a, 8);
    syscall3(SYS_READ, (uint64_t)fd2, (uint64_t)b, 8);
    /* This kernel's dup copies the descriptor, so the copy has its own offset
     * (both start from 0 here); POSIX shares one. Asserting the data is right
     * for either, not the offset policy. */
    check(fd2 >= 0 && a[0] == big_byte(0) && (b[0] == big_byte(0) || b[0] == big_byte(8)), "F: a dup'd fd reads valid data");
    int64_t child = syscall1(SYS_FORK, 0);
    if (child == 0) {
        uint8_t c[8];
        int64_t k = syscall3(SYS_READ, (uint64_t)fd, (uint64_t)c, 8);
        syscall1(SYS_EXIT, (k == 8 && (c[0] == big_byte(8) || c[0] == big_byte(16))) ? 0 : 1);
        for (;;) {}
    }
    int32_t cst = 0;
    syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&cst, 0);
    check(((cst >> 8) & 0xff) == 0 && (cst & 0x7f) == 0, "F: a forked child reads through the inherited fd");
    syscall1(SYS_CLOSE, (uint64_t)fd2);
    uint8_t d[8];
    check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)d, 8) == 8, "F: the original fd still works after closing the dup");

    /* G: unmount with the fd still open */
    check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/e", 0) == 0, "G: umount ext4 with an open fd");
    check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)d, 8) < 0, "G: the open fd now fails instead of reading stale data");
    syscall1(SYS_CLOSE, (uint64_t)fd);
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/e/small.txt", O_RDONLY) < 0, "G: the unmounted path is gone");
    /* Slot reuse: free both slots, mount ext4 (takes slot 0), open a file,
     * unmount, and mount the SAME partition again (slot 0, new generation).
     * Inode numbers are identical, so a descriptor that ignored the mount
     * generation would happily read the new mount; it must fail instead. */
    check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/n", 0) == 0, "G: umount ntfs");
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/a1", (uint64_t)"ext4", 0) == 0, "G: mount ext4 again");
    fd = syscall2(SYS_OPEN, (uint64_t)"/mnt/a1/small.txt", O_RDONLY);
    check(fd >= 0 && syscall3(SYS_READ, (uint64_t)fd, (uint64_t)d, 8) == 8, "G: read through the first mount");
    check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/a1", 0) == 0, "G: umount it");
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/again", (uint64_t)"ext4", 0) == 0, "G: mount the same partition into the freed slot");
    syscall3(SYS_LSEEK, (uint64_t)fd, 0, 0);
    check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)d, 8) < 0, "G: a stale fd never reads the volume that took its slot");
    syscall1(SYS_CLOSE, (uint64_t)fd);
    n = slurp("/mnt/again/small.txt", small, sizeof(small));
    check(n == 9, "G: the remounted volume works");
    check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/again", 0) == 0, "G: final umount");
    check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/again", 0) < 0, "G: umount of a non-mount fails");

    print(failures == 0 ? "hello114: PASS\n" : "hello114: FAIL\n");
    print("hello114 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
