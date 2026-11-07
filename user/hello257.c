/* hello257: /proc/self/fd. Measured on Linux: readlink("/proc/self/fd/N") gives the absolute path of an open file ("/tmp/x"), "pipe:[inode]" for
 * a pipe end, "socket:[inode]" for a socket and "anon_inode:[eventpoll]" / "[eventfd]" / "[timerfd]" for the event objects; a number that is not an
 * open descriptor is ENOENT; opendir("/proc/self/fd") lists "." and "..", and one entry per open descriptor, named by its number. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/dirent.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/epoll.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello257:   ok   " : "hello257:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

/* The readlink result for descriptor `fd` as a C string, or the negative errno as text. */
static long link_of(int fd, char *out, size_t cap) {
    char path[48];
    snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
    long n = readlink(path, out, cap - 1);
    out[n >= 0 ? n : 0] = 0;
    return n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello257: /proc/self/fd\n");
    char what[240], got[160];
    long n;

    int f = (int)open("/tmp/h257file", O_RDWR | O_CREAT | O_TRUNC, 0600);
    n = link_of(f, got, sizeof got);
    snprintf(what, sizeof what, "a tmpfs file reads back as its absolute path (\"%s\")", got);
    check(n > 0 && strcmp(got, "/tmp/h257file") == 0, what);

    int e = (int)open("testdir/h257ext2", O_RDWR | O_CREAT | O_TRUNC, 0600);
    n = link_of(e, got, sizeof got);
    snprintf(what, sizeof what, "an ext2 file opened by a relative name reads back as an absolute path (\"%s\")", got);
    check(n > 0 && strcmp(got, "/testdir/h257ext2") == 0, what);

    int p[2];
    pipe(p);
    n = link_of(p[0], got, sizeof got);
    snprintf(what, sizeof what, "a pipe end reads back as pipe:[inode] (\"%s\")", got);
    check(n > 6 && strncmp(got, "pipe:[", 6) == 0 && got[n - 1] == ']', what);

    /* Two different pipes must read back as different objects, and both ends of one pipe as the same object (Linux: the same inode number). */
    int q[2];
    pipe(q);
    char other[160], second_end[160];
    link_of(q[0], other, sizeof other);
    link_of(p[1], second_end, sizeof second_end);
    snprintf(what, sizeof what, "two pipes read back as different objects (\"%s\" vs \"%s\") and the two ends of one pipe as the same (\"%s\" vs \"%s\")", got, other, got, second_end);
    check(strcmp(got, other) != 0 && strcmp(got, second_end) == 0, what);
    close(q[0]);
    close(q[1]);

    long so = syscall3(SYS_socket, 2, 1, 0);
    n = link_of((int)so, got, sizeof got);
    snprintf(what, sizeof what, "a socket reads back as socket:[inode] (\"%s\")", got);
    check(n > 8 && strncmp(got, "socket:[", 8) == 0 && got[n - 1] == ']', what);

    int ep = (int)epoll_create1(0);
    n = link_of(ep, got, sizeof got);
    snprintf(what, sizeof what, "an epoll descriptor reads back as anon_inode:[eventpoll] (\"%s\")", got);
    check(n > 0 && strcmp(got, "anon_inode:[eventpoll]") == 0, what);

    n = link_of(900, got, sizeof got);
    int err = errno;
    snprintf(what, sizeof what, "a number that is not an open descriptor is ENOENT (rc %ld, errno %d)", n, err);
    check(n < 0 && err == ENOENT, what);

    /* Names that are not descriptors: Linux gives ENOENT for letters, a minus sign and a number too large for an int. */
    {
        char b2[32];
        long a = readlink("/proc/self/fd/abc", b2, sizeof b2);
        int ea = errno;
        long m = readlink("/proc/self/fd/-1", b2, sizeof b2);
        int em = errno;
        long h = readlink("/proc/self/fd/99999999999", b2, sizeof b2);
        int eh = errno;
        snprintf(what, sizeof what, "letters, a minus sign and a huge number are ENOENT (abc %ld/%d, -1 %ld/%d, huge %ld/%d)", a, ea, m, em, h, eh);
        check(a < 0 && ea == ENOENT && m < 0 && em == ENOENT && h < 0 && eh == ENOENT, what);
    }

    /* The directory: every open descriptor appears under its number, plus "." and "..". */
    DIR *d = opendir("/proc/self/fd");
    int dots = 0, saw_f = 0, saw_e = 0, saw_p0 = 0, entries = 0, bad = 0;
    if (d) {
        struct dirent *de;
        while ((de = readdir(d)) != (struct dirent *)0) {
            entries++;
            if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) { dots++; continue; }
            int v = atoi(de->d_name);
            if (v == f) saw_f = 1;
            if (v == e) saw_e = 1;
            if (v == p[0]) saw_p0 = 1;
            if (de->d_name[0] < '0' || de->d_name[0] > '9') bad++;
        }
        closedir(d);
    }
    snprintf(what, sizeof what, "opendir(/proc/self/fd) lists . and .. and every open descriptor by number (opened %d, dots %d, file %d, ext2 %d, pipe %d, non-numeric %d)", d != (DIR *)0, dots, saw_f, saw_e, saw_p0, bad);
    check(d != (DIR *)0 && dots == 2 && saw_f && saw_e && saw_p0 && bad == 0, what);

    /* Opening /proc/self/fd/N opens the same file again, with its own offset (Linux: a new open file description). stat sees the file. */
    {
        char link[48], rb[16];
        memset(rb, 0, sizeof rb);
        write(f, "hello", 5);
        snprintf(link, sizeof link, "/proc/self/fd/%d", f);
        long g = open(link, O_RDONLY, 0);
        long rn = g >= 0 ? read((int)g, rb, 5) : -1;
        long off = lseek(f, 0, SEEK_CUR);
        snprintf(what, sizeof what, "open(/proc/self/fd/N) opens the same file again: reads the 5 bytes from its own offset 0 (open %ld, read %ld \"%s\"), the original keeps offset 5 (%ld)", g, rn, rb, off);
        check(g >= 0 && rn == 5 && memcmp(rb, "hello", 5) == 0 && off == 5, what);
        if (g >= 0) close((int)g);
        struct stat st;
        memset(&st, 0, sizeof st);
        long sr = stat(link, &st);
        snprintf(what, sizeof what, "stat(/proc/self/fd/N) describes the file (rc %ld, regular %d, size %ld)", sr, S_ISREG(st.st_mode), (long)st.st_size);
        check(sr == 0 && S_ISREG(st.st_mode) && st.st_size == 5, what);
        long gone = open("/proc/self/fd/900", O_RDONLY, 0);
        snprintf(what, sizeof what, "open of a number that is not a descriptor is ENOENT (%ld)", gone);
        check(gone == -ENOENT, what);
    }

    /* Closing a descriptor removes it from the listing and from readlink. */
    close(f);
    n = link_of(f, got, sizeof got);
    snprintf(what, sizeof what, "a closed descriptor is gone from readlink (rc %ld)", n);
    check(n < 0, what);

    close(e);
    unlink("/tmp/h257file");
    unlink("testdir/h257ext2");
    print(failures == 0 ? "hello257: PASS\n" : "hello257: FAIL\n");
    return failures;
}
