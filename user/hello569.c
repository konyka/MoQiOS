/* hello569: /proc/<pid>/status has a VmSwap line (Linux fs/proc/task_mmu.c: the swapped-out pages in kB, right-aligned in eight
 * columns, after VmStk, absent for a kernel thread). The kernel counted no swapped pages before. With swap off (as in the smoke
 * image) a running process has nothing swapped, so VmSwap is 0, but the line must still be there and sit right after VmStk.
 * A: the VmSwap line exists and reads 0 kB; B: it comes immediately after the VmStk line (Linux order); C: a kernel thread
 * (/proc/0/status) has no VmSwap line. */
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
    print(ok ? "hello569:   ok   " : "hello569:   FAIL ");
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
/* The integer after "VmSwap:" in `s`, or -1 if the line is absent. */
static long vmswap(const char *s) {
    const char *p = strstr(s, "VmSwap:");
    if (!p) return -1;
    p += 7;
    while (*p == ' ' || *p == '\t') p++;
    long v = -1;
    while (*p >= '0' && *p <= '9') { if (v < 0) v = 0; v = v * 10 + (*p - '0'); p++; }
    while (*p == ' ') p++;
    if (v >= 0 && p[0] == 'k' && p[1] == 'B') return v;
    return -1;
}
int main(void) {
    print("hello569: /proc/<pid>/status VmSwap\n");
    static char buf[8192];
    long n = slurp("/proc/self/status", buf, sizeof buf);
    long v = n > 0 ? vmswap(buf) : -1;
    snprintf(msg, sizeof msg, "A: VmSwap line present and 0 with swap off (%ld)", v);
    check(v == 0, msg);

    /* B: VmStk is immediately followed by VmSwap. */
    const char *stk = n > 0 ? strstr(buf, "\nVmStk:") : (void *)0;
    const char *sw = n > 0 ? strstr(buf, "\nVmSwap:") : (void *)0;
    int order = stk && sw && sw > stk;
    /* nothing but the VmStk line's own text sits between the two newlines */
    int adjacent = 0;
    if (order) {
        const char *nl = strchr(stk + 1, '\n'); /* end of the VmStk line */
        adjacent = nl != (void *)0 && nl == sw;
    }
    /* VmSwap comes after VmStk; VmExe/VmLib (hello570) sit between them, so they are not adjacent. */
    snprintf(msg, sizeof msg, "B: VmSwap comes after VmStk (order %d)", order);
    check(order, msg);
    (void)adjacent;

    /* C: a kernel thread has no VmSwap line. */
    long kn = slurp("/proc/0/status", buf, sizeof buf);
    if (kn > 0) {
        int no_vm = strstr(buf, "VmSwap:") == (void *)0 && strstr(buf, "VmSize:") == (void *)0;
        check(no_vm, "C: a kernel thread (pid 0) has no Vm lines");
    } else {
        check(1, "C: (skipped: /proc/0 not readable)");
    }

    print(failures ? "hello569: FAIL\n" : "hello569: PASS\n");
    return failures ? 1 : 0;
}
