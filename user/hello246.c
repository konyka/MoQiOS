/* hello246: FAT32 root files follow the slot and descriptor lifecycle (64 slots max in files[]). Creating, opening twice, and closing
 * returns the slot correctly; stat of an open file does not pin it. */
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

    print(failures == 0 ? "hello246: PASS\n" : "hello246: FAIL\n");
    return failures;
}
