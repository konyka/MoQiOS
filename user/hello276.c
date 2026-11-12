/// hello276: /proc/self/fd/N for an entry that was unlinked while the descriptor stays open. Linux keeps the link working and appends
/// " (deleted)" to the path the entry had when it was unlinked (measured: readlink "/tmp/x (deleted)", open through the link still
/// reads the file); this kernel used to report ENOENT for the link, so the descriptor's target was lost. On tmpfs only (the path is
/// reconstructed from the directory tree, which an unlinked ext2/FAT32 entry no longer has here).
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stat.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello276:   ok   " : "hello276:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello276: /proc/self/fd/N of unlinked entries\n");
    char what[220], link[64], buf[256];

    /* A: a file unlinked while open keeps its link, with the " (deleted)" suffix */
    unlink("/tmp/h276a");
    int a = (int)open("/tmp/h276a", O_RDWR | O_CREAT | O_TRUNC, 0644);
    long w = write(a, "hello", 5);
    long u = unlink("/tmp/h276a");
    snprintf(link, sizeof link, "/proc/self/fd/%d", a);
    memset(buf, 0, sizeof buf);
    long n = readlink(link, buf, sizeof buf - 1);
    snprintf(what, sizeof what, "A: the link of an unlinked open file reports its old path plus \" (deleted)\" (%ld \"%s\")", n, n > 0 ? buf : "");
    check(w == 5 && u == 0 && n > 0 && strcmp(buf, "/tmp/h276a (deleted)") == 0, what);

    /* B: the descriptor still works through the link: open and read what was written */
    int b = (int)open(link, O_RDONLY, 0);
    char rd[8] = {0};
    long rn = b >= 0 ? read(b, rd, 5) : -1;
    long aoff = lseek(a, 0, SEEK_CUR);
    if (b >= 0) close(b);
    snprintf(what, sizeof what, "B: open through the link reads the file from offset 0, the original keeps its own offset (fd %d read %ld \"%s\", original at %ld)", b, rn, rd, aoff);
    check(b >= 0 && rn == 5 && memcmp(rd, "hello", 5) == 0 && aoff == 5, what);

    /* C: stat through the link describes the file, not a failure */
    struct stat st;
    memset(&st, 0, sizeof st);
    int sr = stat(link, &st);
    snprintf(what, sizeof what, "C: stat through the link describes the file (rc %d, size %ld)", sr, (long)st.st_size);
    check(sr == 0 && st.st_size == 5, what);
    close(a);

    /* D: a directory removed while a descriptor is open behaves the same way */
    rmdir("/tmp/h276d");
    if (mkdir("/tmp/h276d", 0755) == 0) {
        int d = (int)open("/tmp/h276d", O_RDONLY | O_DIRECTORY, 0);
        if (rmdir("/tmp/h276d") == 0 && d >= 0) {
            snprintf(link, sizeof link, "/proc/self/fd/%d", d);
            memset(buf, 0, sizeof buf);
            long dn = readlink(link, buf, sizeof buf - 1);
            snprintf(what, sizeof what, "D: a removed open directory reports its old path plus \" (deleted)\" (%ld \"%s\")", dn, dn > 0 ? buf : "");
            check(dn > 0 && strcmp(buf, "/tmp/h276d (deleted)") == 0, what);
        } else {
            check(1, "D: skipped (could not remove the open directory)");
        }
        if (d >= 0) close(d);
    }

    /* E: a live entry has no suffix */
    int e = (int)open("/tmp/h276e", O_RDWR | O_CREAT | O_TRUNC, 0644);
    snprintf(link, sizeof link, "/proc/self/fd/%d", e);
    memset(buf, 0, sizeof buf);
    long en = readlink(link, buf, sizeof buf - 1);
    snprintf(what, sizeof what, "E: a live entry reports its path without a suffix (%ld \"%s\")", en, en > 0 ? buf : "");
    check(en > 0 && strcmp(buf, "/tmp/h276e") == 0, what);
    if (e >= 0) close(e);
    unlink("/tmp/h276e");

    print(failures == 0 ? "hello276: PASS\n" : "hello276: FAIL\n");
    return failures;
}
