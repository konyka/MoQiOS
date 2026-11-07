/* hello254: /proc as a directory. Measured on Linux: stat("/proc") is a directory (mode 0555); stat of /proc/meminfo is a regular file
 * (0444, size 0); stat of /proc/<pid> and /proc/self succeeds; opendir("/proc") lists "." and "..", meminfo (DT_REG), the numeric pid of a
 * live process (DT_DIR) and self (DT_LNK); opendir("/proc/<pid>") lists status; opendir("/proc/meminfo") is ENOTDIR. */
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
    print(ok ? "hello254:   ok   " : "hello254:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello254: /proc as a directory\n");
    char what[220];
    struct stat st;
    char me[16], mydir[32];
    snprintf(me, sizeof me, "%ld", getpid());
    snprintf(mydir, sizeof mydir, "/proc/%s", me);

    memset(&st, 0, sizeof st);
    int r = stat("/proc", &st);
    snprintf(what, sizeof what, "stat(/proc) is a directory (rc %d, mode 0%o)", r, st.st_mode);
    check(r == 0 && S_ISDIR(st.st_mode), what);

    memset(&st, 0, sizeof st);
    r = stat("/proc/meminfo", &st);
    snprintf(what, sizeof what, "stat(/proc/meminfo) is a regular file (rc %d, mode 0%o)", r, st.st_mode);
    check(r == 0 && S_ISREG(st.st_mode), what);

    memset(&st, 0, sizeof st);
    r = stat(mydir, &st);
    snprintf(what, sizeof what, "stat(/proc/<pid>) is a directory (rc %d, mode 0%o)", r, st.st_mode);
    check(r == 0 && S_ISDIR(st.st_mode), what);

    r = stat("/proc/self", &st);
    snprintf(what, sizeof what, "stat(/proc/self) succeeds (rc %d)", r);
    check(r == 0, what);

    DIR *d = opendir("/proc");
    int n = 0, mem = 0, pid = 0, self = 0, dots = 0, mem_type = -1, pid_type = -1, self_type = -1;
    if (d != (DIR *)0) {
        struct dirent *e;
        while ((e = readdir(d)) != (struct dirent *)0) {
            n++;
            if (strcmp(e->d_name, "meminfo") == 0) { mem = 1; mem_type = e->d_type; }
            if (strcmp(e->d_name, me) == 0) { pid = 1; pid_type = e->d_type; }
            if (strcmp(e->d_name, "self") == 0) { self = 1; self_type = e->d_type; }
            if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) dots++;
        }
        closedir(d);
    }
    snprintf(what, sizeof what, "opendir(/proc) lists . and .. (opened %d, entries %d, dots %d)", d != (DIR *)0, n, dots);
    check(d != (DIR *)0 && dots == 2, what);
    snprintf(what, sizeof what, "it lists meminfo as DT_REG (found %d, d_type %d)", mem, mem_type);
    check(mem == 1 && mem_type == DT_REG, what);
    snprintf(what, sizeof what, "it lists this process's pid as DT_DIR (found %d, d_type %d)", pid, pid_type);
    check(pid == 1 && pid_type == DT_DIR, what);
    snprintf(what, sizeof what, "it lists self as DT_LNK (found %d, d_type %d)", self, self_type);
    check(self == 1 && self_type == DT_LNK, what);

    d = opendir(mydir);
    int status = 0;
    if (d != (DIR *)0) {
        struct dirent *e;
        while ((e = readdir(d)) != (struct dirent *)0) if (strcmp(e->d_name, "status") == 0) status = 1;
        closedir(d);
    }
    snprintf(what, sizeof what, "opendir(/proc/<pid>) lists status (opened %d, status %d)", d != (DIR *)0, status);
    check(d != (DIR *)0 && status == 1, what);

    d = opendir("/proc/meminfo");
    snprintf(what, sizeof what, "opendir(/proc/meminfo) is ENOTDIR (opened %d, errno %d)", d != (DIR *)0, errno);
    check(d == (DIR *)0 && errno == ENOTDIR, what);
    if (d) closedir(d);

    /* A process that is gone has no directory (Linux: ENOENT). The pid is the child's, reaped before the lookup. */
    long kid = fork();
    if (kid == 0) _exit(0);
    int stt = 0;
    waitpid(kid, &stt, 0);
    char gone[32];
    snprintf(gone, sizeof gone, "/proc/%ld", kid);
    r = stat(gone, &st);
    snprintf(what, sizeof what, "a reaped process has no /proc directory (stat rc %d)", r);
    check(r != 0, what);

    struct statfs sf;
    memset(&sf, 0, sizeof sf);
    r = statfs("/proc", &sf);
    snprintf(what, sizeof what, "statfs(/proc) reports PROC_SUPER_MAGIC (rc %d, type 0x%lx)", r, (unsigned long)sf.f_type);
    check(r == 0 && sf.f_type == 0x9fa0, what);

    print(failures == 0 ? "hello254: PASS\n" : "hello254: FAIL\n");
    return failures;
}
