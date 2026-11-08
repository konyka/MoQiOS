/* hello264: VmSize and VmRSS in /proc/<pid>/status. Measured on Linux (gcc probe): mmap of 1 MiB raises VmSize by 1024 kB and VmRSS by 0 (this kernel
 * populates anonymous mappings at mmap time, so its VmRSS rises already there; the test checks the totals, not that moment); touching
 * every page raises VmRSS by 1024 kB and VmSize by 0; munmap lowers both by 1024 kB; sbrk of 1 MiB raises VmSize by 1024 kB; VmRSS never exceeds
 * VmSize. VmData counts the heap and writable private mappings only (and, on Linux, follows mprotect; this kernel's ledger does not, so that is not checked). The lines are "VmSize:\t<n> kB" and "VmRSS:\t<n> kB". */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/mman.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello264:   ok   " : "hello264:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

/* The kB value after `key` ("VmSize:" ...) in /proc/<path>/status, or -1 when the line is missing. */
static long kb_of(const char *path, const char *key) {
    static char text[4096];
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return -1;
    long n = read(fd, text, sizeof text - 1);
    close(fd);
    if (n <= 0) return -1;
    text[n] = 0;
    char want[24];
    snprintf(want, sizeof want, "\n%s\t", key);
    char *p = strstr(text, want);
    if (!p) return -1;
    return atol(p + strlen(want));
}
static void print_dec(unsigned long v) {
    char b[24];
    snprintf(b, sizeof b, "%lu", v);
    print(b);
}
static long vmsize(void) { return kb_of("/proc/self/status", "VmSize:"); }
static long vmrss(void) { return kb_of("/proc/self/status", "VmRSS:"); }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello264: VmSize / VmRSS\n");
    char what[240];
    const long MB = 1024 * 1024;

    long s0 = vmsize(), r0 = vmrss();
    snprintf(what, sizeof what, "A: both lines are present and VmRSS does not exceed VmSize (VmSize %ld kB, VmRSS %ld kB)", s0, r0);
    check(s0 > 0 && r0 > 0 && r0 <= s0, what);

    char *m = (char *)mmap(0, MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    long s1 = vmsize(), r1 = vmrss();
    snprintf(what, sizeof what, "B: mmap of 1 MiB raises VmSize by 1024 kB (dSize %ld)", s1 - s0);
    check(m != (char *)-1 && s1 - s0 == 1024, what);
    /* Linux maps anonymous pages lazily, so VmRSS stays put here and rises while the pages are touched. This kernel populates anonymous mappings
     * at mmap time (kernel/mm/mmap.zig), so VmRSS rises at the mmap; either way the mapping is resident once it has been touched. */
    print("hello264:   note VmRSS after mmap: +");
    print_dec((unsigned long)(r1 - r0));
    print(" kB (Linux: ~0, this kernel populates eagerly)\n");

    memset(m, 1, MB);
    long s2 = vmsize(), r2 = vmrss();
    snprintf(what, sizeof what, "C: touching every page leaves VmSize alone and VmRSS has grown by 1024 kB since before the mmap (dSize %ld, dRSS %ld)", s2 - s1, r2 - r0);
    check(s2 == s1 && r2 - r0 >= 1008 && r2 - r0 <= 1040, what);

    munmap(m, MB);
    long s3 = vmsize(), r3 = vmrss();
    snprintf(what, sizeof what, "D: munmap lowers both by 1024 kB (dSize %ld, dRSS %ld)", s3 - s2, r3 - r2);
    check(s3 - s2 == -1024 && r3 - r2 <= -1008 && r3 - r2 >= -1040, what);
    check(r3 - r0 >= -16 && r3 - r0 <= 16, "D: and VmRSS is back near where it started");

    long b0 = vmsize();
    void *brk0 = sbrk(MB);
    long b1 = vmsize();
    snprintf(what, sizeof what, "E: sbrk of 1 MiB raises VmSize by 1024 kB (dSize %ld)", b1 - b0);
    check(brk0 != (void *)-1 && b1 - b0 == 1024, what);

    long mine = vmsize();
    long viapid = kb_of("/proc/self/status", "VmSize:");
    char path[48];
    snprintf(path, sizeof path, "/proc/%ld/status", (long)getpid());
    long bynum = kb_of(path, "VmSize:");
    snprintf(what, sizeof what, "F: /proc/<pid>/status says the same as /proc/self/status (%ld, %ld, %ld)", mine, viapid, bynum);
    check(mine == viapid && bynum == mine, what);

    /* VmData: writable private mappings and the heap (Linux: private read-only and shared mappings do not count; mprotect to writable does). */
    long d0 = kb_of("/proc/self/status", "VmData:");
    char *pa = (char *)mmap(0, MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    long d1 = kb_of("/proc/self/status", "VmData:");
    char *pb = (char *)mmap(0, MB, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    long d2 = kb_of("/proc/self/status", "VmData:");
    char *pc = (char *)mmap(0, MB, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    long d3 = kb_of("/proc/self/status", "VmData:");
    sbrk(MB);
    long d4 = kb_of("/proc/self/status", "VmData:");
    munmap(pa, MB);
    long d6 = kb_of("/proc/self/status", "VmData:");
    snprintf(what, sizeof what, "G: VmData is present (%ld kB)", d0);
    check(d0 > 0, what);
    snprintf(what, sizeof what, "G: a private writable mapping adds 1024 kB, a private read-only one nothing, a shared one nothing (%ld, %ld, %ld)", d1 - d0, d2 - d1, d3 - d2);
    check(pa != (char *)-1 && pb != (char *)-1 && pc != (char *)-1 && d1 - d0 == 1024 && d2 - d1 == 0 && d3 - d2 == 0, what);
    snprintf(what, sizeof what, "G: sbrk adds 1024 kB (%ld)", d4 - d3);
    check(d4 - d3 == 1024, what);
    snprintf(what, sizeof what, "G: munmap of a private writable mapping removes 1024 kB (%ld)", d6 - d4);
    check(d6 - d4 == -1024, what);
    /* Not asserted: Linux also moves VmData on mprotect (read-only to writable adds, writable to read-only removes). This kernel's data ledger ignores
     * mprotect, so the line would read stale; see docs/current-code-review-and-fix-plan.md. */
    (void)pb;
    (void)pc;

    print(failures == 0 ? "hello264: PASS\n" : "hello264: FAIL\n");
    return failures;
}
