/* hello250: an open directory stream sees entries added and removed through other paths, on ext2 (testdir/) and tmpfs (/tmp). Measured
 * on Linux: after opendir of an empty directory, creating 100 files and rewinddir, readdir returns the two dot entries plus all 100
 * names; after unlinking half it returns the dots plus the other half; after unlinking the rest, only the dots. The ext2 fixture has
 * only 128 inodes, so the number of files that fit varies; the checks are relative to the number actually created. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/dirent.h"
#include "../lib/moqi_libc/include/stat.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello250:   ok   " : "hello250:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

#define NFILES 100

static int count_entries(DIR *d, int *seen_mask_bad) {
    int n = 0;
    struct dirent *e;
    rewinddir(d);
    while ((e = readdir(d)) != (struct dirent *)0) {
        n++;
        if (seen_mask_bad != (int *)0 && e->d_name[0] != '.' && strncmp(e->d_name, "entry-number-", 13) != 0) (*seen_mask_bad)++;
    }
    return n;
}

static void name_of(char *out, size_t cap, const char *dir, int i) {
    snprintf(out, cap, "%s/entry-number-%04d-padding", dir, i);
}

static void run(const char *label, const char *dir) {
    char what[200];
    char path[96];
    if (mkdir(dir, 0755) != 0) { snprintf(what, sizeof what, "%s: mkdir %s failed", label, dir); check(0, what); return; }
    DIR *d = opendir(dir);
    if (d == (DIR *)0) { snprintf(what, sizeof what, "%s: opendir failed (%d)", label, errno); check(0, what); rmdir(dir); return; }
    int bad = 0;
    int base = count_entries(d, &bad);
    snprintf(what, sizeof what, "%s: an empty directory lists only its dot entries (%d)", label, base);
    check(base == 2 && bad == 0, what);

    int made = 0;
    int create_err = 0;
    for (int i = 0; i < NFILES; i++) {
        name_of(path, sizeof path, dir, i);
        int fd = (int)open(path, O_RDWR | O_CREAT, 0600);
        if (fd < 0) { create_err = fd; break; }
        close(fd);
        made++;
    }
    {
        struct dirent *e;
        int k = 0;
        long last_off = 0;
        char last_name[40] = "";
        rewinddir(d);
        while ((e = readdir(d)) != (struct dirent *)0) { k++; last_off = e->d_off; strncpy(last_name, e->d_name, 39); last_name[39] = 0; }
        snprintf(what, sizeof what, "%s: diagnostic: listing ends after %d entries at d_off %ld, last name %s", label, k, last_off, last_name);
        print("hello250:   info "); print(what); print("\n");
    }
    int openable = 0;
    for (int i = 0; i < made; i++) {
        name_of(path, sizeof path, dir, i);
        int t = (int)open(path, O_RDONLY, 0);
        if (t >= 0) { openable++; close(t); }
    }
    struct stat dst;
    long dsz = stat(dir, &dst) == 0 ? (long)dst.st_size : -1;
    snprintf(what, sizeof what, "%s: every created file can be opened by name (%d of %d), directory size %ld", label, openable, made, dsz);
    check(openable == made, what);
    bad = 0;
    int n = count_entries(d, &bad);
    snprintf(what, sizeof what, "%s: after creating %d files the open stream lists them all (%d entries, %d unexpected, create error %d)", label, made, n, bad, create_err);
    check(made >= 30 && n == base + made && bad == 0, what);

    int removed = 0;
    for (int i = 0; i < made; i += 2) {
        name_of(path, sizeof path, dir, i);
        if (unlink(path) == 0) removed++;
    }
    n = count_entries(d, (int *)0);
    snprintf(what, sizeof what, "%s: after unlinking %d of the %d files the open stream lists the rest (%d entries)", label, removed, made, n);
    check(removed == (made + 1) / 2 && n == base + made - removed, what);

    for (int i = 1; i < made; i += 2) {
        name_of(path, sizeof path, dir, i);
        unlink(path);
    }
    n = count_entries(d, (int *)0);
    snprintf(what, sizeof what, "%s: after unlinking all the open stream lists only the dot entries (%d entries)", label, n);
    check(n == base, what);

    closedir(d);
    rmdir(dir);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello250: a directory stream follows changes made through other paths\n");
    run("tmpfs", "/tmp/h250d");
    run("ext2", "testdir/h250e");
    print(failures == 0 ? "hello250: PASS\n" : "hello250: FAIL\n");
    return failures;
}
