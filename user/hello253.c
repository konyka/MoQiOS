/* hello253: /proc/self names the calling process. Measured on Linux: /proc/self/status opens and its Pid line is getpid(); it matches the
 * same file opened by the numeric pid; an unknown file under /proc/self, an unknown name under /proc, and /proc/selfx/status are ENOENT. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello253:   ok   " : "hello253:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

/* The value after "Pid:" in a status file, or -1. */
static long pid_line(const char *path) {
    char b[1024];
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return -1;
    memset(b, 0, sizeof b);
    long n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return -1;
    char *p = strstr(b, "Pid:");
    if (!p) return -1;
    p += 4;
    while (*p == ' ' || *p == '\t') p++;
    return atol(p);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello253: /proc/self\n");
    char what[200];
    long me = getpid();
    char numeric[64];
    snprintf(numeric, sizeof numeric, "/proc/%ld/status", me);

    long viaself = pid_line("/proc/self/status");
    long vianum = pid_line(numeric);
    snprintf(what, sizeof what, "/proc/self/status opens and its Pid is getpid() (self %ld, numeric %ld, getpid %ld)", viaself, vianum, me);
    check(viaself == me && vianum == me, what);

    int fd = (int)open("/proc/self/cmdline", O_RDONLY, 0);
    snprintf(what, sizeof what, "/proc/self/cmdline opens (fd %d)", fd);
    check(fd >= 0, what);
    if (fd >= 0) close(fd);

    long e1 = open("/proc/self/nonesuch", O_RDONLY, 0);
    snprintf(what, sizeof what, "an unknown file under /proc/self is ENOENT (open returned %ld)", e1);
    check(e1 == -ENOENT, what);

    long e2 = open("/proc/selfx/status", O_RDONLY, 0);
    snprintf(what, sizeof what, "/proc/selfx/status is not /proc/self: ENOENT (open returned %ld)", e2);
    check(e2 == -ENOENT, what);

    long e3 = open("/proc/nonesuch", O_RDONLY, 0);
    snprintf(what, sizeof what, "an unknown name under /proc is ENOENT (open returned %ld)", e3);
    check(e3 == -ENOENT, what);

    long child = fork();
    if (child == 0) {
        long cs = pid_line("/proc/self/status");
        _exit(cs == getpid() ? 0 : 1);
    }
    int st = 0;
    waitpid(child, &st, 0);
    snprintf(what, sizeof what, "a forked child's /proc/self is the child, not the parent (exit status %d)", (st >> 8) & 0xff);
    check(((st >> 8) & 0xff) == 0 && (st & 0x7f) == 0, what);

    /* Another user's process. Measured on Linux as an unprivileged user: /proc/1/maps is EACCES (reading a process's memory layout needs
     * ptrace access to it), while status and cmdline of a process of another user open. The same user's own processes open all of them. */
    long target = getpid();
    long owner_exit = -1;
    int sync[2];
    pipe(sync);
    long kid = fork();
    if (kid == 0) {
        long u = syscall1(174, 1000); /* setuid(1000): this probe starts as root with CAP_SETUID only (see capability_profile.zig) */
        char p1[64];
        snprintf(p1, sizeof p1, "/proc/%ld/maps", target);
        long maps = open(p1, O_RDONLY, 0);
        snprintf(p1, sizeof p1, "/proc/%ld/status", target);
        long status = open(p1, O_RDONLY, 0);
        long own = open("/proc/self/maps", O_RDONLY, 0);
        char out[3] = { maps == -EACCES ? 1 : 0, status >= 0 ? 1 : 0, own >= 0 ? 1 : 0 };
        (void)u;
        write(sync[1], out, 3);
        _exit(0);
    }
    char got[3] = { 0, 0, 0 };
    read(sync[0], got, 3);
    waitpid(kid, &st, 0);
    snprintf(what, sizeof what, "an unprivileged user cannot read another user's /proc/<pid>/maps: EACCES (denied %d)", got[0]);
    check(got[0] == 1, what);
    snprintf(what, sizeof what, "but can read its status (opens %d) and its own maps (opens %d)", got[1], got[2]);
    check(got[1] == 1 && got[2] == 1, what);
    (void)owner_exit;

    print(failures == 0 ? "hello253: PASS\n" : "hello253: FAIL\n");
    return failures;
}
