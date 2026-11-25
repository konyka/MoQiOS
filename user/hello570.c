/* hello570: /proc/<pid>/status has VmExe and VmLib lines (Linux fs/proc/task_mmu.c: executable code size and library size in kB,
 * right-aligned in eight columns, after VmStk and before VmSwap). The kernel printed neither. MoQiOS binaries are static (flat or
 * non-PIE ELF, no shared libraries), so VmLib is always 0 and VmExe is the executable segment size. A: VmExe exists and is a
 * positive kB value; B: VmLib exists and is 0; C: VmExe comes after VmStk and VmLib right after VmExe (Linux order); D: a kernel
 * thread (/proc/0/status) has no VmExe line. */
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
    print(ok ? "hello570:   ok   " : "hello570:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static long slurp(const char *path, char *buf, long cap) {
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return -1;
    long n = (long)read(fd, buf, cap - 1);
    close(fd);
    if (n < 0) n = 0;
    buf[n] = 0;
    return n;
}
/* The integer after `key` (e.g. "VmExe:") in `s`, or -1 if the line is absent or malformed. */
static long field(const char *s, const char *key) {
    const char *p = strstr(s, key);
    if (!p) return -1;
    p += strlen(key);
    while (*p == ' ' || *p == '\t') p++;
    long v = -1;
    while (*p >= '0' && *p <= '9') { if (v < 0) v = 0; v = v * 10 + (*p - '0'); p++; }
    while (*p == ' ') p++;
    if (v >= 0 && p[0] == 'k' && p[1] == 'B') return v;
    return -1;
}
int main(void) {
    print("hello570: /proc/<pid>/status VmExe and VmLib\n");
    static char buf[8192];
    long n = slurp("/proc/self/status", buf, sizeof buf);
    long exe = n > 0 ? field(buf, "VmExe:") : -1;
    long lib = n > 0 ? field(buf, "VmLib:") : -1;

    snprintf(msg, sizeof msg, "A: VmExe present and positive (%ld)", exe);
    check(exe > 0, msg);

    snprintf(msg, sizeof msg, "B: VmLib present and 0 (no shared libraries) (%ld)", lib);
#ifdef HOST
    /* On Linux a dynamically linked probe has a nonzero VmLib; only require the line to exist. */
    check(lib >= 0, msg);
#else
    check(lib == 0, msg);
#endif

    const char *stk = n > 0 ? strstr(buf, "\nVmStk:") : (void *)0;
    const char *pe = n > 0 ? strstr(buf, "\nVmExe:") : (void *)0;
    const char *pl = n > 0 ? strstr(buf, "\nVmLib:") : (void *)0;
    int order = stk && pe && pl && pe > stk && pl > pe;
    snprintf(msg, sizeof msg, "C: order VmStk < VmExe < VmLib (%d)", order);
    check(order, msg);

    long kn = slurp("/proc/0/status", buf, sizeof buf);
    if (kn > 0) {
        int no_vm = strstr(buf, "VmExe:") == (void *)0 && strstr(buf, "VmSize:") == (void *)0;
        check(no_vm, "D: a kernel thread (pid 0) has no Vm lines");
    } else {
        check(1, "D: (skipped: /proc/0 not readable)");
    }

    print(failures ? "hello570: FAIL\n" : "hello570: PASS\n");
    return failures ? 1 : 0;
}
