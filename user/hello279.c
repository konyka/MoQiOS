/// hello279: ext2 names removed under an open descriptor. Linux (measured on the host): a directory removed by rmdir while open reads
/// "<path> (deleted)" through /proc/self/fd/N, can still be reopened through it, fstat gives nlink 0, getdents64 and openat(O_CREAT) on it
/// are ENOENT, also after a new directory of the same name appears. A file or empty directory replaced by rename is " (deleted)" too.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stat.h"

#define SYS_OPENAT 255

static int failures;
static char what[240];
static void check(int ok, const char *w) {
    print(ok ? "hello279:   ok   " : "hello279:   FAIL ");
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
    char dents[512];
    rmdir("testdir/h279d");
    long mk = mkdir("testdir/h279d", 0755);
    int d = (int)open("testdir/h279d", O_RDONLY | O_DIRECTORY, 0);
    long rd = rmdir("testdir/h279d");
    linkText(d, got, sizeof got);
    snprintf(what, sizeof what, "a directory removed while open reads \" (deleted)\" (mkdir %ld fd %d rmdir %ld, \"%s\")", mk, d, rd, got);
    check(mk == 0 && d >= 0 && rd == 0 && strcmp(got, "/testdir/h279d (deleted)") == 0, what);

    struct stat st;
    memset(&st, 0, sizeof st);
    int fs = fstat(d, &st);
    snprintf(what, sizeof what, "fstat of the removed directory gives nlink 0 (rc %d nlink %lu)", fs, st.st_nlink);
    check(fs == 0 && st.st_nlink == 0, what);

    long g = syscall3(SYS_getdents64, d, (long)dents, sizeof dents);
    snprintf(what, sizeof what, "getdents64 on the removed directory is ENOENT (%ld)", g);
    check(g == -ENOENT, what);

    long c = syscall4(SYS_OPENAT, d, (long)"x", O_RDWR | O_CREAT, 0644);
    snprintf(what, sizeof what, "openat(O_CREAT) in the removed directory is ENOENT (%ld)", c);
    check(c == -ENOENT, what);
    if (c >= 0) close((int)c);

    long mk2 = mkdir("testdir/h279d", 0755);
    long c2 = syscall4(SYS_OPENAT, d, (long)"y", O_RDWR | O_CREAT, 0644);
    int leak = (int)open("testdir/h279d/y", O_RDONLY, 0);
    snprintf(what, sizeof what, "with a new directory of the same name, openat is still ENOENT and creates nothing there (mkdir %ld openat %ld open %d)", mk2, c2, leak);
    check(mk2 == 0 && c2 == -ENOENT && leak < 0, what);
    if (c2 >= 0) close((int)c2);
    if (leak >= 0) close(leak);
    unlink("testdir/h279d/y");
    rmdir("testdir/h279d");

    char p[64];
    snprintf(p, sizeof p, "/proc/self/fd/%d", d);
    int re = (int)open(p, O_RDONLY | O_DIRECTORY, 0);
    snprintf(what, sizeof what, "the removed directory reopens through its link (%d)", re);
    check(re >= 0, what);
    if (re >= 0) close(re);
    close(d);

    unlink("testdir/h279m");
    unlink("testdir/h279v");
    int m = (int)open("testdir/h279m", O_RDWR | O_CREAT | O_TRUNC, 0644);
    int v = (int)open("testdir/h279v", O_RDWR | O_CREAT | O_TRUNC, 0644);
    write(v, "old", 3);
    long rn = rename("testdir/h279m", "testdir/h279v");
    char gm[128];
    linkText(v, got, sizeof got);
    linkText(m, gm, sizeof gm);
    snprintf(what, sizeof what, "a file replaced by rename is \" (deleted)\", the moved one names the target (rename %ld, \"%s\", \"%s\")", rn, got, gm);
    check(rn == 0 && strcmp(got, "/testdir/h279v (deleted)") == 0 && strcmp(gm, "/testdir/h279v") == 0, what);
    char buf[4] = {0};
    long n = pread(v, buf, 3, 0);
    snprintf(what, sizeof what, "the replaced file still reads its data (%ld \"%s\")", n, buf);
    check(n == 3 && memcmp(buf, "old", 3) == 0, what);
    close(m);
    close(v);
    unlink("testdir/h279v");

    rmdir("testdir/h279e");
    rmdir("testdir/h279f");
    mkdir("testdir/h279e", 0755);
    mkdir("testdir/h279f", 0755);
    int vf = (int)open("testdir/h279f", O_RDONLY | O_DIRECTORY, 0);
    int me = (int)open("testdir/h279e", O_RDONLY | O_DIRECTORY, 0);
    long rr = rename("testdir/h279e", "testdir/h279f");
    linkText(vf, got, sizeof got);
    linkText(me, gm, sizeof gm);
    long g2 = syscall3(SYS_getdents64, vf, (long)dents, sizeof dents);
    snprintf(what, sizeof what, "an empty directory replaced by rename is \" (deleted)\" and unlistable (rename %ld, \"%s\", \"%s\", getdents %ld)", rr, got, gm, g2);
    check(rr == 0 && strcmp(got, "/testdir/h279f (deleted)") == 0 && strcmp(gm, "/testdir/h279f") == 0 && g2 == -ENOENT, what);
    close(vf);
    close(me);
    rmdir("testdir/h279f");

    print(failures == 0 ? "hello279: PASS\n" : "hello279: FAIL\n");
    return failures;
}
