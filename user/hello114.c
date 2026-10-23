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
///   I/J. (only when the scratch NVMe / SATA disk holds an ext4 volume)
///   L. permissions: the process runs as uid/gid 1000; files owned by 4242 are
///      checked against their other-class bits, the owner's own against the owner class
///   M. statfs/fstatfs: real block and inode counts, read-only flag, cached NTFS count
///   K. mount-point rules: '/', /dev, /proc, /tmp, nested and '..'-disguised
///      targets are refused; equivalent spellings name one mount

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
#define SYS_ACCESS    198
#define SYS_STATFS    276
#define SYS_FSTATFS   277

#define EROFS   30
#define ENOENT  2
#define EACCES  13
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

/* Mount `src` at `target` and expect `want`. If the mount unexpectedly
 * succeeds it is undone, so one wrongly accepted mount cannot keep the
 * partition busy and make every later refusal pass for the wrong reason. */
static int mount_expect(const char *src, const char *target, const char *type, int64_t want) {
    int64_t r = syscall4(SYS_MOUNT, (uint64_t)src, (uint64_t)target, (uint64_t)type, 0);
    if (r == 0 && want != 0) syscall2(SYS_UMOUNT2, (uint64_t)target, 0);
    return r == want;
}

struct kstat_t { uint64_t w[18]; };   /* matches the 144-byte struct stat layout */
struct kstatfs_t { uint64_t w[15]; }; /* 120-byte struct statfs: type bsize blocks bfree bavail files ffree fsid namelen frsize flags */

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

    /* M: statfs / fstatfs report the volume's own numbers (the expected
     * values are what dumpe2fs and a popcount of the NTFS $Bitmap say about
     * the fixtures, see tests/ext4_test.zig and tests/ntfs_test.zig). */
    {
        struct kstatfs_t sf;
        int64_t sr = syscall2(SYS_STATFS, (uint64_t)"/mnt/e/dir/sub", (uint64_t)&sf);
        check(sr == 0 && sf.w[0] == 0xEF53 && sf.w[1] == 1024 && sf.w[2] == 4096, "M: statfs on ext4 reports type, block size and block count");
        check(sr == 0 && sf.w[3] == 2092 && sf.w[4] == 2092 - 204 && sf.w[5] == 1024 && sf.w[6] == 694, "M: ext4 free blocks, reserved blocks and inodes match dumpe2fs");
        check(sr == 0 && (sf.w[10] & 1) != 0 && sf.w[8] == 255, "M: the volume is flagged read-only, name max 255");
        sr = syscall2(SYS_STATFS, (uint64_t)"/mnt/n", (uint64_t)&sf);
        check(sr == 0 && sf.w[0] == 0x5346544e && sf.w[1] == 1024 && sf.w[2] == 4095, "M: statfs on NTFS reports type, cluster size and cluster count");
        check(sr == 0 && sf.w[3] == 1743 && sf.w[4] == 1743 && sf.w[5] == 188 && sf.w[6] == 45, "M: NTFS free clusters and MFT records come from the bitmaps");
        sr = syscall2(SYS_STATFS, (uint64_t)"/mnt/n", (uint64_t)&sf);
        check(sr == 0 && sf.w[3] == 1743, "M: a second NTFS statfs (cached count) agrees");
        fd = syscall2(SYS_OPEN, (uint64_t)"/mnt/e/small.txt", O_RDONLY);
        sr = syscall2(SYS_FSTATFS, (uint64_t)fd, (uint64_t)&sf);
        check(fd >= 0 && sr == 0 && sf.w[0] == 0xEF53 && sf.w[2] == 4096, "M: fstatfs on a volume fd");
        syscall1(SYS_CLOSE, (uint64_t)fd);
        check(syscall2(SYS_STATFS, (uint64_t)"/mnt/e/nope", (uint64_t)&sf) == -ENOENT, "M: statfs on a missing path is ENOENT");
        check(syscall2(SYS_STATFS, (uint64_t)"/mnt/e/small.txt", 0) == -14, "M: a null buffer is EFAULT");
        sr = syscall2(SYS_STATFS, (uint64_t)"/", (uint64_t)&sf);
        check(sr == 0 && sf.w[2] != 4096 && sf.w[2] != 4095, "M: a path outside any volume keeps the built-in figures");
    }

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
    {
        struct kstatfs_t sf2;
        check(syscall2(SYS_FSTATFS, (uint64_t)fd, (uint64_t)&sf2) == -ENODEV, "M: fstatfs on an fd whose volume was unmounted is ENODEV");
    }
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

    /* K: mount-point rules */
    check(mount_expect("/dev/vblk1p1", "/", "ext4", -EBUSY), "K: mounting over / is refused");
    check(mount_expect("/dev/vblk1p1", "/dev", "ext4", -EBUSY), "K: mounting over /dev is refused");
    check(mount_expect("/dev/vblk1p1", "/proc/x", "ext4", -EBUSY), "K: mounting inside /proc is refused");
    check(mount_expect("/dev/vblk1p1", "/tmp", "ext4", -EBUSY), "K: mounting over /tmp is refused");
    check(mount_expect("/dev/vblk1p1", "/mnt/../dev", "ext4", -EBUSY), "K: '..' cannot smuggle a target into /dev");
    check(mount_expect("/dev/vblk1p1", "mnt/rel", "ext4", -EINVAL), "K: a relative target is EINVAL");
    check(mount_expect("/dev/vblk1p1", "//mnt///k1/", "ext4", 0), "K: a sloppy spelling mounts");
    check(mount_expect("/dev/vblk1p2", "/mnt/k1", "ntfs", -EBUSY), "K: the normalised target is taken (same mount point)");
    check(mount_expect("/dev/vblk1p2", "/mnt/k1/sub", "ntfs", -EBUSY), "K: nesting inside a mount is refused");
    check(mount_expect("/dev/vblk1p2", "/mnt", "ntfs", -EBUSY), "K: mounting above an existing mount is refused");
    n = slurp("/mnt/./k1/../k1/small.txt", small, sizeof(small));
    check(n == 9, "K: a path with . and .. reaches the mount");
    check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/x/../k1/", 0) == 0, "K: umount accepts an equivalent spelling");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/k1/small.txt", O_RDONLY) < 0, "K: the volume is gone after umount");

    /* L: permissions. The process is uid/gid 1000 and unprivileged. */
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/p", (uint64_t)"ext4", 0) == 0, "L: mount for the permission checks");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/p/perm/world.txt", O_RDONLY) >= 0, "L: world-readable file owned by someone else opens");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/p/perm/private.txt", O_RDONLY) == -EACCES, "L: mode 0600 owned by another user is EACCES");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/p/perm/group.txt", O_RDONLY) == -EACCES, "L: mode 0640 of another user/group is EACCES");
    check(slurp("/mnt/p/perm/mine_open.txt", small, sizeof(small)) == 18, "L: my own 0600 file reads");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/p/perm/mine_closed.txt", O_RDONLY) == -EACCES, "L: owner class 000 beats a readable other class");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/p/perm/locked", O_RDONLY) == -EACCES, "L: a 0700 directory of another user cannot be listed");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/p/perm/locked/inside.txt", O_RDONLY) == -EACCES, "L: nor searched");
    check(syscall2(SYS_OPEN, (uint64_t)"/mnt/p/perm/listonly/inside.txt", O_RDONLY) == -EACCES, "L: a list-only directory (0744) cannot be searched");
    fd = syscall2(SYS_OPEN, (uint64_t)"/mnt/p/perm/listonly", O_RDONLY);
    check(fd >= 0, "L: ...but it can be opened to list");
    syscall1(SYS_CLOSE, (uint64_t)fd);
    check(syscall1(SYS_CHDIR, (uint64_t)"/mnt/p/perm/locked") == -EACCES, "L: chdir into a closed directory is EACCES");
    /* access(2): the mode argument is honoured, not just existence */
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/private.txt", 0) == 0, "L: access F_OK only needs the file to exist");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/private.txt", 4) == -EACCES, "L: access R_OK on another user's 0600 file is EACCES");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/world.txt", 4) == 0, "L: access R_OK on a world-readable file is 0");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/world.txt", 2) == -EROFS, "L: access W_OK on a read-only volume is EROFS");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/world.txt", 6) == -EROFS, "L: access R_OK|W_OK is EROFS too");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/world.txt", 1) == -EACCES, "L: access X_OK on a file without execute bits is EACCES");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/world.txt", 8) == -EINVAL, "L: access with unknown mode bits is EINVAL");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/locked/inside.txt", 0) == -EACCES, "L: access cannot look through a closed directory");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/nope.txt", 0) == -ENOENT, "L: access on a missing file is ENOENT");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm", 1) == 0, "L: access X_OK on a searchable directory is 0");
    check(syscall2(SYS_ACCESS, (uint64_t)"/mnt/p/perm/locked", 1) == -EACCES, "L: access X_OK on a 0700 directory of another user is EACCES");
    {
        struct kstatfs_t sf3;
        check(syscall2(SYS_STATFS, (uint64_t)"/mnt/p/perm/locked/inside.txt", (uint64_t)&sf3) == -EACCES, "L: statfs cannot reach through a closed directory");
        check(syscall2(SYS_STATFS, (uint64_t)"/mnt/p/perm/private.txt", (uint64_t)&sf3) == 0, "L: statfs needs only search permission, not read on the file");
    }
    check(syscall3(SYS_READLINK, (uint64_t)"/mnt/p/link", (uint64_t)link, 63) == 9, "L: a symlink's own mode never blocks readlink");
    check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/p", 0) == 0, "L: umount");

    /* I: a volume on the NVMe controller (its read path sleeps until the
     * completion interrupt, unlike virtio-blk's polling). The smoke gives
     * nvme0 the ext4 fixture; without it the mount is EINVAL and we skip. */
    {
        int64_t mr = syscall4(SYS_MOUNT, (uint64_t)"/dev/nvme0", (uint64_t)"/mnt/nv", (uint64_t)"ext4", 0);
        if (mr == -EINVAL) {
            print("hello114:   skip I: nvme0 holds no ext4 volume\n");
        } else {
            check(mr == 0, "I: mount ext4 from /dev/nvme0");
            if (mr == 0) {
                n = slurp("/mnt/nv/small.txt", small, sizeof(small));
                check(n == 9 && small[0] == 'h', "I: read a file through the NVMe read path");
                n = slurp("/mnt/nv/big.bin", big, sizeof(big));
                ok = (n == 300000);
                for (int64_t i = 0; ok && i < 300000; i++) if (big[i] != big_byte((uint64_t)i)) ok = 0;
                check(ok, "I: 300000 bytes through NVMe match");
                check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/nv", 0) == 0, "I: umount nvme0 volume");
            }
        }
    }

    /* J: the same through the AHCI/SATA driver (non-NCQ polling or NCQ). */
    {
        int64_t mr = syscall4(SYS_MOUNT, (uint64_t)"/dev/sda", (uint64_t)"/mnt/sa", (uint64_t)"ext4", 0);
        if (mr == -EINVAL) {
            print("hello114:   skip J: sda holds no ext4 volume\n");
        } else {
            check(mr == 0, "J: mount ext4 from /dev/sda");
            if (mr == 0) {
                n = slurp("/mnt/sa/big.bin", big, sizeof(big));
                ok = (n == 300000);
                for (int64_t i = 0; ok && i < 300000; i++) if (big[i] != big_byte((uint64_t)i)) ok = 0;
                check(ok, "J: 300000 bytes through AHCI match");
                check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/sa", 0) == 0, "J: umount sda volume");
            }
        }
    }

    print(failures == 0 ? "hello114: PASS\n" : "hello114: FAIL\n");
    print("hello114 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
