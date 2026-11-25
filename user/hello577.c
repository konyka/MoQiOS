/* hello577: /proc/<pid>/stat fields 18 (priority) and 19 (nice). The kernel left them 0; Linux reports priority = 20 + nice for a
 * normal task and the nice value itself. A: priority == 20 + nice holds; B: after setpriority(nice 5),
 * field 18 is 25 and field 19 is 5; C: after setpriority(nice -3), field 18 is 30 and field 19 is 10. */
#ifdef HOST
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/resource.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static int set_nice(int v) { return setpriority(PRIO_PROCESS, 0, v); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
static int set_nice(int v) { return (int)syscall3(233, 0, 0, (long)v); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello577:   ok   " : "hello577:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
/* fields 18 (priority) and 19 (nice) of /proc/self/stat into *prio/*nice; returns 0 on success, -1 on parse failure. */
static int prio_nice(long *prio, long *nice) {
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
    long vals[40];
    int nf = 0;
    while (nf < 40) {
        while (*q == ' ') q++;
        if (*q == 0 || *q == '\n') break;
        tok++;
        long sign = 1, x = 0;
        const char *s = q;
        if (*s == '-') { sign = -1; s++; }
        while (*s >= '0' && *s <= '9') { x = x * 10 + (*s - '0'); s++; }
        vals[nf++] = sign * x;
        while (*q != ' ' && *q != 0 && *q != '\n') q++;
    }
    if (nf < 17) return -1; /* need field 19 => index 16 */
    *prio = vals[18 - 3];
    *nice = vals[19 - 3];
    return 0;
}
int main(void) {
    print("hello577: /proc/<pid>/stat priority/nice (fields 18/19)\n");
    long prio = -99, nice = -99;

    if (prio_nice(&prio, &nice) != 0) { check(0, "A: fields parse"); print("hello577: FAIL\n"); return 1; }
    /* The process may be spawned at a non-default priority; only the invariant priority == 20 + nice must hold. */
    snprintf(msg, sizeof msg, "A: priority %ld == 20 + nice %ld", prio, nice);
    check(prio == 20 + nice, msg);

    int r = set_nice(5);
    prio_nice(&prio, &nice);
    snprintf(msg, sizeof msg, "B: setpriority(5) %d, then priority %ld, nice %ld (25, 5)", r, prio, nice);
    check(r == 0 && prio == 25 && nice == 5, msg);

    r = set_nice(10); /* raising nice is always allowed (no privilege needed) */
    prio_nice(&prio, &nice);
    snprintf(msg, sizeof msg, "C: setpriority(10) %d, then priority %ld, nice %ld (30, 10)", r, prio, nice);
    check(r == 0 && prio == 30 && nice == 10, msg);

    print(failures ? "hello577: FAIL\n" : "hello577: PASS\n");
    return failures ? 1 : 0;
}
