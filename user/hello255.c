/* hello255: the root directory lists the trees that hang off it. Measured on Linux: opendir("/") lists "." and "..", and the top-level
 * directories such as tmp, dev and proc (DT_DIR); "." in a process whose working directory is "/" lists the same entries as "/". */
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
    print(ok ? "hello255:   ok   " : "hello255:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

struct seen { int n, dot, dotdot, tmp, dev, proc, testdir; int tmp_type, dev_type, proc_type; };

static void scan(const char *path, struct seen *s, int *opened) {
    memset(s, 0, sizeof *s);
    s->tmp_type = s->dev_type = s->proc_type = -1;
    DIR *d = opendir(path);
    *opened = d != (DIR *)0;
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != (struct dirent *)0) {
        s->n++;
        if (!strcmp(e->d_name, ".")) s->dot = 1;
        else if (!strcmp(e->d_name, "..")) s->dotdot = 1;
        else if (!strcmp(e->d_name, "tmp")) { s->tmp++; s->tmp_type = e->d_type; }
        else if (!strcmp(e->d_name, "dev")) { s->dev++; s->dev_type = e->d_type; }
        else if (!strcmp(e->d_name, "proc")) { s->proc++; s->proc_type = e->d_type; }
        else if (!strcmp(e->d_name, "testdir")) s->testdir = 1;
    }
    closedir(d);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello255: the root directory\n");
    char what[240];
    struct seen a, b;
    int oa, ob;
    scan("/", &a, &oa);
    snprintf(what, sizeof what, "opendir(/) opens and lists . and .. (opened %d, entries %d, dot %d, dotdot %d)", oa, a.n, a.dot, a.dotdot);
    check(oa && a.dot && a.dotdot, what);
    snprintf(what, sizeof what, "it lists tmp, dev and proc once each, as directories (tmp %d/%d, dev %d/%d, proc %d/%d; DT_DIR is %d)", a.tmp, a.tmp_type, a.dev, a.dev_type, a.proc, a.proc_type, DT_DIR);
    check(a.tmp == 1 && a.dev == 1 && a.proc == 1 && a.tmp_type == DT_DIR && a.dev_type == DT_DIR && a.proc_type == DT_DIR, what);
    snprintf(what, sizeof what, "it lists the ext2 fixture's testdir (found %d)", a.testdir);
    check(a.testdir, what);

    /* rewinddir after the end, and a second full pass, must give the same list (the virtual tail must not stick). */
    DIR *rd = opendir("/");
    int first = 0, second = 0;
    if (rd) {
        while (readdir(rd) != (struct dirent *)0) first++;
        rewinddir(rd);
        while (readdir(rd) != (struct dirent *)0) second++;
        closedir(rd);
    }
    snprintf(what, sizeof what, "rewinddir gives the same list again (first %d, second %d)", first, second);
    check(first == a.n && second == a.n, what);

    char cwd[128];
    getcwd(cwd, sizeof cwd);
    chdir("/");
    scan(".", &b, &ob);
    snprintf(what, sizeof what, "opendir(.) from / lists the same entries as / (entries %d vs %d, opened %d)", b.n, a.n, ob);
    check(ob && b.n == a.n, what);
    chdir(cwd);

    struct stat st;
    memset(&st, 0, sizeof st);
    int r = stat("/", &st);
    snprintf(what, sizeof what, "stat(/) is a directory (rc %d, mode 0%o)", r, st.st_mode);
    check(r == 0 && S_ISDIR(st.st_mode), what);

    print(failures == 0 ? "hello255: PASS\n" : "hello255: FAIL\n");
    return failures;
}
