/// hello280: /proc/self/fd/N of a FAT32 file unlinked while open. Linux builds the link text in the generic VFS (d_path), so every filesystem
/// behaves as measured on ext4 and tmpfs: the link reads "<path> (deleted)", opening it still reaches the data with a new descriptor (also
/// " (deleted)"), O_CREAT|O_EXCL through it is EEXIST; the name stays gone after the last close.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stat.h"

static int failures;
static char what[240];
static void check(int ok, const char *w) {
    print(ok ? "hello280:   ok   " : "hello280:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void linkText(int fd, char *out, int cap) {
    char l[64];
    snprintf(l, sizeof l, "/proc/self/fd/%d", fd);
    long n = readlink(l, out, cap - 1);
    out[n > 0 ? n : 0] = 0;
}

int main(void) {
    char got[128];
    char p[64];
    unlink("h280");
    int f = (int)open("h280", O_RDWR | O_CREAT | O_TRUNC, 0644);
    long w = f >= 0 ? write(f, "abc", 3) : -1;
    linkText(f, got, sizeof got);
    snprintf(what, sizeof what, "a FAT32 file has a plain path while named (fd %d write %ld, \"%s\")", f, w, got);
    check(f >= 0 && w == 3 && strcmp(got, "/h280") == 0, what);

    long u = unlink("h280");
    linkText(f, got, sizeof got);
    snprintf(what, sizeof what, "after unlink the link reads \" (deleted)\" (unlink %ld, \"%s\")", u, got);
    check(u == 0 && strcmp(got, "/h280 (deleted)") == 0, what);

    snprintf(p, sizeof p, "/proc/self/fd/%d", f);
    int ex = (int)open(p, O_RDWR | O_CREAT | O_EXCL, 0644);
    snprintf(what, sizeof what, "O_CREAT|O_EXCL through the deleted link is EEXIST (%d)", ex);
    check(ex == -EEXIST, what);
    if (ex >= 0) close(ex);

    int re = (int)open(p, O_RDONLY, 0);
    char buf[8] = {0};
    long n = re >= 0 ? read(re, buf, 3) : -1;
    snprintf(what, sizeof what, "the deleted link reopens and reads the data from offset 0 (fd %d read %ld \"%s\")", re, n, buf);
    check(re >= 0 && n == 3 && memcmp(buf, "abc", 3) == 0, what);
    if (re >= 0) {
        linkText(re, got, sizeof got);
        snprintf(what, sizeof what, "the reopened descriptor is also deleted (\"%s\")", got);
        check(strcmp(got, "/h280 (deleted)") == 0, what);
    }

    close(f);
    char b2[4] = {0};
    long n2 = re >= 0 ? pread(re, b2, 3, 0) : -1;
    snprintf(what, sizeof what, "the reopened descriptor keeps the data after the first one closes (%ld \"%s\")", n2, b2);
    check(n2 == 3 && memcmp(b2, "abc", 3) == 0, what);
    if (re >= 0) close(re);

    int gone = (int)open("h280", O_RDONLY, 0);
    snprintf(what, sizeof what, "after the last close the name is still gone (%d)", gone);
    check(gone == -ENOENT, what);
    if (gone >= 0) close(gone);

    print(failures == 0 ? "hello280: PASS\n" : "hello280: FAIL\n");
    return failures;
}
