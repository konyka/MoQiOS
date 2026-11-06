/* hello246: FAT32 root files (bare names). Slot lifecycle (the table has 64 slots): creating, opening twice and closing return the slot, and
 * stat of an open file does not pin it. Descriptor coherence, measured on Linux: a second descriptor of a file sees what the first wrote at
 * once (size, SEEK_END and read), a write through either is visible to the other, and after unlink every still-open descriptor keeps
 * reading and writing the file until the last one is closed. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello246:   ok   " : "hello246:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int free_slots(void) {
    char nm[24];
    int n = 0;
    for (int i = 0; i < 100; i++) {
        snprintf(nm, sizeof nm, "h246s%d", i);
        int s = (int)open(nm, O_RDWR | O_CREAT, 0600);
        if (s < 0) break;
        close(s);
        n++;
    }
    for (int i = 0; i < n; i++) {
        snprintf(nm, sizeof nm, "h246s%d", i);
        unlink(nm);
    }
    return n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello246: FAT32 slots and lifecycle\n");
    char what[200];
    struct stat st;

    int base = free_slots();
    snprintf(what, sizeof what, "A: free FAT32 file slots can be measured (%d)", base);
    check(base >= 4, what);

    int fd = (int)open("h246f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    check(fd >= 0, "B: create file in FAT32 root");
    write(fd, "abc", 3);
    close(fd);
    unlink("h246f");
    int n = free_slots();
    snprintf(what, sizeof what, "B: create, write, close, unlink gives the slot back (%d free, baseline %d)", n, base);
    check(n == base, what);

    fd = (int)open("h246f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    stat("h246f", &st);
    close(fd);
    unlink("h246f");
    n = free_slots();
    snprintf(what, sizeof what, "C: stat of an open file does not pin the slot (%d free, baseline %d)", n, base);
    check(n == base, what);

    fd = (int)open("h246f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    int fd2 = (int)open("h246f", O_RDONLY, 0);
    close(fd);
    close(fd2);
    unlink("h246f");
    n = free_slots();
    snprintf(what, sizeof what, "D: two opens closed first-then-second (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* E: the second descriptor sees the first one's staged writes */
    fd = (int)open("h246f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    write(fd, "abc", 3);
    fd2 = (int)open("h246f", O_RDWR, 0);
    fstat(fd2, &st);
    long se = lseek(fd2, 0, SEEK_END);
    lseek(fd2, 0, SEEK_SET);
    char r1[8] = {0};
    long rn = read(fd2, r1, 8);
    snprintf(what, sizeof what, "E: a second descriptor sees the 3 bytes the first wrote (fstat %ld, SEEK_END %ld, read %ld \"%s\")", (long)st.st_size, se, rn, r1);
    check(st.st_size == 3 && se == 3 && rn == 3 && memcmp(r1, "abc", 3) == 0, what);
    write(fd, "def", 3);
    lseek(fd2, 0, SEEK_SET);
    memset(r1, 0, sizeof r1);
    rn = read(fd2, r1, 8);
    snprintf(what, sizeof what, "E: and a later write through the first shows up too (read %ld \"%s\")", rn, r1);
    check(rn == 6 && memcmp(r1, "abcdef", 6) == 0, what);
    lseek(fd2, 0, SEEK_END);
    write(fd2, "!", 1);
    lseek(fd, 0, SEEK_SET);
    memset(r1, 0, sizeof r1);
    rn = read(fd, r1, 8);
    snprintf(what, sizeof what, "E: a write through the second is visible to the first (read %ld \"%s\")", rn, r1);
    check(rn == 7 && memcmp(r1, "abcdef!", 7) == 0, what);

    /* F: unlink while open: both descriptors keep the data; the slot comes back at the last close */
    unlink("h246f");
    lseek(fd, 0, SEEK_SET);
    lseek(fd2, 0, SEEK_SET);
    char ra[8] = {0}, rb[8] = {0};
    long na = read(fd, ra, 8), nb = read(fd2, rb, 8);
    snprintf(what, sizeof what, "F: after unlink both descriptors still read the file (%ld \"%s\", %ld \"%s\")", na, ra, nb, rb);
    check(na == 7 && nb == 7 && memcmp(ra, "abcdef!", 7) == 0 && memcmp(rb, "abcdef!", 7) == 0, what);
    close(fd);
    lseek(fd2, 0, SEEK_SET);
    memset(rb, 0, sizeof rb);
    nb = read(fd2, rb, 8);
    snprintf(what, sizeof what, "F: after one is closed the other still reads it (%ld \"%s\")", nb, rb);
    check(nb == 7 && memcmp(rb, "abcdef!", 7) == 0, what);
    close(fd2);
    n = free_slots();
    snprintf(what, sizeof what, "F: the slot is back after the last close (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* G: dup keeps the file alive after the original is closed and the name is gone */
    fd = (int)open("h246f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    write(fd, "abc", 3);
    int d = (int)dup(fd);
    close(fd);
    unlink("h246f");
    {
        char r4[4] = {0}, r5[8] = {0};
        lseek(d, 0, SEEK_SET);
        long b1 = read(d, r4, 3);
        long w1 = write(d, "XYZ", 3);
        lseek(d, 0, SEEK_SET);
        long b2 = read(d, r5, 6);
        snprintf(what, sizeof what, "G: the dup reads \"%s\" (%ld), writes (%ld) and reads back \"%s\" (%ld)", r4, b1, w1, r5, b2);
        check(b1 == 3 && memcmp(r4, "abc", 3) == 0 && w1 == 3 && b2 == 6 && memcmp(r5, "abcXYZ", 6) == 0, what);
    }
    close(d);
    n = free_slots();
    snprintf(what, sizeof what, "G: closing the last descriptor returns the slot (%d free, baseline %d)", n, base);
    check(n == base, what);

    /* H: fork. The child closes its copies; the parent's descriptors stay valid and keep the slot */
    fd = (int)open("h246f", O_RDWR | O_CREAT | O_TRUNC, 0600);
    write(fd, "abc", 3);
    fd2 = (int)open("h246f", O_RDWR, 0);
    long kid = fork();
    if (kid == 0) {
        close(fd);
        close(fd2);
        _exit(0);
    }
    int stk = 0;
    waitpid(kid, &stk, 0);
    close(fd);
    unlink("h246f");
    {
        char r6[4] = {0};
        lseek(fd2, 0, SEEK_SET);
        long c1 = read(fd2, r6, 3);
        int held = free_slots();
        snprintf(what, sizeof what, "H: after the child closed both and the parent closed one and unlinked, the other still reads \"%s\" (%ld) and holds the slot (%d free, baseline %d)", r6, c1, held, base);
        check(c1 == 3 && memcmp(r6, "abc", 3) == 0 && held == base - 1, what);
    }
    close(fd2);
    n = free_slots();
    snprintf(what, sizeof what, "H: the slot is back after the last close (%d free, baseline %d)", n, base);
    check(n == base, what);

    print(failures == 0 ? "hello246: PASS\n" : "hello246: FAIL\n");
    return failures;
}
