/// hello114: read-only ext4 and NTFS volumes on the second virtio disk.
///
/// The disk (tests/fixtures/fs/datadisk.img, vblk1) holds an MBR with
/// p1 = ext4, p2 = NTFS and p3 = NTFS with a 1900-entry root, built by tools/fsfixtures/mkfixtures.sh.
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
///   N. a 1900-entry NTFS directory (multi-level index): complete, duplicate-free
///      listings with small buffers, two interleaved readers, rewind; listing time bounded
///   O. five processes read one file concurrently while a sixth is killed mid-read;
///      the volume lock must hand over cleanly and the volume must still work afterwards
///   P. mmap of a file on a volume: PROT_READ MAP_PRIVATE/MAP_SHARED serve the file's bytes,
///      a write mapping is refused, offsets work, the mapping outlives close(fd)
///   Q. directory descriptors: openat() relative to a volume directory fd, fchdir() into one,
///      fchdir() on a regular file is ENOTDIR
///   R. descriptor-based calls on a volume fd: nothing may modify or sync the volume, and an
///      unsupported call must fail cleanly (never act on another filesystem's object)
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

static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
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
#define SYS_FSYNC     74
#define SYS_FTRUNCATE 77
#define SYS_FCHMOD    91
#define SYS_FCHOWN    93
#define SYS_FALLOCATE 274
#define SYS_FLOCK     73
#define SYS_SENDFILE  40
#define SYS_PWRITE    18
#define SYS_COPY_FILE_RANGE 184
#define SYS_OPENAT    255
#define SYS_STATX     183
#define SYS_FCHDIR    81
#define SYS_GETCWD    79
#define SYS_MMAP      8
#define SYS_MUNMAP    12
#define SYS_KILL      62
#define SYS_SCHED_YIELD 24
#define SYS_CLOCK_GETTIME 228
#define SYS_STATFS    276
#define SYS_FSTATFS   277

#define EROFS   30
#define ENOENT  2
#define EACCES  13
#define ENODEV  19
#define EINVAL  22
#define EBUSY   16
#define ENOTDIR 20

#define PROT_READ    0x1
#define PROT_WRITE   0x2
#define MAP_SHARED   0x01
#define MAP_PRIVATE  0x02
#define ENODEV_ 19
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

#define SYS_SYSINFO 99
static uint64_t freeram_pages_(void) {
    static uint64_t sinfo[16];
    syscall1(SYS_SYSINFO, (uint64_t)sinfo);
    return sinfo[5] / 4096; /* freeram @40, in bytes here */
}

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

#define BIG_N 1900
#ifndef NTFS_LIST_BUDGET_MS
#define NTFS_LIST_BUDGET_MS 10000
#endif
struct big_stats { int total, named, dups, dot, dotdot, bad; uint8_t seen[BIG_N]; };

static void big_clear(struct big_stats *st) {
    st->total = st->named = st->dups = st->dot = st->dotdot = st->bad = 0;
    for (int i = 0; i < BIG_N; i++) st->seen[i] = 0;
}

static uint64_t now_ms(void) {
    struct { int64_t sec; int64_t nsec; } ts;
    syscall2(SYS_CLOCK_GETTIME, 1 /* CLOCK_MONOTONIC */, (uint64_t)&ts);
    return (uint64_t)ts.sec * 1000 + (uint64_t)ts.nsec / 1000000;
}

/* Read one getdents64 chunk of at most `bufsz` bytes from `fd`, tallying
 * "bigdir_entry_with_a_long_name_NNNN.txt" entries into `st`. Returns the
 * getdents result (0 at the end, negative errno on failure). */
static int64_t big_step(int64_t fd, uint64_t bufsz, struct big_stats *st) {
    static char buf[2048];
    static const char prefix[] = "bigdir_entry_with_a_long_name_";
    int64_t n = syscall3(SYS_GETDENTS, (uint64_t)fd, (uint64_t)buf, bufsz);
    if (n <= 0) return n;
    int64_t off = 0;
    while (off < n) {
        struct dirent64 *d = (struct dirent64 *)(buf + off);
        st->total++;
        const char *nm = d->name;
        if (streq(nm, ".")) st->dot++;
        else if (streq(nm, "..")) st->dotdot++;
        else {
            int i = 0;
            while (prefix[i] && nm[i] == prefix[i]) i++;
            if (prefix[i] == 0) {
                int v = 0, digits = 0;
                const char *q = nm + i;
                while (*q >= '0' && *q <= '9' && digits < 4) { v = v * 10 + (*q - '0'); q++; digits++; }
                if (digits == 4 && streq(q, ".txt") && v < BIG_N) {
                    st->named++;
                    if (st->seen[v]) st->dups++;
                    st->seen[v] = 1;
                } else st->bad++;
            }
        }
        off += d->reclen;
    }
    return n;
}

