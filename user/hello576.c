/* hello576: /proc/<pid>/stat field 16 (cutime, CPU time of reaped children, clock ticks 100 Hz). The kernel left it 0. After a
 * child burns CPU and the parent waits for it, the parent's cutime must be positive (the child's user time is folded in on reap),
 * and must not drop after reaping a second child. A: field 16 parses and starts at 0 before any child; B: after reaping a
 * CPU-burning child, cutime > 0; C: after a second such child, cutime does not go backwards. */
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
    print(ok ? "hello576:   ok   " : "hello576:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
/* field 16 (cutime) of /proc/self/stat, or -1 on parse failure. */
static long cutime_field(void) {
    static char buf[1024];
    int fd = (int)open("/proc/self/stat", O_RDONLY, 0);
    long n = fd >= 0 ? (long)read(fd, buf, sizeof buf - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *rp = strrchr(buf, ')');
    if (!rp) return -1;
    const char *q = rp + 1;
    int tok = 0;
    long val = -1;
    while (*q) {
        while (*q == ' ') q++;
        if (*q == 0 || *q == '\n') break;
        tok++; /* token 1 = field 3 */
        long x = 0; int got = 0;
        const char *s = q;
        while (*s >= '0' && *s <= '9') { x = x * 10 + (*s - '0'); s++; got = 1; }
        if (tok == 16 - 2) { val = got ? x : -1; break; } /* field 16 */
        while (*q != ' ' && *q != 0 && *q != '\n') q++;
    }
    return val;
}
static volatile unsigned long sink;
static void burn(unsigned long n) {
    unsigned long x = 1;
    for (unsigned long i = 0; i < n; i++) x = x * 1103515245 + 12345 + i;
    sink = x;
}
static void run_burner_child(void) {
    long pid = fork();
    if (pid == 0) { burn(120000000UL); _exit(0); }
    int status = 0;
    waitpid(pid, &status, 0);
}
int main(void) {
    print("hello576: /proc/<pid>/stat cutime (field 16)\n");
    long a = cutime_field();
#ifdef HOST
    /* glibc may have reaped helper processes before main, so cutime can be nonzero here; only require the field to parse. */
    snprintf(msg, sizeof msg, "A: cutime field present (%ld)", a);
    check(a >= 0, msg);
#else
    snprintf(msg, sizeof msg, "A: cutime field present, 0 before any child (%ld)", a);
    check(a == 0, msg);
#endif

    run_burner_child();
    long b = cutime_field();
    snprintf(msg, sizeof msg, "B: cutime positive after reaping a CPU-burning child (%ld)", b);
    check(b > 0, msg);

    run_burner_child();
    long c = cutime_field();
    snprintf(msg, sizeof msg, "C: cutime does not go backwards after a second child (%ld -> %ld)", b, c);
    check(c >= b, msg);

    print(failures ? "hello576: FAIL\n" : "hello576: PASS\n");
    return failures ? 1 : 0;
}
