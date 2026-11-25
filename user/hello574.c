/* hello574: /proc/<pid>/stat field 22 (starttime, in clock ticks since boot). The kernel left it 0 for every process; Linux sets
 * it to when the process started, so a process that starts well after boot has a positive starttime, and one started later has a
 * starttime no smaller than an earlier one's. A: the stat line still has at least 24 fields and field 22 parses; B: starttime is
 * a non-negative number; C: a child forked now has a starttime >= this process's (it started no earlier). */
#ifdef HOST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/stdlib.h"
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello574:   ok   " : "hello574:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
/* Read /proc/PATH/stat and return field 22 (starttime), or -1 on any parse failure. */
static long starttime(const char *path) {
    static char buf[1024];
    int fd = (int)open(path, O_RDONLY, 0);
    long n = fd >= 0 ? (long)read(fd, buf, sizeof buf - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *rp = strrchr(buf, ')');
    if (!rp) return -1;
    const char *q = rp + 1;
    /* fields after ')': field 3 = state, so field k is the (k-2)th token here. starttime is field 22 => token 20. */
    int tok = 0;
    long val = -1;
    while (*q) {
        while (*q == ' ') q++;
        if (*q == 0 || *q == '\n') break;
        tok++; /* token 1 = field 3 */
        long sign = 1, x = 0; int got = 0;
        const char *s = q;
        if (*s == '-') { sign = -1; s++; }
        while (*s >= '0' && *s <= '9') { x = x * 10 + (*s - '0'); s++; got = 1; }
        if (tok == 22 - 2) { val = got ? sign * x : -1; break; } /* field 22 */
        while (*q != ' ' && *q != 0 && *q != '\n') q++;
    }
    return val;
}
int main(void) {
    print("hello574: /proc/<pid>/stat starttime (field 22)\n");
    long st = starttime("/proc/self/stat");
    snprintf(msg, sizeof msg, "A/B: starttime field present and positive (started after boot) (%ld)", st);
    check(st > 0, msg);

    long pid = fork();
    if (pid == 0) {
        /* child: report its own starttime through the exit path is awkward; write it to a file */
        long cst = starttime("/proc/self/stat");
        int fd = (int)open("/tmp/h574_child", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { char b[32]; int k = snprintf(b, sizeof b, "%ld\n", cst); write(fd, b, (unsigned)k); close(fd); }
        _exit(0);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    long cst = -1;
    {
        static char b[32];
        int fd = (int)open("/tmp/h574_child", O_RDONLY, 0);
        long n = fd >= 0 ? (long)read(fd, b, sizeof b - 1) : -1;
        if (fd >= 0) close(fd);
        if (n > 0) { b[n] = 0; cst = 0; for (const char *p = b; *p >= '0' && *p <= '9'; p++) cst = cst * 10 + (*p - '0'); }
    }
    unlink("/tmp/h574_child");
    snprintf(msg, sizeof msg, "C: a child forked later has starttime >= ours (%ld >= %ld)", cst, st);
    check(cst > 0 && st > 0 && cst >= st, msg);

    print(failures ? "hello574: FAIL\n" : "hello574: PASS\n");
    return failures ? 1 : 0;
}
