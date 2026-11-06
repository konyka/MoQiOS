/* hello241: a tmpfs entry comes back when its last descriptor closes, however the descriptors were made. The tmpfs table holds
 * 63 entries; a descriptor that is closed while another descriptor of the same file is still open must still give up its own
 * reference to the entry, otherwise unlink cannot free the slot and the table slowly fills (open+stat leaked one entry per call).
 * The count of free entries is measured by creating files until the table is full. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello241:   ok   " : "hello241:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int free_entries(void) {
    char nm[32];
    int n = 0;
    for (int i = 0; i < 70; i++) {
        snprintf(nm, sizeof nm, "/tmp/h241slot%d", i);
        int s = (int)open(nm, O_RDWR | O_CREAT, 0600);
        if (s < 0) break;
        close(s);
        n++;
    }
    for (int i = 0; i < n; i++) {
        snprintf(nm, sizeof nm, "/tmp/h241slot%d", i);
        unlink(nm);
    }
    return n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello241: tmpfs entries are returned by the last close\n");
    char what[160];
    struct stat st;
    int base = free_entries();
    snprintf(what, sizeof what, "A: the baseline can be measured (%d free entries)", base);
    check(base >= 6, what);

    /* B: one descriptor, closed, unlinked: the entry is back */
    int fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    close(fd);
    unlink("/tmp/h241f");
    int n = free_entries();
    snprintf(what, sizeof what, "B: create, close, unlink gives the entry back (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* C: stat of a file that is open (statx opens it a second time inside) */
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    stat("/tmp/h241f", &st);
    close(fd);
    unlink("/tmp/h241f");
    n = free_entries();
    snprintf(what, sizeof what, "C: stat of a file while it is open does not pin the entry (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* D: two descriptors of the same file made by open, closed in either order */
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    int fd2 = (int)open("/tmp/h241f", O_RDONLY, 0);
    close(fd);
    close(fd2);
    unlink("/tmp/h241f");
    n = free_entries();
    snprintf(what, sizeof what, "D: two opens of one file, closed first-then-second (%d free, baseline %d)", n, base);
    check(n == base, what);
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    fd2 = (int)open("/tmp/h241f", O_RDONLY, 0);
    close(fd2);
    close(fd);
    unlink("/tmp/h241f");
    n = free_entries();
    snprintf(what, sizeof what, "D: two opens of one file, closed second-then-first (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* E: unlink while a second descriptor is open: the data stays readable and the entry comes back at the last close */
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    write(fd, "abc", 3);
    fd2 = (int)open("/tmp/h241f", O_RDONLY, 0);
    close(fd);
    unlink("/tmp/h241f");
    char b[4] = {0};
    long rn = read(fd2, b, 3);
    close(fd2);
    n = free_entries();
    snprintf(what, sizeof what, "E: unlinked while still open: reads %ld bytes \"%s\", entry returned at the last close (%d free, baseline %d)", rn, b, n, base);
    check(rn == 3 && memcmp(b, "abc", 3) == 0 && n == base, what);

    /* F: dup */
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    int d = (int)dup(fd);
    close(fd);
    close(d);
    unlink("/tmp/h241f");
    n = free_entries();
    snprintf(what, sizeof what, "F: dup then closing both gives the entry back (%d free, baseline %d)", n, base);
    check(n == base, what);

    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    d = (int)fcntl(fd, F_DUPFD, 20);
    close(fd);
    close(d);
    unlink("/tmp/h241f");
    n = free_entries();
    snprintf(what, sizeof what, "F: fcntl(F_DUPFD) then closing both gives the entry back (%d free, baseline %d)", n, base);
    check(n == base, what);
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    d = (int)dup3(fd, 21, 0);
    close(fd);
    close(d);
    unlink("/tmp/h241f");
    n = free_entries();
    snprintf(what, sizeof what, "F: dup3 then closing both gives the entry back (%d free, baseline %d)", n, base);
    check(n == base, what);
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT, 0600);
    fd2 = (int)open("/tmp/h241g", O_RDWR | O_CREAT, 0600);
    d = (int)dup2(fd, fd2);
    close(fd);
    close(d);
    unlink("/tmp/h241f");
    unlink("/tmp/h241g");
    n = free_entries();
    snprintf(what, sizeof what, "F: dup2 over an open descriptor releases the old target and shares the new one (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* F2: the duplicate keeps the file alive after the original is closed and the name is gone (Linux: reads "abc", then writes work) */
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    write(fd, "abc", 3);
    d = (int)dup(fd);
    close(fd);
    unlink("/tmp/h241f");
    {
        char r1[4] = {0};
        char r2[8] = {0};
        lseek(d, 0, SEEK_SET);
        long a1 = read(d, r1, 3);
        long w1 = write(d, "XYZ", 3);
        lseek(d, 0, SEEK_SET);
        long a2 = read(d, r2, 6);
        snprintf(what, sizeof what, "F2: after the original is closed and unlinked, the dup still reads \"%s\" (%ld), writes (%ld) and reads back \"%s\" (%ld)", r1, a1, w1, r2, a2);
        check(a1 == 3 && memcmp(r1, "abc", 3) == 0 && w1 == 3 && a2 == 6 && memcmp(r2, "abcXYZ", 6) == 0, what);
    }
    close(d);
    {
        int after = free_entries();
        snprintf(what, sizeof what, "F2: closing the last descriptor returns the entry (%d free, baseline %d)", after, base);
        check(after == base, what);
    }

    /* G: a directory made and removed, with a file inside it opened through a relative name after chdir */
    mkdir("/tmp/h241d", 0755);
    chdir("/tmp/h241d");
    fd = (int)open("f", O_RDWR | O_CREAT, 0600);
    stat("f", &st);
    close(fd);
    unlink("f");
    chdir("/");
    rmdir("/tmp/h241d");
    n = free_entries();
    snprintf(what, sizeof what, "G: mkdir, chdir, open+stat+close+unlink, rmdir leaves nothing behind (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* H: fork. The child's table holds its own reference per descriptor, so two descriptors of one file in the child must be closed
     * independently: the child closes both and exits, and the parent still reads and writes the file through its own descriptor.
     * (A reference count that is one short lets the child's closes recycle the entry under the parent's feet.) */
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    write(fd, "abc", 3);
    fd2 = (int)open("/tmp/h241f", O_RDONLY, 0);
    long kid = fork();
    if (kid == 0) {
        close(fd);
        close(fd2);
        _exit(0);
    }
    int st_k = 0;
    waitpid(kid, &st_k, 0);
    {
        char r3[4] = {0};
        lseek(fd, 0, SEEK_SET);
        long a3 = read(fd, r3, 3);
        long w3 = write(fd, "def", 3);
        lseek(fd2, 0, SEEK_SET);
        char r4[8] = {0};
        long a4 = read(fd2, r4, 6);
        snprintf(what, sizeof what, "H: after a child closed its copies of both descriptors the parent still reads \"%s\" (%ld), writes (%ld) and the other descriptor reads \"%s\" (%ld)", r3, a3, w3, r4, a4);
        check(a3 == 3 && memcmp(r3, "abc", 3) == 0 && w3 == 3 && a4 == 6 && memcmp(r4, "abcdef", 6) == 0, what);
    }
    close(fd);
    close(fd2);
    unlink("/tmp/h241f");
    n = free_entries();
    snprintf(what, sizeof what, "H: after fork, child exit and parent close the entry is back (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* H2: after fork, each side closes one of its two descriptors; the file must stay usable through the other (an undercounted
     * reference would let the entry be recycled while the parent's second descriptor is still open). */
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    write(fd, "abc", 3);
    fd2 = (int)open("/tmp/h241f", O_RDWR, 0);
    kid = fork();
    if (kid == 0) {
        close(fd);
        close(fd2);
        _exit(0);
    }
    waitpid(kid, &st_k, 0);
    close(fd);
    unlink("/tmp/h241f");
    {
        char r5[4] = {0};
        lseek(fd2, 0, SEEK_SET);
        long a5 = read(fd2, r5, 3);
        int mid = free_entries();
        snprintf(what, sizeof what, "H2: the child closed both, the parent closed one and unlinked: the other still reads \"%s\" (%ld) and the entry is still held (%d free, baseline %d)", r5, a5, mid, base);
        check(a5 == 3 && memcmp(r5, "abc", 3) == 0 && mid == base - 1, what);
    }
    close(fd2);
    n = free_entries();
    snprintf(what, sizeof what, "H2: closing the last descriptor returns the entry (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* I: the child exits without closing: the kernel closes its descriptors, one release each */
    fd = (int)open("/tmp/h241f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    fd2 = (int)open("/tmp/h241f", O_RDONLY, 0);
    kid = fork();
    if (kid == 0) _exit(0);
    waitpid(kid, &st_k, 0);
    close(fd);
    close(fd2);
    unlink("/tmp/h241f");
    n = free_entries();
    snprintf(what, sizeof what, "I: a child that exits holding two descriptors of one file releases both (%d free, baseline %d)", n, base);
    check(n == base, what);

    print(failures == 0 ? "hello241: PASS\n" : "hello241: FAIL\n");
    return failures;
}
