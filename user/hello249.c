/* hello249: a shared file mapping follows a truncate made through another descriptor, on ext2 (testdir/), FAT32 (bare root names) and
 * tmpfs (/tmp). Measured on Linux (8192-byte file, page 0 and page 1 mapped read-only MAP_SHARED, truncate to 100 through a second
 * descriptor): touching the still-unfaulted page 1 raises SIGBUS (signal 7); page 0 keeps reading its first 100 bytes and the bytes
 * past the new end inside that page read as zero; extending back to 8192 makes page 1 readable again, zero filled. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/mman.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello249:   ok   " : "hello249:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

/* Reads one byte of *p in a child; returns the child's exit code, or -signal when it was killed. */
static int child_reads(volatile char *p, int expect) {
    long c = fork();
    if (c == 0) {
        int v = *p;
        _exit(v == expect ? 0 : 1);
    }
    int st = 0;
    waitpid(c, &st, 0);
    if ((st & 0x7f) != 0) return -(st & 0x7f);
    return (st >> 8) & 0xff;
}

static void run(const char *label, const char *path) {
    char what[200];
    static char blk[8192];
    int a = (int)open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (a < 0) { snprintf(what, sizeof what, "%s: create %s failed (%d)", label, path, a); check(0, what); return; }
    memset(blk, 'A', sizeof blk);
    write(a, blk, sizeof blk);
    int b = (int)open(path, O_RDWR, 0);
    fsync(a); /* the blocks are on disk before d copies the inode, so d holds real block pointers */
    int d = (int)open(path, O_RDWR, 0); /* never read before the stale-write check below */
    volatile char *m = (volatile char *)mmap(0, 8192, PROT_READ, MAP_SHARED, a, 0);
    if (m == (volatile char *)MAP_FAILED) { snprintf(what, sizeof what, "%s: mmap failed", label); check(0, what); close(a); close(b); close(d); unlink(path); return; }

    long fr = ftruncate(b, 100);
    int sig = child_reads(m + 4096, 0);
    snprintf(what, sizeof what, "%s: an unfaulted page wholly past the new end is SIGBUS (ftruncate %ld, child %d)", label, fr, sig);
    check(fr == 0 && sig == -7, what);

    int c0 = child_reads(m, 'A');
    snprintf(what, sizeof what, "%s: the page holding the new end still reads (child %d) and its tail past the end is zero (%d)", label, c0, (int)m[100]);
    check(c0 == 0 && m[99] == 'A' && m[100] == 0, what);

    fr = ftruncate(b, 8192);
    char rb[4] = { 'x', 'x', 'x', 'x' };
    long pn = pread(b, rb, 4, 4096);
    snprintf(what, sizeof what, "%s: reading the extended range through a descriptor gives zeros (pread %ld, byte %d)", label, pn, (int)rb[0]);
    check(pn == 4 && rb[0] == 0, what);
    snprintf(what, sizeof what, "%s: extending back makes the page readable and zero filled (ftruncate %ld, byte %d)", label, fr, (int)m[4096]);
    check(fr == 0 && m[4096] == 0, what);

    long wn = pwrite(a, "ZZ", 2, 2000);
    char zb[4] = { 0, 0, 0, 0 };
    char tail[4] = { 'x', 'x', 'x', 'x' };
    long rn = pread(b, zb, 2, 2000);
    long tn = pread(a, tail, 1, 6000);
    snprintf(what, sizeof what, "%s: a write through the first descriptor after the truncate is read by the second (pwrite %ld, pread %ld \"%s\"), and the extended range still reads zero (%ld, %d)", label, wn, rn, zb, tn, (int)tail[0]);
    check(wn == 2 && rn == 2 && memcmp(zb, "ZZ", 2) == 0 && tn == 1 && tail[0] == 0, what);

    /* The blocks the truncate freed may now belong to another file; a write through the first descriptor must not reach them. */
    char other[48];
    snprintf(other, sizeof other, "%s.o", path);
    ftruncate(b, 100);
    int c = (int)open(other, O_RDWR | O_CREAT | O_TRUNC, 0600);
    memset(blk, 'C', sizeof blk);
    write(c, blk, sizeof blk);
    fsync(c);
    pwrite(d, "ZZZZ", 4, 6000);
    pwrite(d, "YYYY", 4, 3000);
    fsync(d);
    static char back[8192];
    memset(back, 0, sizeof back);
    lseek(c, 0, SEEK_SET);
    long cn = read(c, back, sizeof back);
    int damaged = 0;
    for (int i = 0; i < cn; i++) if (back[i] != 'C') damaged++;
    snprintf(what, sizeof what, "%s: writes through a descriptor that never saw the truncate leave another file's data alone (read %ld, %d bytes damaged)", label, cn, damaged);
    check(cn == 8192 && damaged == 0, what);
    close(c);
    unlink(other);

    munmap((void *)m, 8192);
    close(a);
    close(b);
    close(d);
    unlink(path);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello249: mmap follows a truncate through another descriptor\n");
    run("tmpfs", "/tmp/h249t");
    run("FAT32", "h249f");
    run("ext2", "testdir/h249e");
    print(failures == 0 ? "hello249: PASS\n" : "hello249: FAIL\n");
    return failures;
}
