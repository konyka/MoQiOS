/* hello248: a truncate through one descriptor is seen by every descriptor of the file, on ext2 (testdir/), FAT32 (bare root names) and
 * tmpfs (/tmp). Measured on Linux: after ftruncate(b, 5) the other descriptor reports size 5, SEEK_END 5 and reads 5 bytes; extending to
 * 12 afterwards reads 12 bytes with zeros in 5..11. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello248:   ok   " : "hello248:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void run(const char *label, const char *path) {
    char what[220];
    struct stat st;
    char r[40];
    int a = (int)open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (a < 0) { snprintf(what, sizeof what, "%s: create %s failed (%d)", label, path, a); check(0, what); return; }
    write(a, "0123456789ABCDEF", 16);
    int b = (int)open(path, O_RDWR, 0);
    long fr = ftruncate(b, 5);
    fstat(a, &st);
    long se = lseek(a, 0, SEEK_END);
    lseek(a, 0, SEEK_SET);
    memset(r, 0, sizeof r);
    long n = read(a, r, 32);
    snprintf(what, sizeof what, "%s: after the second descriptor truncated to 5 the first sees it (ftruncate %ld, fstat %ld, SEEK_END %ld, read %ld \"%s\")", label, fr, (long)st.st_size, se, n, r);
    check(fr == 0 && st.st_size == 5 && se == 5 && n == 5 && memcmp(r, "01234", 5) == 0, what);
    fr = ftruncate(b, 12);
    lseek(a, 0, SEEK_SET);
    memset(r, 'x', sizeof r);
    n = read(a, r, 32);
    snprintf(what, sizeof what, "%s: extending to 12 reads 12 bytes with zeros after the old end (ftruncate %ld, read %ld, [4]=%d [5]=%d [11]=%d)", label, fr, n, r[4], r[5], r[11]);
    check(fr == 0 && n == 12 && r[4] == '4' && r[5] == 0 && r[11] == 0, what);
    long tr = truncate(path, 3);
    fstat(b, &st);
    lseek(b, 0, SEEK_SET);
    memset(r, 0, sizeof r);
    n = read(b, r, 32);
    snprintf(what, sizeof what, "%s: truncate(path, 3) is seen by an open descriptor (rc %ld, fstat %ld, read %ld \"%s\")", label, tr, (long)st.st_size, n, r);
    check(tr == 0 && st.st_size == 3 && n == 3 && memcmp(r, "012", 3) == 0, what);
    close(a);
    close(b);
    unlink(path);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello248: truncate seen by every descriptor\n");
    run("tmpfs", "/tmp/h248t");
    run("FAT32", "h248f");
    run("ext2", "testdir/h248e");
    print(failures == 0 ? "hello248: PASS\n" : "hello248: FAIL\n");
    return failures;
}
