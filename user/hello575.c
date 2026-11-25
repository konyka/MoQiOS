/* hello575: /proc/<pid>/stat fields 14 (utime) and 15 (stime) carry real CPU time in clock ticks (100 Hz). The kernel left them 0.
 * utime is the process's user CPU time; after burning CPU in user mode it must be positive and must not go backwards. A: the stat
 * line has >= 15 fields and field 14 parses; B: after a busy loop in user mode, utime > 0; C: a second read after more busy work
 * gives a utime no smaller than the first (monotonic). */
#ifdef HOST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello575:   ok   " : "hello575:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
/* Read /proc/self/stat and return field 14 (utime), or -1 on parse failure. */
static long utime_field(void) {
    static char buf[1024];
    int fd = (int)open("/proc/self/stat", O_RDONLY, 0);
    long n = fd >= 0 ? (long)read(fd, buf, sizeof buf - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *rp = strrchr(buf, ')');
    if (!rp) return -1;
    const char *q = rp + 1;
    int tok = 0; /* token 1 = field 3 */
    long val = -1;
    while (*q) {
        while (*q == ' ') q++;
        if (*q == 0 || *q == '\n') break;
        tok++;
        long x = 0; int got = 0;
        const char *s = q;
        while (*s >= '0' && *s <= '9') { x = x * 10 + (*s - '0'); s++; got = 1; }
        if (tok == 14 - 2) { val = got ? x : -1; break; } /* field 14 */
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
int main(void) {
    print("hello575: /proc/<pid>/stat utime/stime\n");
    long a = utime_field();
    snprintf(msg, sizeof msg, "A: utime field present (%ld)", a);
    check(a >= 0, msg);
    if (a < 0) { print("hello575: FAIL\n"); return 1; }

    burn(80000000UL);
    long b = utime_field();
    snprintf(msg, sizeof msg, "B: utime positive after a user-mode busy loop (%ld -> %ld)", a, b);
    check(b > 0, msg);

    burn(80000000UL);
    long c = utime_field();
    snprintf(msg, sizeof msg, "C: utime does not go backwards (%ld -> %ld)", b, c);
    check(c >= b, msg);

    print(failures ? "hello575: FAIL\n" : "hello575: PASS\n");
    return failures ? 1 : 0;
}
