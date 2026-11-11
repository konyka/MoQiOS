/* hello275: FAT32 writes that the writeback cache could never flush. Two cases staged data that could not reach the disk, and such a
 * buffer stays dirty and becomes the oldest one in the shared pool, so every later eviction tries it first and fails: from then on writes
 * to any file on any filesystem return ENOSPC once the pool is full (seen as hello270's short files in the full smoke, ext2 included).
 *   A: a file unlinked while open still takes writes that grow it (Linux: they succeed and read back through the descriptor);
 *   B: a file grown with ftruncate, then written past its old end (Linux: the write lands and the gap reads as zeros).
 * C then writes 4 MiB (more than the 512 x 4 KiB pool) to a fresh FAT32 file and to a fresh ext2 file: both must come out whole. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello275:   ok   " : "hello275:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static long big(const char *path) {
    static char rec[4096];
    memset(rec, 'q', sizeof rec);
    unlink(path);
    int fd = (int)open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1000;
    long total = 0;
    for (int i = 0; i < 1024; i++) {
        long w = write(fd, rec, sizeof rec);
        if (w != (long)sizeof rec) { printf("hello275:        %s: write %d returned %ld errno %d\n", path, i, w, errno); break; }
        total += w;
    }
    close(fd);
    fd = (int)open(path, O_RDONLY, 0);
    long sz = lseek(fd, 0, SEEK_END);
    close(fd);
    unlink(path);
    return total == sz ? sz : -1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello275: FAT32 writes the writeback cache could not flush\n");
    char what[200];

    /* A: unlink while open, then grow the file through both descriptors */
    {
        unlink("h275a");
        int a = (int)open("h275a", O_RDWR | O_CREAT | O_TRUNC, 0644);
        int b = (int)open("h275a", O_RDWR, 0);
        long w1 = write(a, "abc", 3);
        unlink("h275a");
        long w2 = write(a, "defgh", 5);
        long w3 = pwrite(b, "XY", 2, 8);
        long fs = fsync(a) | fsync(b);
        char r[16] = {0};
        long n = pread(b, r, sizeof r, 0);
        snprintf(what, sizeof what, "A: writes to an unlinked open file land and fsync succeeds (writes %ld %ld %ld, fsync %ld, read %ld \"%.10s\")", w1, w2, w3, fs, n, r);
        check(w1 == 3 && w2 == 5 && w3 == 2 && fs == 0 && n == 10 && memcmp(r, "abcdefghXY", 10) == 0, what);
        close(a);
        close(b);
    }

    /* B: grow with ftruncate, then write past the old end */
    {
        unlink("h275b");
        int a = (int)open("h275b", O_RDWR | O_CREAT | O_TRUNC, 0644);
        long w1 = write(a, "head", 4);
        long t = ftruncate(a, 8192);
        long w2 = pwrite(a, "ZZZZ", 4, 6000);
        long fs = fsync(a);
        char r[8] = {0}, gap = 1;
        long n = pread(a, r, 4, 6000);
        long g = pread(a, &gap, 1, 3000);
        snprintf(what, sizeof what, "B: a write past a truncate-grown end lands (write %ld, ftruncate %ld, pwrite %ld, fsync %ld, read %ld \"%.4s\", gap %ld/%d)", w1, t, w2, fs, n, r, g, gap);
        check(w1 == 4 && t == 0 && w2 == 4 && fs == 0 && n == 4 && memcmp(r, "ZZZZ", 4) == 0 && g == 1 && gap == 0, what);
        close(a);
        unlink("h275b");
    }

    /* C: afterwards, writing more than the whole pool still works everywhere */
    long f = big("h275c");
    snprintf(what, sizeof what, "C: 4 MiB to a fresh FAT32 file comes out whole (%ld bytes)", f);
    check(f == 4L * 1024 * 1024, what);
    long e = big("testdir/h275c");
    snprintf(what, sizeof what, "C: 4 MiB to a fresh ext2 file comes out whole (%ld bytes)", e);
    check(e == 4L * 1024 * 1024, what);

    print(failures == 0 ? "hello275: PASS\n" : "hello275: FAIL\n");
    return failures;
}
