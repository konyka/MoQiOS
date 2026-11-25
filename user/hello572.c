/* hello572: /proc/<pid>/statm exists and reports seven page counts (Linux fs/proc/array.c proc_pid_statm: size resident shared
 * text lib data dt). The kernel had no statm file at all (open returned ENOENT). MoQiOS fills size (VmSize), resident (VmRSS),
 * shared 0, text (VmExe), lib 0, data (VmData+VmStk), dt 0. A: the file opens and has exactly seven space-separated numbers;
 * B: size >= resident, text > 0, and (on the target) shared/lib/dt are 0; C: the data field is positive (heap + stack pages). */
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
    print(ok ? "hello572:   ok   " : "hello572:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
int main(void) {
    print("hello572: /proc/<pid>/statm\n");
    static char buf[256];
    int fd = (int)open("/proc/self/statm", O_RDONLY, 0);
    long n = fd >= 0 ? (long)read(fd, buf, sizeof buf - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) { check(0, "A: /proc/self/statm opens and reads"); print("hello572: FAIL\n"); return 1; }
    buf[n] = 0;

    /* Parse seven whitespace-separated numbers. */
    long v[8];
    int nf = 0;
    const char *p = buf;
    while (nf < 8) {
        while (*p == ' ' || *p == '\t' || *p == '\n') p++;
        if (*p < '0' || *p > '9') break;
        long x = 0;
        while (*p >= '0' && *p <= '9') { x = x * 10 + (*p - '0'); p++; }
        v[nf++] = x;
    }
    snprintf(msg, sizeof msg, "A: statm has 7 fields (got %d: %ld %ld %ld %ld %ld %ld %ld)",
             nf, nf > 0 ? v[0] : -1, nf > 1 ? v[1] : -1, nf > 2 ? v[2] : -1, nf > 3 ? v[3] : -1,
             nf > 4 ? v[4] : -1, nf > 5 ? v[5] : -1, nf > 6 ? v[6] : -1);
    check(nf == 7, msg);
    if (nf != 7) { print("hello572: FAIL\n"); return 1; }

    /* size resident shared text lib data dt */
    snprintf(msg, sizeof msg, "B: size %ld >= resident %ld, text %ld > 0", v[0], v[1], v[3]);
#ifdef HOST
    check(v[0] >= v[1] && v[3] > 0, msg);
#else
    /* On the target: no shared file mappings, no lib, no dirty accounting. */
    snprintf(msg, sizeof msg, "B: size %ld >= resident %ld, text %ld > 0, shared %ld lib %ld dt %ld all 0",
             v[0], v[1], v[3], v[2], v[4], v[6]);
    check(v[0] >= v[1] && v[3] > 0 && v[2] == 0 && v[4] == 0 && v[6] == 0, msg);
#endif

    snprintf(msg, sizeof msg, "C: data field (heap+stack pages) positive (%ld)", v[5]);
    check(v[5] > 0, msg);

    print(failures ? "hello572: FAIL\n" : "hello572: PASS\n");
    return failures ? 1 : 0;
}
