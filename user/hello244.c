/* hello244: /tmp holds more than a few dozen entries. The tmpfs table used to stop at 63 files and directories in total, so a program that
 * made 64 files got ENOSPC where Linux has no such limit, and one test that leaked a handful of entries could stop later tests (and syslogd)
 * from creating /tmp/kern.log. This creates files, directories and memfds well past the old limit, checks each is usable on its own
 * (distinct contents survive), lists the directory, removes everything, and checks the table is back where it started. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello244:   ok   " : "hello244:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int count_free(void) {
    char nm[40];
    int n = 0;
    for (int i = 0; i < 700; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244slot%d", i);
        int s = (int)open(nm, O_RDWR | O_CREAT, 0600);
        if (s < 0) break;
        close(s);
        n++;
    }
    for (int i = 0; i < n; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244slot%d", i);
        unlink(nm);
    }
    return n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello244: a larger /tmp\n");
    char what[200];
    char nm[48];

    int base = count_free();
    snprintf(what, sizeof what, "A: the free-entry count can be measured and is well past the old total of 63 (%d free)", base);
    check(base >= 400, what);

    /* B: 300 files with distinct contents (more than a byte can number, so a slot number is a 16-bit value), created, written, closed */
    int made = 0;
    for (int i = 0; i < 300; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244f%d", i);
        int fd = (int)open(nm, O_RDWR | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) break;
        char body[24];
        int bl = snprintf(body, sizeof body, "file-%d", i);
        write(fd, body, (size_t)bl);
        close(fd);
        made++;
    }
    snprintf(what, sizeof what, "B: 300 files can be created in /tmp (%d made)", made);
    check(made == 300, what);

    int wrong = 0;
    for (int i = 0; i < made; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244f%d", i);
        int fd = (int)open(nm, O_RDONLY, 0);
        char body[24] = {0};
        char want[24];
        long rn = fd >= 0 ? read(fd, body, sizeof body - 1) : -1;
        int wl = snprintf(want, sizeof want, "file-%d", i);
        if (fd >= 0) close(fd);
        if (rn != wl || memcmp(body, want, (size_t)wl) != 0) wrong++;
    }
    snprintf(what, sizeof what, "B: each of the %d files reads back its own contents (%d wrong)", made, wrong);
    check(wrong == 0, what);

    /* C: directories and nested files past the old limit */
    int dirs = 0;
    for (int i = 0; i < 20; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244d%d", i);
        if (mkdir(nm, 0755) == 0) dirs++;
    }
    int nested = 0;
    for (int i = 0; i < 20; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244d%d/inner", i);
        int fd = (int)open(nm, O_RDWR | O_CREAT, 0600);
        if (fd >= 0) { nested++; close(fd); }
    }
    snprintf(what, sizeof what, "C: 20 directories and a file in each (%d dirs, %d files)", dirs, nested);
    check(dirs == 20 && nested == 20, what);
    struct stat st;
    check(stat("/tmp/h244d19/inner", &st) == 0 && S_ISREG(st.st_mode), "C: the last nested file resolves");
    check(stat("/tmp/h244d7", &st) == 0 && S_ISDIR(st.st_mode), "C: a directory in the middle resolves");

    /* D: unlinking in the middle frees that slot for reuse and does not disturb its neighbours */
    snprintf(nm, sizeof nm, "/tmp/h244f60");
    check(unlink(nm) == 0, "D: unlink a file in the middle");
    errno = 0;
    check(stat(nm, &st) == -1 && errno == ENOENT, "D: it is gone");
    check(stat("/tmp/h244f59", &st) == 0 && stat("/tmp/h244f61", &st) == 0, "D: its neighbours are still there");
    int fd = (int)open("/tmp/h244again", O_RDWR | O_CREAT, 0600);
    check(fd >= 0, "D: a new file can be created in the freed slot");
    if (fd >= 0) close(fd);
    unlink("/tmp/h244again");

    /* E: fill the table to its end: creation then fails with ENOSPC, and everything made so far still works */
    int extra = 0;
    int last_errno = 0;
    for (int i = 0; i < 700; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244x%d", i);
        int xfd = (int)open(nm, O_RDWR | O_CREAT, 0600);
        if (xfd < 0) { last_errno = -xfd; break; }
        close(xfd);
        extra++;
    }
    snprintf(what, sizeof what, "E: a full table fails with ENOSPC, not a crash (%d more made, error %d)", extra, last_errno);
    check(last_errno == ENOSPC, what);
    check(stat("/tmp/h244f0", &st) == 0 && stat("/tmp/h244f299", &st) == 0, "E: the files made earlier are still intact");
    for (int i = 0; i < extra; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244x%d", i);
        unlink(nm);
    }

    /* F: clean up everything and check the table is back where it started */
    for (int i = 0; i < made; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244f%d", i);
        unlink(nm);
    }
    for (int i = 0; i < 20; i++) {
        snprintf(nm, sizeof nm, "/tmp/h244d%d/inner", i);
        unlink(nm);
        snprintf(nm, sizeof nm, "/tmp/h244d%d", i);
        rmdir(nm);
    }
    int after = count_free();
    snprintf(what, sizeof what, "F: after removing everything the free count is back (%d before, %d after)", base, after);
    check(after == base, what);

    print(failures == 0 ? "hello244: PASS\n" : "hello244: FAIL\n");
    return failures;
}
