/* hello252: a directory can grow past twelve blocks, on ext2 (testdir/) and tmpfs (/tmp). Measured on Linux: 56 entries with 240-byte names
 * (14 KiB of directory records, more than the twelve direct blocks an ext2 inode holds at 1 KiB per block) are all created, listed (the
 * entries plus the dot entries), openable by name and removable, and the emptied directory is removed. On ext2 the entries are hard
 * links to one file, because the fixture has only 128 inodes. Names are relative to a chdir into the directory because a path is
 * limited to 255 bytes and "testdir/h252e/" plus a 240-byte name is not. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/dirent.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static long free_blocks(const char *path) {
    struct statfs f;
    memset(&f, 0, sizeof f);
    if (statfs(path, &f) != 0) return -1;
    return (long)f.f_bfree;
}
static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello252:   ok   " : "hello252:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void entry_name(char *nm, int namelen, int i) {
    memset(nm, 'n', (size_t)namelen);
    nm[namelen] = 0;
    snprintf(nm + namelen - 10, 11, "%010d", i);
}

static void run(const char *label, const char *dir, int namelen, int want, int use_links) {
    char what[200];
    char nm[300];
    char cwd[128];
    long free_before = free_blocks(dir[0] == '/' ? "/tmp" : "testdir");
    if (mkdir(dir, 0755) != 0) { snprintf(what, sizeof what, "%s: mkdir %s failed", label, dir); check(0, what); return; }
    getcwd(cwd, sizeof cwd);
    if (chdir(dir) != 0) { snprintf(what, sizeof what, "%s: chdir %s failed", label, dir); check(0, what); rmdir(dir); return; }

    int made = 0;
    int err = 0;
    int base_fd = -1;
    if (use_links) {
        base_fd = (int)open("base", O_RDWR | O_CREAT, 0600);
        if (base_fd < 0) err = base_fd;
    }
    for (int i = 0; i < want && err == 0; i++) {
        entry_name(nm, namelen, i);
        if (use_links) {
            int lr = link("base", nm);
            if (lr != 0) { err = lr; break; }
        } else {
            int fd = (int)open(nm, O_RDWR | O_CREAT, 0600);
            if (fd < 0) { err = fd; break; }
            close(fd);
        }
        made++;
    }
    int extra = use_links ? 1 : 0; /* the base file itself is an entry too */
    snprintf(what, sizeof what, "%s: %d %s with %d-byte names are created (made %d, error %d)", label, want, use_links ? "hard links" : "files", namelen, made, err);
    check(made == want, what);

    DIR *d = opendir(".");
    int listed = 0;
    if (d != (DIR *)0) {
        while (readdir(d) != (struct dirent *)0) listed++;
        closedir(d);
    }
    snprintf(what, sizeof what, "%s: the directory lists all of them and the dot entries (%d of %d)", label, listed, made + extra + 2);
    check(listed == made + extra + 2, what);

    int opened = 0;
    for (int i = 0; i < made; i++) {
        entry_name(nm, namelen, i);
        int fd = (int)open(nm, O_RDONLY, 0);
        if (fd >= 0) { opened++; close(fd); }
    }
    snprintf(what, sizeof what, "%s: every one opens by name (%d of %d)", label, opened, made);
    check(opened == made, what);

    int gone = 0;
    for (int i = 0; i < made; i++) {
        entry_name(nm, namelen, i);
        if (unlink(nm) == 0) gone++;
    }
    if (use_links) {
        close(base_fd);
        unlink("base");
    }
    chdir(cwd);
    long rr = rmdir(dir);
    snprintf(what, sizeof what, "%s: all are removed and so is the directory (%d unlinked, rmdir %ld)", label, gone, rr);
    check(gone == made && rr == 0, what);
    long free_after = free_blocks(dir[0] == '/' ? "/tmp" : "testdir");
    snprintf(what, sizeof what, "%s: removing it returns every block, indirect ones included (free blocks %ld before, %ld after)", label, free_before, free_after);
    check(free_before >= 0 && free_after == free_before, what);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello252: a directory grows past twelve blocks\n");
    run("tmpfs", "/tmp/h252d", 50, 56, 0);
    run("ext2", "testdir/h252e", 240, 56, 1);
    print(failures == 0 ? "hello252: PASS\n" : "hello252: FAIL\n");
    return failures;
}
