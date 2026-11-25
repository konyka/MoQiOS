/* hello571: /proc/<pid>/status has a VmPTE line (Linux fs/proc/task_mmu.c: the page-table pages of the process, in kB,
 * right-aligned in eight columns, after VmLib and before VmSwap). The kernel printed none. VmPTE grows when more address space is
 * populated (each 2 MiB region that gets a mapped page needs its own leaf page table). A: VmPTE exists and is a positive kB value;
 * B: after mapping and touching several megabytes spread across the address space, VmPTE does not shrink (more leaf tables exist);
 * C: VmPTE comes after VmLib and before VmSwap (Linux order); D: a kernel thread (/proc/0/status) has no VmPTE line. */
#ifdef HOST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/mman.h"
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello571:   ok   " : "hello571:   FAIL ");
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
#define PG 4096
int main(void) {
    print("hello571: /proc/<pid>/status VmPTE\n");
    static char buf[8192];
    long n = slurp("/proc/self/status", buf, sizeof buf);
    long a = n > 0 ? field(buf, "VmPTE:") : -1;
    snprintf(msg, sizeof msg, "A: VmPTE present and positive (%ld)", a);
    check(a > 0, msg);

    /* Map several 2 MiB-spanning regions and touch one page in each, forcing new leaf page tables. */
    for (int i = 0; i < 8; i++) {
        void *p = mmap(0, 4 * 1024 * 1024, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p != (void *)-1 && p != 0) {
            ((volatile char *)p)[0] = 1;
            ((volatile char *)p)[2 * 1024 * 1024] = 1;
        }
    }
    n = slurp("/proc/self/status", buf, sizeof buf);
    long b = n > 0 ? field(buf, "VmPTE:") : -1;
    snprintf(msg, sizeof msg, "B: after mapping more address space VmPTE does not shrink (%ld -> %ld)", a, b);
    check(b >= a && b > 0, msg);

    const char *lib = n > 0 ? strstr(buf, "\nVmLib:") : (void *)0;
    const char *pte = n > 0 ? strstr(buf, "\nVmPTE:") : (void *)0;
    const char *sw = n > 0 ? strstr(buf, "\nVmSwap:") : (void *)0;
    int order = lib && pte && sw && pte > lib && sw > pte;
    snprintf(msg, sizeof msg, "C: order VmLib < VmPTE < VmSwap (%d)", order);
    check(order, msg);

    long kn = slurp("/proc/0/status", buf, sizeof buf);
    if (kn > 0) {
        int no_vm = strstr(buf, "VmPTE:") == (void *)0 && strstr(buf, "VmSize:") == (void *)0;
        check(no_vm, "D: a kernel thread (pid 0) has no Vm lines");
    } else {
        check(1, "D: (skipped: /proc/0 not readable)");
    }

    print(failures ? "hello571: FAIL\n" : "hello571: PASS\n");
    return failures ? 1 : 0;
}
