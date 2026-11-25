/* hello578: /proc/<pid>/status has a VmPeak line (Linux: the high-water mark of VmSize, in kB, right-aligned in eight columns,
 * the first Vm line, before VmSize). The kernel printed none. VmPeak must be >= the current VmSize, and must not drop after a
 * mapping is freed (it is a peak). A: VmPeak exists and is >= VmSize; B: after mapping and touching memory then unmapping it,
 * VmSize falls back but VmPeak stays at least as high as the peak VmSize reached; C: a kernel thread (/proc/0/status) has no
 * VmPeak line. */
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
    print(ok ? "hello578:   ok   " : "hello578:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static long field(const char *path, const char *key) {
    static char buf[8192];
    int fd = (int)open(path, O_RDONLY, 0);
    long n = fd >= 0 ? (long)read(fd, buf, sizeof buf - 1) : -1;
    if (fd >= 0) close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    const char *p = strstr(buf, key);
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
    print("hello578: /proc/<pid>/status VmPeak\n");
    long peak0 = field("/proc/self/status", "VmPeak:");
    long size0 = field("/proc/self/status", "VmSize:");
    snprintf(msg, sizeof msg, "A: VmPeak %ld >= VmSize %ld, both positive", peak0, size0);
    check(peak0 > 0 && size0 > 0 && peak0 >= size0, msg);

    /* Map and touch 8 MiB, note the peak, then unmap and confirm VmPeak holds while VmSize drops. */
    void *p = mmap(0, 8 * 1024 * 1024, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == (void *)-1 || p == 0) { check(0, "B: mmap"); print("hello578: FAIL\n"); return 1; }
    for (long i = 0; i < 8 * 1024 * 1024; i += PG) ((volatile char *)p)[i] = 1;
    long peak_hi = field("/proc/self/status", "VmPeak:");
    long size_hi = field("/proc/self/status", "VmSize:");
    munmap(p, 8 * 1024 * 1024);
    long peak_after = field("/proc/self/status", "VmPeak:");
    long size_after = field("/proc/self/status", "VmSize:");
    snprintf(msg, sizeof msg, "B: peak rose to %ld (>=%ld); after unmap VmSize %ld < %ld but VmPeak %ld still >= %ld",
             peak_hi, size_hi, size_after, size_hi, peak_after, peak_hi);
    check(peak_hi >= size_hi && size_after < size_hi && peak_after >= peak_hi, msg);

    long kp = field("/proc/0/status", "VmPeak:");
    check(kp == -1, "C: a kernel thread (pid 0) has no VmPeak line");

    print(failures ? "hello578: FAIL\n" : "hello578: PASS\n");
    return failures ? 1 : 0;
}
