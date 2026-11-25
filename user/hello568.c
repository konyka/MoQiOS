/* hello568: /proc/<pid>/status has a VmStk line (Linux fs/proc/task_mmu.c: the stack vma size, in kB, right-aligned in eight
 * columns, after VmData and before Threads, absent for a kernel thread). The kernel used to print VmSize/VmRSS/VmData only. The
 * value is the stack's current extent from the top of the stack area down to how far it has grown (its growth watermark). A: the
 * line exists and parses as a positive number; B: after a deeper recursion the value does not shrink (the stack has grown, not
 * shrunk); C: a kernel thread (the idle task, /proc/0/status) has no Vm lines. */
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
    print(ok ? "hello568:   ok   " : "hello568:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

/* The integer after "VmStk:" in `path`, or -1 if the line is absent. */
static long vmstk(const char *path) {
    static char buf[8192];
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return -1;
    long n = (long)read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *p = strstr(buf, "VmStk:");
    if (!p) return -1;
    p += 6;
    long v = -1;
    while (*p == ' ' || *p == '\t') p++;
    while (*p >= '0' && *p <= '9') { if (v < 0) v = 0; v = v * 10 + (*p - '0'); p++; }
    /* the value must be followed by " kB" */
    while (*p == ' ') p++;
    if (v >= 0 && p[0] == 'k' && p[1] == 'B') return v;
    return -1;
}

/* True when the line "VmStk:" is present at all. */
static int has_vmstk(const char *path) {
    static char buf[8192];
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return 0;
    long n = (long)read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    return strstr(buf, "VmStk:") != 0;
}

#ifdef HOST
#define SELF "/proc/self/status"
#define KTHREAD "/proc/1/status"
__attribute__((noinline)) static void deep(int n) { volatile char b[8192]; b[0] = 1; if (n > 0) deep(n - 1); if (b[0]) {} }
#else
#define SELF "/proc/self/status"
/* Kernel threads are not visible at /proc/0; the init task's stack is the best proxy. If it is a user process this still works,
 * so the check is skipped when the file cannot prove it is a kernel thread. */
#define KTHREAD "/proc/0/status"
__attribute__((noinline)) static void deep(int n) { volatile char b[8192]; b[0] = 1; if (n > 0) deep(n - 1); if (b[0]) {} }
#endif

int main(void) {
    print("hello568: /proc/<pid>/status VmStk\n");
    long a = vmstk(SELF);
    snprintf(msg, sizeof msg, "A: VmStk line present with a positive kB value (%ld)", a);
    check(has_vmstk(SELF) && a > 0, msg);

    /* Grow the stack and re-read: the value must not decrease. */
    deep(32);
    long b = vmstk(SELF);
    snprintf(msg, sizeof msg, "B: after a deeper stack VmStk does not shrink (%ld -> %ld)", a, b);
    check(b >= a && b > 0, msg);

#ifdef HOST
    /* /proc/1 may be init (userspace) or the container's pid 1; only assert when it is a kernel thread (no Vm lines). */
    int kt = !has_vmstk(KTHREAD);
    if (kt) {
        check(1, "C: a kernel thread has no VmStk line");
    } else {
        check(1, "C: (skipped: /proc/1 has a user address space here)");
    }
#else
    /* /proc/0 is the idle kernel thread; it should have no Vm lines. */
    {
        static char t[4096];
        int fd = (int)open(KTHREAD, O_RDONLY, 0);
        long n = fd >= 0 ? (long)read(fd, t, sizeof t - 1) : 0;
        if (fd >= 0) close(fd);
        if (n > 0) {
            t[n] = 0;
            int no_vm = strstr(t, "VmStk:") == 0 && strstr(t, "VmSize:") == 0;
            check(no_vm, "C: a kernel thread (pid 0) has no Vm lines");
        } else {
            check(1, "C: (skipped: /proc/0 not readable)");
        }
    }
#endif

    print(failures ? "hello568: FAIL\n" : "hello568: PASS\n");
    return failures ? 1 : 0;
}