static int big_complete(const struct big_stats *st) {
    for (int i = 0; i < BIG_N; i++) if (!st->seen[i]) return 0;
    return 1;
}

static void print_u64(uint64_t v) {
    char num[24]; int k = 0;
    if (v == 0) num[k++] = '0';
    while (v) { num[k++] = (char)('0' + v % 10); v /= 10; }
    char out[24]; for (int j = 0; j < k; j++) out[j] = num[k - 1 - j]; out[k] = 0;
    print(out);
}

static struct big_stats bs_main, bs_a, bs_b;

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
    check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p4", (uint64_t)"/mnt/x", (uint64_t)"ext4", 0) == -ENODEV, "H: empty partition slot is ENODEV");

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

    /* N: a large NTFS directory. Entry names are 38 bytes, so a 200-byte
     * buffer holds three entries and listing 1900 of them takes ~640 getdents
     * calls; each must resume where the last stopped without rescanning. */
    {
        check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p3", (uint64_t)"/mnt/big", (uint64_t)"ntfs", 0) == 0, "N: mount the big-directory volume");
        big_clear(&bs_main);
        int64_t bfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/big", O_RDONLY);
        uint64_t t0 = now_ms();
        int64_t r;
        while ((r = big_step(bfd, 200, &bs_main)) > 0) {}
        uint64_t took = now_ms() - t0;
        check(bfd >= 0 && r == 0, "N: the listing ends cleanly");
        check(bs_main.named == BIG_N && bs_main.dups == 0 && big_complete(&bs_main), "N: all 1900 names appear exactly once with small buffers");
        check(bs_main.dot == 1 && bs_main.dotdot == 1 && bs_main.bad == 0, "N: . and .. once each, no malformed names");
        check(bs_main.total >= BIG_N + 2, "N: system files are listed too");
        print("hello114:   info N: 1900-entry listing took "); print_u64(took); print(" ms\n");
        check(took < NTFS_LIST_BUDGET_MS, "N: listing time is linear (a rescan per call would take far longer)");

        big_clear(&bs_main);
        check(syscall3(SYS_LSEEK, (uint64_t)bfd, 0, 0) == 0, "N: lseek(0) rewinds the directory");
        while ((r = big_step(bfd, 1024, &bs_main)) > 0) {}
        check(r == 0 && bs_main.named == BIG_N && bs_main.dups == 0 && big_complete(&bs_main), "N: a second listing after the rewind is complete");

        /* two readers of the same directory with different buffer sizes,
         * stepped alternately, each with its own tally */
        int64_t fa = syscall2(SYS_OPEN, (uint64_t)"/mnt/big", O_RDONLY);
        int64_t fb = syscall2(SYS_OPEN, (uint64_t)"/mnt/big", O_RDONLY);
        big_clear(&bs_a); big_clear(&bs_b);
        int64_t ra = 1, rb = 1;
        int clean = 1;
        while (ra > 0 || rb > 0) {
            if (ra > 0) { ra = big_step(fa, 200, &bs_a); if (ra < 0) clean = 0; }
            if (rb > 0) { rb = big_step(fb, 150, &bs_b); if (rb < 0) clean = 0; }
        }
        check(clean, "N: two interleaved readers never see an error");
        check(bs_a.named == BIG_N && bs_a.dups == 0 && big_complete(&bs_a), "N: reader A (interleaved) saw every name exactly once");
        check(bs_b.named == BIG_N && bs_b.dups == 0 && big_complete(&bs_b), "N: reader B (interleaved) saw every name exactly once");
        syscall1(SYS_CLOSE, (uint64_t)fa);
        syscall1(SYS_CLOSE, (uint64_t)fb);
        syscall1(SYS_CLOSE, (uint64_t)bfd);

        n = slurp("/mnt/big/bigdir_entry_with_a_long_name_1234.txt", small, sizeof(small));
        check(n == 0, "N: lookup of one entry deep in the tree works");
        check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/big", 0) == 0, "N: umount");
    }

    /* R: descriptor-based calls on a volume descriptor. The descriptors of the
     * other filesystems carry index fields that default to 0; a handler that
     * did not check the descriptor type could act on whatever object sits at
     * index 0 of ext2/fat32/tmpfs. Each call below must be refused outright,
     * and a file on the writable disk must be untouched afterwards. */
    {
        /* a canary on the writable root disk: slot 0 of its open-file tables */
        int64_t cfd = syscall2(SYS_OPEN, (uint64_t)"/hello114-canary", O_RDWR | O_CREAT | O_TRUNC);
        int canary_ok = cfd >= 0 && syscall3(SYS_WRITE, (uint64_t)cfd, (uint64_t)"canary-data-0123456789", 22) == 22;
        check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/r", (uint64_t)"ext4", 0) == 0, "R: mount ext4 for the descriptor-call tests");
        int64_t rfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/r/small.txt", O_RDONLY);
        check(rfd >= 0, "R: open a volume file");
        check(syscall2(SYS_FTRUNCATE, (uint64_t)rfd, 0) < 0, "R: ftruncate on a volume fd is refused");
        check(syscall2(SYS_FCHMOD, (uint64_t)rfd, 0777) < 0, "R: fchmod on a volume fd is refused");
        check(syscall3(SYS_FCHOWN, (uint64_t)rfd, 0, 0) < 0, "R: fchown on a volume fd is refused");
        check(syscall4(SYS_FALLOCATE, (uint64_t)rfd, 0, 0, 4096) < 0, "R: fallocate on a volume fd is refused");
        check(syscall3(SYS_WRITE, (uint64_t)rfd, (uint64_t)"x", 1) < 0, "R: write on a volume fd is refused");
        check(syscall4(SYS_PWRITE, (uint64_t)rfd, (uint64_t)"x", 1, 0) < 0, "R: pwrite on a volume fd is refused");
        int64_t fs_r = syscall1(SYS_FSYNC, (uint64_t)rfd);
        print("hello114:   info R: fsync on a volume fd returned "); print_u64(fs_r < 0 ? (uint64_t)(-fs_r) : (uint64_t)fs_r); print(fs_r < 0 ? " (negative errno)\n" : "\n");
        check(fs_r == 0 || fs_r == -22, "R: fsync on a volume fd is 0 or EINVAL, like any file with nothing to sync");
        /* the canary must be exactly as written */
        if (canary_ok) {
            syscall3(SYS_LSEEK, (uint64_t)cfd, 0, 0);
            uint8_t cb[32];
            int64_t cn = syscall3(SYS_READ, (uint64_t)cfd, (uint64_t)cb, 32);
            int same = (cn == 22);
            const char *want = "canary-data-0123456789";
            for (int i = 0; same && i < 22; i++) if (cb[i] != (uint8_t)want[i]) same = 0;
            check(same, "R: the writable-disk canary file is unchanged by all of the above");
        } else {
            check(0, "R: the writable-disk canary file is unchanged by all of the above");
        }
        /* sendfile with a volume fd as the source into a pipe */
        int32_t pp[2];
        if (syscall1(22, (uint64_t)pp) == 0) {
            int64_t sf = syscall4(SYS_SENDFILE, (uint64_t)pp[1], (uint64_t)rfd, 0, 9);
            uint8_t sb[16];
            int64_t sn = sf > 0 ? syscall3(SYS_READ, (uint64_t)pp[0], (uint64_t)sb, 16) : -1;
            print("hello114:   info R: sendfile from a volume fd returned "); print_u64(sf < 0 ? (uint64_t)(-sf) : (uint64_t)sf); print(sf < 0 ? " (negative errno)\n" : "\n");
            check(sf == 9 && sn == 9 && sb[0] == 'h' && sb[8] == '\n', "R: sendfile from a volume fd copies the file's bytes");
            syscall1(SYS_CLOSE, (uint64_t)pp[0]);
            syscall1(SYS_CLOSE, (uint64_t)pp[1]);
        }
        /* copy_file_range: a volume file is never a valid destination */
        {
            int64_t dst = syscall2(SYS_OPEN, (uint64_t)"/hello114-canary", O_RDWR);
            if (dst >= 0) {
                int64_t cr = syscall5(SYS_COPY_FILE_RANGE, (uint64_t)dst, 0, (uint64_t)rfd, 0, 4);
                check(cr < 0, "R: copy_file_range into a volume fd is refused");
                syscall1(SYS_CLOSE, (uint64_t)dst);
            }
        }
        /* ...but a volume file is a valid source for copy_file_range. The destination is a
         * freshly created file, so the result must be exactly the 9 bytes of the source. */
        {
            int64_t dst = syscall2(SYS_OPEN, (uint64_t)"/hello114-copy", O_RDWR | O_CREAT | O_TRUNC);
            if (dst >= 0) {
                syscall3(SYS_LSEEK, (uint64_t)rfd, 0, 0);
                int64_t cr = syscall5(SYS_COPY_FILE_RANGE, (uint64_t)rfd, 0, (uint64_t)dst, 0, 9);
                print("hello114:   info R: copy_file_range from a volume fd returned "); print_u64(cr < 0 ? (uint64_t)(-cr) : (uint64_t)cr); print(cr < 0 ? " (negative errno)\n" : "\n");
                syscall3(SYS_LSEEK, (uint64_t)dst, 0, 0);
                uint8_t cc[16];
                int64_t cn = syscall3(SYS_READ, (uint64_t)dst, (uint64_t)cc, 16);
                check(cr == 9 && cn == 9 && cc[0] == 'h' && cc[8] == '\n', "R: copy_file_range from a volume fd copies exactly the file's 9 bytes");
                syscall1(SYS_CLOSE, (uint64_t)dst);
                syscall1(87, (uint64_t)"/hello114-copy"); /* unlink */
            } else {
                check(0, "R: copy_file_range from a volume fd copies exactly the file's 9 bytes");
            }
        }
        /* a splice from a volume file into a pipe */
        {
            int32_t sp[2];
            if (syscall1(22, (uint64_t)sp) == 0) {
                syscall3(SYS_LSEEK, (uint64_t)rfd, 0, 0);
                int64_t sr = syscall6(145 /* splice */, (uint64_t)rfd, 0, (uint64_t)sp[1], 0, 9, 0);
                uint8_t sb2[16];
                int64_t sn2 = sr > 0 ? syscall3(SYS_READ, (uint64_t)sp[0], (uint64_t)sb2, 16) : -1;
                print("hello114:   info R: splice from a volume fd returned "); print_u64(sr < 0 ? (uint64_t)(-sr) : (uint64_t)sr); print(sr < 0 ? " (negative errno)\n" : "\n");
                check(sr == 9 && sn2 == 9 && sb2[0] == 'h', "R: splice from a volume fd into a pipe copies the file's bytes");
                syscall1(SYS_CLOSE, (uint64_t)sp[0]);
                syscall1(SYS_CLOSE, (uint64_t)sp[1]);
            }
        }
        syscall1(SYS_CLOSE, (uint64_t)rfd);
        if (cfd >= 0) syscall1(SYS_CLOSE, (uint64_t)cfd);
        syscall1(87, (uint64_t)"/hello114-canary"); /* unlink */
        check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/r", 0) == 0, "R: umount");
    }

    /* Q: directory descriptors on a volume */
    {
        check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/q", (uint64_t)"ext4", 0) == 0, "Q: mount ext4 for the directory-fd tests");
        int64_t dfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/q/dir", O_RDONLY);
        check(dfd >= 0, "Q: open a volume directory");
        /* openat(dirfd, "sub/n.txt") must resolve inside that directory, not against the cwd */
        int64_t afd = syscall4(SYS_OPENAT, (uint64_t)dfd, (uint64_t)"sub/n.txt", O_RDONLY, 0);
        uint8_t qb[16];
        int64_t qn = afd >= 0 ? syscall3(SYS_READ, (uint64_t)afd, (uint64_t)qb, 16) : -1;
        check(afd >= 0 && qn == 7 && qb[0] == 'n', "Q: openat(dirfd, relative path) resolves inside the directory");
        if (afd >= 0) syscall1(SYS_CLOSE, (uint64_t)afd);
        afd = syscall4(SYS_OPENAT, (uint64_t)dfd, (uint64_t)"file_217.txt", O_RDONLY, 0);
        qn = afd >= 0 ? syscall3(SYS_READ, (uint64_t)afd, (uint64_t)qb, 16) : -1;
        check(afd >= 0 && qn == 4 && qb[0] == '2' && qb[1] == '1' && qb[2] == '7', "Q: openat finds a file in an htree directory");
        if (afd >= 0) syscall1(SYS_CLOSE, (uint64_t)afd);
        check(syscall4(SYS_OPENAT, (uint64_t)dfd, (uint64_t)"nope.txt", O_RDONLY, 0) == -ENOENT, "Q: openat of a missing name is ENOENT");
        afd = syscall4(SYS_OPENAT, (uint64_t)dfd, (uint64_t)"../small.txt", O_RDONLY, 0);
        qn = afd >= 0 ? syscall3(SYS_READ, (uint64_t)afd, (uint64_t)qb, 16) : -1;
        check(afd >= 0 && qn == 9 && qb[0] == 'h', "Q: openat with '..' climbs out of the directory");
        if (afd >= 0) syscall1(SYS_CLOSE, (uint64_t)afd);
        /* an absolute path ignores dirfd */
        afd = syscall4(SYS_OPENAT, (uint64_t)dfd, (uint64_t)"/mnt/q/small.txt", O_RDONLY, 0);
        check(afd >= 0, "Q: openat with an absolute path ignores dirfd");
        if (afd >= 0) syscall1(SYS_CLOSE, (uint64_t)afd);
        /* a non-directory fd as dirfd */
        int64_t ffd = syscall2(SYS_OPEN, (uint64_t)"/mnt/q/small.txt", O_RDONLY);
        check(syscall4(SYS_OPENAT, (uint64_t)ffd, (uint64_t)"x", O_RDONLY, 0) == -ENOTDIR, "Q: a regular file as dirfd is ENOTDIR");
        /* fchdir */
        check(syscall1(SYS_FCHDIR, (uint64_t)ffd) == -ENOTDIR, "Q: fchdir on a regular file is ENOTDIR");
        syscall1(SYS_CLOSE, (uint64_t)ffd);
        check(syscall1(SYS_FCHDIR, (uint64_t)dfd) == 0, "Q: fchdir into a volume directory succeeds");
        qn = slurp("file_5.txt", qb, sizeof(qb));
        check(qn == 2 && qb[0] == '5', "Q: relative open after fchdir reads from that directory");
        syscall1(SYS_CHDIR, (uint64_t)"/");
        syscall1(SYS_CLOSE, (uint64_t)dfd);
        /* relative paths from a volume cwd, for the calls that resolve by path */
        check(syscall1(SYS_CHDIR, (uint64_t)"/mnt/q/dir") == 0, "Q: chdir into the volume directory");
        {
            static uint64_t stx[24];
            int64_t sr = syscall5(SYS_STATX, (uint64_t)-100, (uint64_t)"sub/n.txt", 0, 0x7ff, (uint64_t)stx);
            check(sr == 0 && stx[5] == 7, "Q: statx of a relative path from a volume cwd reports the file size");
            sr = syscall5(SYS_STATX, (uint64_t)-100, (uint64_t)"nope", 0, 0x7ff, (uint64_t)stx);
            check(sr == -ENOENT, "Q: statx of a missing relative name is ENOENT");
        }
        check(syscall2(SYS_ACCESS, (uint64_t)"file_1.txt", 4) == 0, "Q: access(R_OK) of a relative path from a volume cwd");
        check(syscall2(SYS_ACCESS, (uint64_t)"nope.txt", 0) == -ENOENT, "Q: access of a missing relative name is ENOENT");
        {
            char lk[64];
            for (int i = 0; i < 64; i++) lk[i] = 0;
            int64_t lr = syscall3(SYS_READLINK, (uint64_t)"../link", (uint64_t)lk, 63);
            check(lr == 9 && streq(lk, "small.txt"), "Q: readlink of a relative path from a volume cwd");
        }
        {
            struct kstatfs_t sfq;
            check(syscall2(SYS_STATFS, (uint64_t)"sub", (uint64_t)&sfq) == 0 && sfq.w[0] == 0xEF53, "Q: statfs of a relative path from a volume cwd reports the volume");
        }
        check(syscall1(SYS_CHDIR, (uint64_t)"/mnt/q/dir/sub") == 0 && syscall1(SYS_CHDIR, (uint64_t)"..") == 0, "Q: chdir('..') from a volume directory");
        qn = slurp("file_5.txt", qb, sizeof(qb));
        check(qn == 2 && qb[0] == '5', "Q: cwd is /mnt/q/dir after chdir('..')");
        syscall1(SYS_CHDIR, (uint64_t)"/");
        check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/q", 0) == 0, "Q: umount");
    }

    /* P: mmap of files on a mounted volume. */
    {
        check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/mm", (uint64_t)"ext4", 0) == 0, "P: mount ext4 for the mmap tests");
        int64_t mfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mm/big.bin", O_RDONLY);
        int64_t mp = syscall6(SYS_MMAP, 0, 300000, PROT_READ, MAP_PRIVATE, (uint64_t)mfd, 0);
        check(mp > 0 || mp < -4095, "P: mmap(PROT_READ, MAP_PRIVATE) of a volume file succeeds");
        if (mp > 0 || mp < -4095) {
            const uint8_t *m = (const uint8_t *)mp;
            int same = 1;
            for (uint64_t i = 0; same && i < 300000; i++) if (m[i] != big_byte(i)) same = 0;
            check(same, "P: all 300000 mapped bytes match the file");
            syscall1(SYS_CLOSE, (uint64_t)mfd);
            same = 1;
            for (uint64_t i = 0; same && i < 300000; i += 997) if (m[i] != big_byte(i)) same = 0;
            check(same, "P: the mapping outlives close(fd)");
            check(syscall2(SYS_MUNMAP, (uint64_t)mp, 74 * 4096) == 0, "P: munmap (page-aligned length)");
        } else {
            syscall1(SYS_CLOSE, (uint64_t)mfd);
        }
        mfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mm/big.bin", O_RDONLY);
        int64_t mo = syscall6(SYS_MMAP, 0, 8192, PROT_READ, MAP_SHARED, (uint64_t)mfd, 8192);
        check(mo > 0 || mo < -4095, "P: mmap with a page-aligned offset succeeds");
        if (mo > 0 || mo < -4095) {
            const uint8_t *m = (const uint8_t *)mo;
            int same = 1;
            for (uint64_t i = 0; same && i < 8192; i++) if (m[i] != big_byte(8192 + i)) same = 0;
            check(same, "P: an offset mapping shows the file from that offset");
            syscall2(SYS_MUNMAP, (uint64_t)mo, 8192);
        }
        check(syscall6(SYS_MMAP, 0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, (uint64_t)mfd, 0) == -13, "P: a writable shared mapping of a read-only volume is EACCES");
        check(syscall6(SYS_MMAP, 0, 4096, PROT_READ, MAP_PRIVATE, (uint64_t)mfd, 100) == -22, "P: an unaligned offset is EINVAL");
        syscall1(SYS_CLOSE, (uint64_t)mfd);
        {
            int64_t dfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mm/dir", O_RDONLY);
            check(syscall6(SYS_MMAP, 0, 4096, PROT_READ, MAP_PRIVATE, (uint64_t)dfd, 0) == -19, "P: mmap of a directory is ENODEV");
            syscall1(SYS_CLOSE, (uint64_t)dfd);
        }
        /* a private writable mapping is a copy: writes stay in memory, the file is unchanged */
        mfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mm/small.txt", O_RDONLY);
        int64_t pw = syscall6(SYS_MMAP, 0, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE, (uint64_t)mfd, 0);
        check(pw > 0 || pw < -4095, "P: a private writable mapping is allowed");
        if (pw > 0 || pw < -4095) {
            uint8_t *m = (uint8_t *)pw;
            check(m[0] == 'h' && m[8] == '\n' && m[9] == 0 && m[4095] == 0, "P: a short file reads as its bytes, then zeros to the end of the page");
            m[0] = 'J';
            check(m[0] == 'J', "P: the private copy is writable");
            int64_t kid = syscall1(SYS_FORK, 0);
            if (kid == 0) {
                /* the child sees the parent's value, and its own write is private */
                int ok2 = (m[0] == 'J');
                m[0] = 'K';
                syscall1(SYS_EXIT, ok2 && m[0] == 'K' ? 0 : 1);
                for (;;) {}
            }
            int32_t kst = 0;
            syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&kst, 0);
            check(((kst >> 8) & 0xff) == 0 && (kst & 0x7f) == 0, "P: a forked child inherits the copy and writes to its own");
            check(m[0] == 'J', "P: the child's write is not visible in the parent");
            uint8_t again[16];
            n = slurp("/mnt/mm/small.txt", again, sizeof(again));
            check(n == 9 && again[0] == 'h', "P: the file on the volume is unchanged");
            syscall2(SYS_MUNMAP, (uint64_t)pw, 4096);
        }
        syscall1(SYS_CLOSE, (uint64_t)mfd);
        /* no frames leak across many map/unmap cycles */
        {
            mfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mm/big.bin", O_RDONLY);
            uint64_t before = freeram_pages_();
            int cycles_ok = 1;
            for (int c = 0; c < 20; c++) {
                int64_t mm2 = syscall6(SYS_MMAP, 0, 74 * 4096, PROT_READ, MAP_PRIVATE, (uint64_t)mfd, 0);
                if (!(mm2 > 0 || mm2 < -4095)) { cycles_ok = 0; break; }
                volatile uint8_t sink = *(volatile uint8_t *)mm2; (void)sink;
                if (syscall2(SYS_MUNMAP, (uint64_t)mm2, 74 * 4096) != 0) cycles_ok = 0;
            }
            uint64_t after = freeram_pages_();
            check(cycles_ok, "P: 20 map/unmap cycles of a 300 KB file succeed");
            check(before >= after ? before - after < 16 : 1, "P: free memory is unchanged after those cycles (no leaked frames)");
            syscall1(SYS_CLOSE, (uint64_t)mfd);
        }
        /* a mapping bigger than the cap is refused cleanly */
        mfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mm/big.bin", O_RDONLY);
        check(syscall6(SYS_MMAP, 0, (uint64_t)33 << 20, PROT_READ, MAP_PRIVATE, (uint64_t)mfd, 0) == -12, "P: a mapping over the 32 MiB cap is ENOMEM");
        syscall1(SYS_CLOSE, (uint64_t)mfd);
        /* a mapping whose descriptor outlives the mount cannot be created */
        mfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mm/small.txt", O_RDONLY);
        check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/mm", 0) == 0, "P: umount");
        check(syscall6(SYS_MMAP, 0, 4096, PROT_READ, MAP_PRIVATE, (uint64_t)mfd, 0) < 0, "P: mmap through an fd whose volume was unmounted fails");
        syscall1(SYS_CLOSE, (uint64_t)mfd);
        /* the same on NTFS */
        check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p2", (uint64_t)"/mnt/mn", (uint64_t)"ntfs", 0) == 0, "P: mount ntfs for the mmap test");
        mfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mn/big.bin", O_RDONLY);
        int64_t nm = syscall6(SYS_MMAP, 0, 300000, PROT_READ, MAP_PRIVATE, (uint64_t)mfd, 0);
        check(nm > 0 || nm < -4095, "P: mmap of an NTFS file succeeds");
        if (nm > 0 || nm < -4095) {
            const uint8_t *m = (const uint8_t *)nm;
            int same = 1;
            for (uint64_t i = 0; same && i < 300000; i++) if (m[i] != big_byte(i)) same = 0;
            check(same, "P: all 300000 mapped NTFS bytes match the file");
            syscall2(SYS_MUNMAP, (uint64_t)nm, 74 * 4096);
        }
        syscall1(SYS_CLOSE, (uint64_t)mfd);
        mfd = syscall2(SYS_OPEN, (uint64_t)"/mnt/mn/sparse.bin", O_RDONLY);
        int64_t sm = syscall6(SYS_MMAP, 0, 24 * 16384 + 5003, PROT_READ, MAP_PRIVATE, (uint64_t)mfd, 0);
        if (sm > 0 || sm < -4095) {
            const uint8_t *m = (const uint8_t *)sm;
            check(m[0] == 'A' && m[100] == 0 && m[16384] == 'B' && m[24 * 16384 + 5000] == 'E', "P: an NTFS sparse file maps with its holes as zeros");
            syscall2(SYS_MUNMAP, (uint64_t)sm, ((24 * 16384 + 5003 + 4095) / 4096) * 4096);
        } else {
            check(0, "P: an NTFS sparse file maps with its holes as zeros");
        }
        syscall1(SYS_CLOSE, (uint64_t)mfd);
        check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/mn", 0) == 0, "P: umount ntfs");
    }

    /* O: contention on the volume lock. A holder that is preempted (timer
     * tick) keeps the lock; the others must sleep on it, not spin, and a
     * waiter that is signalled must leave the queue without losing its turn
     * or wedging the rest. */
    {
        check(syscall4(SYS_MOUNT, (uint64_t)"/dev/vblk1p1", (uint64_t)"/mnt/o", (uint64_t)"ext4", 0) == 0, "O: mount ext4 for the contention test");
        enum { READERS = 5 };
        int64_t kids[READERS];
        for (int k = 0; k < READERS; k++) {
            kids[k] = syscall1(SYS_FORK, 0);
            if (kids[k] == 0) {
                int good = 1;
                for (int round = 0; round < 4; round++) {
                    int64_t got = slurp("/mnt/o/big.bin", big, sizeof(big));
                    int same = (got == 300000);
                    for (int64_t i = 0; same && i < 300000; i++) if (big[i] != big_byte((uint64_t)i)) same = 0;
                    if (!same) good = 0;
                    /* also hit the directory path so the lock is taken by different operations */
                    int a, b, c, d2, e2;
                    if (list_dir("/mnt/o/dir/sub", &a, &b, &c, &d2, &e2) != 0) good = 0;
                }
                syscall1(SYS_EXIT, good ? 0 : 1);
                for (;;) {}
            }
        }
        /* the victim: reads forever until killed */
        int64_t victim = syscall1(SYS_FORK, 0);
        if (victim == 0) {
            for (;;) {
                int64_t got = slurp("/mnt/o/big.bin", big, sizeof(big));
                if (got != 300000) syscall1(SYS_EXIT, 2);
            }
        }
        for (int i = 0; i < 300; i++) syscall1(SYS_SCHED_YIELD, 0);
        check(victim > 0 && syscall2(SYS_KILL, (uint64_t)victim, 9) == 0, "O: SIGKILL the reader that is mid-read");
        int32_t vst = 0;
        int64_t vw = syscall3(SYS_WAITPID, (uint64_t)victim, (uint64_t)&vst, 0);
        check(vw == victim, "O: the killed reader is reaped");
        int all_ok = 1;
        for (int k = 0; k < READERS; k++) {
            int32_t st = 0;
            int64_t w = syscall3(SYS_WAITPID, (uint64_t)kids[k], (uint64_t)&st, 0);
            if (w != kids[k] || ((st >> 8) & 0xff) != 0 || (st & 0x7f) != 0) all_ok = 0;
        }
        check(all_ok, "O: all five concurrent readers got correct data and exited cleanly");
        n = slurp("/mnt/o/big.bin", big, sizeof(big));
        ok = (n == 300000);
        for (int64_t i = 0; ok && i < 300000; i++) if (big[i] != big_byte((uint64_t)i)) ok = 0;
        check(ok, "O: the volume still reads correctly after the contention and the kill");
        check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/o", 0) == 0, "O: umount succeeds (the lock is not left held)");
    }

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
                /* Two processes reading the same device at once: the read path
                 * must not hold something a sleeping reader cannot give up. */
                {
                    int64_t kid = syscall1(SYS_FORK, 0);
                    int good = 1;
                    for (int round = 0; round < 3; round++) {
                        int64_t got = slurp("/mnt/nv/big.bin", big, sizeof(big));
                        int same = (got == 300000);
                        for (int64_t i = 0; same && i < 300000; i++) if (big[i] != big_byte((uint64_t)i)) same = 0;
                        if (!same) good = 0;
                    }
                    if (kid == 0) {
                        syscall1(SYS_EXIT, good ? 0 : 1);
                        for (;;) {}
                    }
                    int32_t kst = 0;
                    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&kst, 0);
                    check(kid > 0 && good, "I: parent reads the NVMe volume correctly while a child reads it too");
                    check(kid > 0 && ((kst >> 8) & 0xff) == 0 && (kst & 0x7f) == 0, "I: the child reading concurrently got correct data");
                }
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
                {
                    int64_t kid = syscall1(SYS_FORK, 0);
                    int good = 1;
                    for (int round = 0; round < 3; round++) {
                        int64_t got = slurp("/mnt/sa/big.bin", big, sizeof(big));
                        int same = (got == 300000);
                        for (int64_t i = 0; same && i < 300000; i++) if (big[i] != big_byte((uint64_t)i)) same = 0;
                        if (!same) good = 0;
                    }
                    if (kid == 0) {
                        syscall1(SYS_EXIT, good ? 0 : 1);
                        for (;;) {}
                    }
                    int32_t kst = 0;
                    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&kst, 0);
                    check(kid > 0 && good, "J: parent reads the AHCI volume correctly while a child reads it too");
                    check(kid > 0 && ((kst >> 8) & 0xff) == 0 && (kst & 0x7f) == 0, "J: the child reading concurrently got correct data");
                }
                check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/sa", 0) == 0, "J: umount sda volume");
            }
        }
    }

    print(failures == 0 ? "hello114: PASS\n" : "hello114: FAIL\n");
    print("hello114 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
