/// hello278: /proc/self/fd/N of ext2 files follows rename and unlink. Linux (measured on the host): after the file is renamed the link
/// names the new path; after its parent directory is renamed it names the new parent plus the file name; after the name it was opened
/// by is unlinked it reads "<path> (deleted)" even while another hard link keeps the inode alive, and opening the link still reaches the
/// data. A file whose name is untouched keeps a plain path.
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
    print(ok ? "hello278:   ok   " : "hello278:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long linkText(int fd, char *out, int cap) {
    char l[64];
    snprintf(l, sizeof l, "/proc/self/fd/%d", fd);
    long n = readlink(l, out, cap - 1);
    out[n > 0 ? n : 0] = 0;
    return n;
}

int main(void) {
    char got[128];
    unlink("testdir/h278a");
    unlink("testdir/h278b");
    unlink("testdir/h278c");
    unlink("testdir/h278d");

    int a = (int)open("testdir/h278a", O_RDWR | O_CREAT | O_TRUNC, 0644);
    write(a, "abc", 3);
    long r = rename("testdir/h278a", "testdir/h278b");
    linkText(a, got, sizeof got);
    snprintf(what, sizeof what, "after rename the link names the new path (rename %ld, link \"%s\")", r, got);
    check(a >= 0 && r == 0 && strcmp(got, "/testdir/h278b") == 0, what);

    int e = (int)open("testdir/h278c", O_RDWR | O_CREAT | O_TRUNC, 0644);
    linkText(e, got, sizeof got);
    snprintf(what, sizeof what, "an untouched file keeps a plain path (\"%s\")", got);
    check(e >= 0 && strcmp(got, "/testdir/h278c") == 0, what);

    long l = link("testdir/h278c", "testdir/h278d");
    write(e, "xyz", 3);
    long u = unlink("testdir/h278c");
    linkText(e, got, sizeof got);
    snprintf(what, sizeof what, "unlinking the opened name gives \" (deleted)\" while another link remains (link %ld unlink %ld, \"%s\")", l, u, got);
    check(l == 0 && u == 0 && strcmp(got, "/testdir/h278c (deleted)") == 0, what);

    char p[64];
    snprintf(p, sizeof p, "/proc/self/fd/%d", e);
    int re = (int)open(p, O_RDONLY, 0);
    char buf[8] = {0};
    long n = re >= 0 ? read(re, buf, 3) : -1;
    snprintf(what, sizeof what, "opening the deleted link still reads the data (fd %d read %ld \"%s\")", re, n, buf);
    check(re >= 0 && n == 3 && memcmp(buf, "xyz", 3) == 0, what);
    if (re >= 0) {
        linkText(re, got, sizeof got);
        snprintf(what, sizeof what, "the reopened descriptor is also deleted (\"%s\")", got);
        check(strcmp(got, "/testdir/h278c (deleted)") == 0, what);
        close(re);
    }

    int d = (int)open("testdir/h278d", O_RDONLY, 0);
    linkText(d, got, sizeof got);
    snprintf(what, sizeof what, "the surviving hard link opens with a plain path (\"%s\")", got);
    check(d >= 0 && strcmp(got, "/testdir/h278d") == 0, what);
    if (d >= 0) close(d);

    rmdir("testdir/h278sub2");
    rmdir("testdir/h278sub");
    long mk = mkdir("testdir/h278sub", 0755);
    int s = (int)open("testdir/h278sub/f", O_RDWR | O_CREAT | O_TRUNC, 0644);
    long rr = rename("testdir/h278sub", "testdir/h278sub2");
    linkText(s, got, sizeof got);
    snprintf(what, sizeof what, "after the parent is renamed the link names the new parent (mkdir %ld rename %ld, \"%s\")", mk, rr, got);
    check(mk == 0 && s >= 0 && rr == 0 && strcmp(got, "/testdir/h278sub2/f") == 0, what);

    close(a);
    close(e);
    if (s >= 0) close(s);
    unlink("testdir/h278b");
    unlink("testdir/h278d");
    unlink("testdir/h278sub2/f");
    rmdir("testdir/h278sub2");

    print(failures == 0 ? "hello278: PASS\n" : "hello278: FAIL\n");
    return failures;
}
