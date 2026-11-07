/* hello251: statfs/fstatfs report each filesystem's own figures, on ext2 (testdir/), FAT32 (bare root names) and tmpfs (/tmp). Measured
 * on Linux for tmpfs: f_type 0x01021994, f_bsize 4096, f_bfree <= f_blocks, f_namelen 255 (this kernel's tmpfs cuts names at 60 bytes, so it reports 60), and writing 40960 bytes lowers f_bfree by
 * exactly 10 blocks; statfs of a missing path is ENOENT and of "<file>/x" is ENOTDIR. ext2 is 0xEF53 and FAT is 0x4d44 (MSDOS_SUPER_MAGIC). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello251:   ok   " : "hello251:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

/* 0, or -errno, so the checks below read as they did against the raw system call. */
static long do_statfs(const char *path, struct statfs *s) {
    memset(s, 0, sizeof *s);
    return statfs(path, s) == 0 ? 0 : -(long)errno;
}

#define WRITE_BYTES 40960

static void run(const char *label, const char *path, const char *missing, int dir_semantics, unsigned long magic, int has_inodes, unsigned long name_max) {
    char what[240];
    char missing_under[96];
    struct statfs a, b, c;
    static char blk[WRITE_BYTES];

    int fd = (int)open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { snprintf(what, sizeof what, "%s: create %s failed (%d)", label, path, fd); check(0, what); return; }
    long r = do_statfs(path, &a);
    snprintf(what, sizeof what, "%s: statfs reports the type 0x%lx (rc %ld, type 0x%lx)", label, magic, r, a.f_type);
    check(r == 0 && a.f_type == magic, what);
    snprintf(what, sizeof what, "%s: block size %lu, blocks %lu >= free %lu >= available %lu, fragment size %lu, name max %lu", label, a.f_bsize, a.f_blocks, a.f_bfree, a.f_bavail, a.f_frsize, a.f_namelen);
    check(a.f_bsize >= 512 && a.f_blocks > 0 && a.f_blocks >= a.f_bfree && a.f_bfree >= a.f_bavail && a.f_frsize == a.f_bsize && a.f_namelen == name_max, what);
    if (magic == 0xEF53) {
        snprintf(what, sizeof what, "%s: blocks reserved for root are not available to others (free %lu, available %lu)", label, a.f_bfree, a.f_bavail);
        check(a.f_bavail < a.f_bfree, what);
    }
    if (has_inodes) {
        snprintf(what, sizeof what, "%s: inode counts are real (files %lu, free %lu)", label, a.f_files, a.f_ffree);
        check(a.f_files > 0 && a.f_files >= a.f_ffree && a.f_ffree > 0 && a.f_files != 65536, what);
    }
    r = fstatfs(fd, &b);
    snprintf(what, sizeof what, "%s: fstatfs agrees with statfs (rc %ld, type 0x%lx, blocks %lu/%lu, free %lu/%lu)", label, r, b.f_type, b.f_blocks, a.f_blocks, b.f_bfree, a.f_bfree);
    check(r == 0 && b.f_type == a.f_type && b.f_blocks == a.f_blocks && b.f_bfree == a.f_bfree && b.f_bsize == a.f_bsize, what);

    memset(blk, 'x', sizeof blk);
    write(fd, blk, sizeof blk);
    fsync(fd);
    do_statfs(path, &c);
    unsigned long bs = (unsigned long)c.f_bsize;
    unsigned long data = (WRITE_BYTES + bs - 1) / bs;
    unsigned long drop = a.f_bfree - c.f_bfree;
    unsigned long expect_lo = data, expect_hi = data;
    if (magic == 0xEF53) { expect_hi = data + 1; if (data > 12) expect_lo = data + 1; } /* ext2: one indirect block past 12 data blocks */
    if (magic == 0x4d44) { expect_lo = data > 1 ? data - 1 : data; } /* FAT32: the empty file already owns a cluster */
    snprintf(what, sizeof what, "%s: writing %d bytes lowers the free count by %lu blocks (block size %lu, expected %lu..%lu)", label, WRITE_BYTES, drop, bs, expect_lo, expect_hi);
    check(c.f_bfree <= a.f_bfree && drop >= expect_lo && drop <= expect_hi, what);
    close(fd);
    unlink(path);
    struct statfs d;
    r = do_statfs(missing, &d);
    snprintf(what, sizeof what, "%s: statfs of a missing path is ENOENT (rc %ld)", label, r);
    check(r == -ENOENT, what);
    if (dir_semantics) {
        int f2 = (int)open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
        snprintf(missing_under, sizeof missing_under, "%s/x", path);
        r = do_statfs(missing_under, &d);
        snprintf(what, sizeof what, "%s: statfs of \"<file>/x\" is ENOTDIR (rc %ld)", label, r);
        check(r == -ENOTDIR, what);
        close(f2);
        unlink(path);
    }
}

/* /proc and /dev are not disk filesystems (this kernel opens the /proc files, not the /proc directory, so the file is what is asked). Measured on Linux: /proc is type 0x9fa0 (PROC_SUPER_MAGIC) with no blocks and no inodes, name max 255;
 * /dev is a devtmpfs, which reports TMPFS_MAGIC. Neither is the ext2 the kernel used to claim for every path. */
static void run_virtual(void) {
    char what[200];
    struct statfs p, d;
    long r = do_statfs("/proc/meminfo", &p);
    snprintf(what, sizeof what, "proc: statfs reports PROC_SUPER_MAGIC 0x9fa0 with no blocks or inodes (rc %ld, type 0x%lx, blocks %lu, files %lu)", r, (unsigned long)p.f_type, p.f_blocks, p.f_files);
    check(r == 0 && p.f_type == 0x9fa0 && p.f_blocks == 0 && p.f_bfree == 0 && p.f_files == 0 && p.f_ffree == 0 && p.f_namelen == 255, what);
    r = do_statfs("/dev/null", &d);
    snprintf(what, sizeof what, "dev: statfs reports a tmpfs-type devtmpfs, not ext2 (rc %ld, type 0x%lx)", r, (unsigned long)d.f_type);
    check(r == 0 && d.f_type == 0x01021994, what);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello251: statfs / fstatfs per filesystem\n");
    run("tmpfs", "/tmp/h251t", "/tmp/h251-missing", 1, 0x01021994UL, 1, 60);
    run("FAT32", "h251f", "h251-missing", 0, 0x4d44UL, 0, 255);
    run("ext2", "testdir/h251e", "testdir/h251-missing", 1, 0xEF53UL, 1, 255);
    run_virtual();
    print(failures == 0 ? "hello251: PASS\n" : "hello251: FAIL\n");
    return failures;
}
