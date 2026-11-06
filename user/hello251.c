/* hello251: statfs/fstatfs report each filesystem's own figures, on ext2 (testdir/), FAT32 (bare root names) and tmpfs (/tmp). Measured
 * on Linux for tmpfs: f_type 0x01021994, f_bsize 4096, f_bfree <= f_blocks, f_namelen 255 (this kernel's tmpfs cuts names at 60 bytes, so it reports 60), and writing 40960 bytes lowers f_bfree by
 * exactly 10 blocks; statfs of a missing path is ENOENT and of "<file>/x" is ENOTDIR. ext2 is 0xEF53 and FAT is 0x4d44 (MSDOS_SUPER_MAGIC). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

#define SYS_STATFS  276
#define SYS_FSTATFS 277
struct kstatfs { unsigned long w[15]; }; /* type bsize blocks bfree bavail files ffree fsid namelen frsize flags */

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello251:   ok   " : "hello251:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static long do_statfs(const char *path, struct kstatfs *s) {
    memset(s, 0, sizeof *s);
    return syscall2(SYS_STATFS, (long)path, (long)s);
}

#define WRITE_BYTES 40960

static void run(const char *label, const char *path, const char *missing, int dir_semantics, unsigned long magic, int has_inodes, unsigned long name_max) {
    char what[240];
    char missing_under[96];
    struct kstatfs a, b, c;
    static char blk[WRITE_BYTES];

    int fd = (int)open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { snprintf(what, sizeof what, "%s: create %s failed (%d)", label, path, fd); check(0, what); return; }
    long r = do_statfs(path, &a);
    snprintf(what, sizeof what, "%s: statfs reports the type 0x%lx (rc %ld, type 0x%lx)", label, magic, r, a.w[0]);
    check(r == 0 && a.w[0] == magic, what);
    snprintf(what, sizeof what, "%s: block size %lu, blocks %lu >= free %lu >= available %lu, fragment size %lu, name max %lu", label, a.w[1], a.w[2], a.w[3], a.w[4], a.w[9], a.w[8]);
    check(a.w[1] >= 512 && a.w[2] > 0 && a.w[2] >= a.w[3] && a.w[3] >= a.w[4] && a.w[9] == a.w[1] && a.w[8] == name_max, what);
    if (magic == 0xEF53) {
        snprintf(what, sizeof what, "%s: blocks reserved for root are not available to others (free %lu, available %lu)", label, a.w[3], a.w[4]);
        check(a.w[4] < a.w[3], what);
    }
    if (has_inodes) {
        snprintf(what, sizeof what, "%s: inode counts are real (files %lu, free %lu)", label, a.w[5], a.w[6]);
        check(a.w[5] > 0 && a.w[5] >= a.w[6] && a.w[6] > 0 && a.w[5] != 65536, what);
    }
    r = syscall2(SYS_FSTATFS, fd, (long)&b);
    snprintf(what, sizeof what, "%s: fstatfs agrees with statfs (rc %ld, type 0x%lx, blocks %lu/%lu, free %lu/%lu)", label, r, b.w[0], b.w[2], a.w[2], b.w[3], a.w[3]);
    check(r == 0 && b.w[0] == a.w[0] && b.w[2] == a.w[2] && b.w[3] == a.w[3] && b.w[1] == a.w[1], what);

    memset(blk, 'x', sizeof blk);
    write(fd, blk, sizeof blk);
    fsync(fd);
    do_statfs(path, &c);
    unsigned long bs = c.w[1];
    unsigned long data = (WRITE_BYTES + bs - 1) / bs;
    unsigned long drop = a.w[3] - c.w[3];
    unsigned long expect_lo = data, expect_hi = data;
    if (magic == 0xEF53) { expect_hi = data + 1; if (data > 12) expect_lo = data + 1; } /* ext2: one indirect block past 12 data blocks */
    if (magic == 0x4d44) { expect_lo = data > 1 ? data - 1 : data; } /* FAT32: the empty file already owns a cluster */
    snprintf(what, sizeof what, "%s: writing %d bytes lowers the free count by %lu blocks (block size %lu, expected %lu..%lu)", label, WRITE_BYTES, drop, bs, expect_lo, expect_hi);
    check(c.w[3] <= a.w[3] && drop >= expect_lo && drop <= expect_hi, what);
    close(fd);
    unlink(path);
    struct kstatfs d;
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

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello251: statfs / fstatfs per filesystem\n");
    run("tmpfs", "/tmp/h251t", "/tmp/h251-missing", 1, 0x01021994UL, 1, 60);
    run("FAT32", "h251f", "h251-missing", 0, 0x4d44UL, 0, 255);
    run("ext2", "testdir/h251e", "testdir/h251-missing", 1, 0xEF53UL, 1, 255);
    print(failures == 0 ? "hello251: PASS\n" : "hello251: FAIL\n");
    return failures;
}
