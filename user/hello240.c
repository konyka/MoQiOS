/* hello240: stat, lstat, fstat, chmod, fchmod, readlink, symlink and link of moqi_libc on the real kernel. Expected values were
 * measured against glibc on Linux with an equivalent program. Parts A, B and E run in /tmp (tmpfs); the kernel keeps no symbolic or
 * hard links in tmpfs, so parts C and D run in /testdir (ext2). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello240:   ok   " : "hello240:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello240: stat and friends\n");
    char what[200];
    struct stat st;

    /* How many tmpfs entries are free right now (the table holds 63 besides the root); earlier tests leave files behind, and a full
     * table makes creation fail with ENOSPC, which would show up below as a bogus failure of the call under test. */
    int free_slots = 0;
    {
        char nm[32];
        for (int i = 0; i < 70; i++) {
            snprintf(nm, sizeof nm, "/tmp/h240slot%d", i);
            int sfd = (int)open(nm, O_RDWR | O_CREAT, 0600);
            if (sfd < 0) break;
            close(sfd);
            free_slots++;
        }
        for (int i = 0; i < free_slots; i++) {
            snprintf(nm, sizeof nm, "/tmp/h240slot%d", i);
            unlink(nm);
        }
    }
    snprintf(what, sizeof what, "A0: tmpfs has room for the two scratch entries this test needs (%d free entries, need 2)", free_slots);
    check(free_slots >= 2, what);
    long r0 = rmdir("/tmp/h240");
    long mk0 = mkdir("/tmp/h240", 0755);
    long r = chdir("/tmp/h240");
    snprintf(what, sizeof what, "A: enter the scratch directory (rmdir of a stale one %ld, mkdir %ld, chdir %ld)", r0, mk0, r);
    check(r == 0 && mk0 == 0, what);

    int fd = (int)open("f", O_RDWR | O_CREAT, 0640);
    write(fd, "hello world", 11);

    /* B: stat / fstat */
    memset(&st, 0xAA, sizeof st);
    int sr = stat("f", &st);
    snprintf(what, sizeof what, "B: stat(f): regular, mode 0640, size 11, nlink 1, blksize 4096 (rc %d mode %o size %ld nlink %lu blksize %ld)", sr, st.st_mode, st.st_size, st.st_nlink, st.st_blksize);
    check(sr == 0 && S_ISREG(st.st_mode) && (st.st_mode & 07777) == 0640 && st.st_size == 11 && st.st_nlink == 1 && st.st_blksize == 4096, what);
    check(st.st_uid == getuid() && st.st_gid == getgid(), "B: stat(f) reports the owner as the creator");
    memset(&st, 0xAA, sizeof st);
    sr = fstat(fd, &st);
    snprintf(what, sizeof what, "B: fstat(fd): same file, size 11, mode 0640 (rc %d mode %o size %ld)", sr, st.st_mode, st.st_size);
    check(sr == 0 && S_ISREG(st.st_mode) && (st.st_mode & 07777) == 0640 && st.st_size == 11, what);
    errno = 0;
    check(stat("nope", &st) == -1 && errno == ENOENT, "B: stat of a missing name is -1 / ENOENT");
    errno = 0;
    long sx = stat("f/x", &st);
    int sxe = errno;
    snprintf(what, sizeof what, "B: stat(f/x) through a regular file is -1 / ENOTDIR (rc %ld errno %d)", sx, sxe);
    check(sx == -1 && sxe == ENOTDIR, what);
    errno = 0;
    check(fstat(999, &st) == -1 && errno == EBADF, "B: fstat on a closed descriptor is -1 / EBADF");
    {
        long ofx = open("f/x", O_RDONLY, 0);
        snprintf(what, sizeof what, "B: open(f/x) through a regular file is -ENOTDIR (returned %ld)", ofx);
        check(ofx == -ENOTDIR, what);
    }
    {
        long of2 = open("f/", O_RDONLY, 0);
        errno = 0;
        long ac2 = access("f/", F_OK);
        int ace = errno;
        errno = 0;
        long ch2 = chmod("f/", 0640);
        int che = errno;
        snprintf(what, sizeof what, "B: a trailing slash on a regular file: open %ld, access %ld/errno %d, chmod %ld/errno %d; Linux gives ENOTDIR for all three", of2, ac2, ace, ch2, che);
        check(of2 == -ENOTDIR && ac2 == -1 && ace == ENOTDIR && ch2 == -1 && che == ENOTDIR, what);
    }
    errno = 0;
    long sx2 = stat("f/", &st);
    snprintf(what, sizeof what, "B: stat(\"f/\"), a trailing slash on a regular file, is -1 / ENOTDIR (rc %ld errno %d)", sx2, errno);
    check(sx2 == -1 && errno == ENOTDIR, what);
    errno = 0;
    check(stat("missing/x", &st) == -1 && errno == ENOENT, "B: stat(missing/x) with a missing directory is -1 / ENOENT");
    errno = 0;
    check(stat("", &st) == -1 && errno == ENOENT, "B: stat of the empty string is -1 / ENOENT");
    {
        static char longn[300];
        memset(longn, 'a', 299);
        longn[299] = 0;
        errno = 0;
        long sl = stat(longn, &st);
        snprintf(what, sizeof what, "B: stat of a 299-byte name is -1 / ENAMETOOLONG (rc %ld errno %d)", sl, errno);
        check(sl == -1 && errno == ENAMETOOLONG, what);
    }

    chdir("/testdir");
    long mk = mkdir("h240d", 0755);
    sr = stat("h240d", &st);
    snprintf(what, sizeof what, "B: stat(d) on ext2: a directory with mode 0755 (mkdir %ld rc %d mode %o)", mk, sr, st.st_mode);
    check(mk == 0 && sr == 0 && S_ISDIR(st.st_mode) && (st.st_mode & 07777) == 0755, what);
    rmdir("h240d");
    int efd = (int)open("h240f", O_RDWR | O_CREAT, 0640);
    write(efd, "hello world", 11);
    close(efd);

    /* C: symlink (ext2) / lstat / readlink */
    errno = 0;
    check(symlink("h240f", "h240ln") == 0, "C: symlink(f, ln)");
    errno = 0;
    check(symlink("h240f", "h240ln") == -1 && errno == EEXIST, "C: symlink again is -1 / EEXIST");
    sr = lstat("h240ln", &st);
    snprintf(what, sizeof what, "C: lstat(ln): a symbolic link whose size is the length of its target, 5 (rc %d mode %o size %ld)", sr, st.st_mode, st.st_size);
    check(sr == 0 && S_ISLNK(st.st_mode) && st.st_size == 5, what);
    sr = stat("h240ln", &st);
    snprintf(what, sizeof what, "C: stat(ln) follows the link: regular, size 11 (rc %d mode %o size %ld)", sr, st.st_mode, st.st_size);
    check(sr == 0 && S_ISREG(st.st_mode) && st.st_size == 11, what);
    char b[32];
    memset(b, 'x', sizeof b);
    long rl = readlink("h240ln", b, sizeof b);
    check(rl == 5 && memcmp(b, "h240f", 5) == 0 && b[5] == 'x', "C: readlink(ln) returns the 5 bytes \"h240f\" without a terminating NUL");
    errno = 0;
    check(readlink("h240f", b, sizeof b) == -1 && errno == EINVAL, "C: readlink of a regular file is -1 / EINVAL");
    errno = 0;
    check(readlink("h240nope", b, sizeof b) == -1 && errno == ENOENT, "C: readlink of a missing name is -1 / ENOENT");
    sr = lstat("h240f", &st);
    check(sr == 0 && S_ISREG(st.st_mode), "C: lstat of a regular file describes the file");

    /* D: link */
    errno = 0;
    int lr = link("h240f", "h240hl");
    stat("h240f", &st);
    snprintf(what, sizeof what, "D: link(f, hl) succeeds and f has 2 links (rc %d nlink %lu)", lr, st.st_nlink);
    check(lr == 0 && st.st_nlink == 2, what);
    errno = 0;
    check(link("h240f", "h240hl") == -1 && errno == EEXIST, "D: link to an existing name is -1 / EEXIST");
    errno = 0;
    check(link("h240nope", "h240x") == -1 && errno == ENOENT, "D: link of a missing source is -1 / ENOENT");

    unlink("h240ln");
    unlink("h240hl");
    unlink("h240f");
    chdir("/tmp/h240");

    /* E: chmod / fchmod */
    check(chmod("f", 0600) == 0, "E: chmod(f, 0600)");
    stat("f", &st);
    snprintf(what, sizeof what, "E: stat shows mode 0600 (%o)", st.st_mode & 07777);
    check((st.st_mode & 07777) == 0600, what);
    check(fchmod(fd, 0644) == 0, "E: fchmod(fd, 0644)");
    fstat(fd, &st);
    snprintf(what, sizeof what, "E: fstat shows mode 0644 (%o)", st.st_mode & 07777);
    check((st.st_mode & 07777) == 0644, what);
    errno = 0;
    check(chmod("nope", 0600) == -1 && errno == ENOENT, "E: chmod of a missing name is -1 / ENOENT");
    errno = 0;
    check(fchmod(999, 0600) == -1 && errno == EBADF, "E: fchmod on a closed descriptor is -1 / EBADF");
    check(chmod("f", 07777) == 0, "E: chmod(f, 07777)");
    stat("f", &st);
    snprintf(what, sizeof what, "E: all of setuid, setgid, sticky and the permissions are kept (%o)", st.st_mode & 07777);
    check((st.st_mode & 07777) == 07777, what);

    close(fd);
    long ur = unlink("f");
    chdir("/");
    long rr = rmdir("/tmp/h240");
    snprintf(what, sizeof what, "Y: cleaning up: unlink(f) %ld, rmdir(/tmp/h240) %ld", ur, rr);
    check(ur == 0 && rr == 0, what);
    {
        char nm[32];
        int again = 0;
        for (int i = 0; i < 70; i++) {
            snprintf(nm, sizeof nm, "/tmp/h240slot%d", i);
            int sfd = (int)open(nm, O_RDWR | O_CREAT, 0600);
            if (sfd < 0) break;
            close(sfd);
            again++;
        }
        for (int i = 0; i < again; i++) {
            snprintf(nm, sizeof nm, "/tmp/h240slot%d", i);
            unlink(nm);
        }
        snprintf(what, sizeof what, "Z: this test left the tmpfs table as it found it (%d free entries before, %d after)", free_slots, again);
        check(again == free_slots, what);
    }
    print(failures == 0 ? "hello240: PASS\n" : "hello240: FAIL\n");
    return failures;
}
