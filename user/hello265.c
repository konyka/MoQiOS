/* hello265: mprotect keeps the RLIMIT_DATA ledger (VmData). Measured on Linux (gcc probes): VmData follows mprotect: a private mapping that becomes
 * writable adds its pages, one that stops being writable gives them back, PROT_NONE is not data, execute-only changes nothing, a shared mapping never
 * counts; a partly writable region adds only the other part; munmap of a piece afterwards refunds what the piece is NOW (not what it was at mmap);
 * and under RLIMIT_DATA an mprotect that would push the ledger over the limit fails with ENOMEM and changes nothing, while giving writability up
 * elsewhere first makes room. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/mman.h"
#include "../lib/moqi_libc/include/resource.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello265:   ok   " : "hello265:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static long vmdata(void) {
    static char text[4096];
    int fd = (int)open("/proc/self/status", O_RDONLY, 0);
    if (fd < 0) return -1;
    long n = read(fd, text, sizeof text - 1);
    close(fd);
    if (n <= 0) return -1;
    text[n] = 0;
    char *p = strstr(text, "\nVmData:\t");
    return p ? atol(p + 9) : -1;
}

#define MB (1024 * 1024)
#define RW (PROT_READ | PROT_WRITE)

static void *anon(long len, int prot, int flags) { return mmap(0, len, prot, MAP_PRIVATE | MAP_ANONYMOUS | flags, -1, 0); }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello265: mprotect and the RLIMIT_DATA ledger\n");
    char what[260];

    long d0 = vmdata();
    char *a = (char *)anon(MB, RW, 0);
    long d1 = vmdata();
    mprotect(a, MB, PROT_READ);
    long d2 = vmdata();
    mprotect(a, MB, RW);
    long d3 = vmdata();
    snprintf(what, sizeof what, "A: writable -> read-only gives the pages back, and back to writable takes them again (%ld, %ld, %ld)", d1 - d0, d2 - d1, d3 - d2);
    check(d1 - d0 == 1024 && d2 - d1 == -1024 && d3 - d2 == 1024, what);

    mprotect(a + MB / 4, MB / 4, PROT_READ);
    long d4 = vmdata();
    snprintf(what, sizeof what, "B: making the middle quarter read-only gives back a quarter (%ld)", d4 - d3);
    check(d4 - d3 == -256, what);
    mprotect(a, MB, PROT_NONE);
    long d5 = vmdata();
    snprintf(what, sizeof what, "B: PROT_NONE is not data: the writable three quarters are given back (%ld)", d5 - d4);
    check(d5 - d4 == -768, what);
    mprotect(a, MB, RW);
    long d6 = vmdata();
    snprintf(what, sizeof what, "B: all writable again takes the whole megabyte (%ld)", d6 - d5);
    check(d6 - d5 == 1024, what);

    munmap(a + MB / 4, MB / 4);
    long d7 = vmdata();
    munmap(a, MB / 4);
    munmap(a + MB / 2, MB / 2);
    long d8 = vmdata();
    snprintf(what, sizeof what, "C: munmap refunds what each piece is now (a quarter, then the rest: %ld, %ld; net %ld)", d7 - d6, d8 - d7, d8 - d0);
    check(d7 - d6 == -256 && d8 - d7 == -768 && d8 - d0 == 0, what);

    char *b = (char *)anon(MB, PROT_READ, 0);
    long e0 = vmdata();
    mprotect(b, MB, PROT_READ | PROT_EXEC);
    long e1 = vmdata();
    mprotect(b, MB, RW | PROT_EXEC);
    long e2 = vmdata();
    snprintf(what, sizeof what, "D: read-only -> read+exec changes nothing, adding write adds the megabyte (%ld, %ld)", e1 - e0, e2 - e1);
    check(e1 - e0 == 0 && e2 - e1 == 1024, what);
    munmap(b, MB);

    char *c = (char *)anon(MB, PROT_READ, 0);
    mprotect(c, MB / 2, RW);
    long f0 = vmdata();
    mprotect(c, MB, RW);
    long f1 = vmdata();
    snprintf(what, sizeof what, "E: a region that is half writable gains only the other half (%ld)", f1 - f0);
    check(f1 - f0 == 512, what);
    munmap(c, MB);

    char *s = (char *)mmap(0, MB, PROT_READ, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    long g0 = vmdata();
    mprotect(s, MB, RW);
    long g1 = vmdata();
    snprintf(what, sizeof what, "F: a shared mapping never counts, whatever its protection (%ld)", g1 - g0);
    check(s != (char *)-1 && g1 - g0 == 0, what);
    munmap(s, MB);

    /* Pieces join again: the region table holds 64 records, and a round trip of mprotect on the first page of a mapping splits it and (as on Linux)
     * has to merge it back. 100 round trips on 100 different mappings would run the table out if the pieces stayed apart. */
    int merged_ok = 1;
    for (int k = 0; k < 100; k++) {
        char *w = (char *)anon(2 * 4096, RW, 0);
        if (w == (char *)-1) { merged_ok = 0; break; }
        if (mprotect(w, 4096, PROT_READ) != 0 || mprotect(w, 4096, RW) != 0) { merged_ok = 0; munmap(w, 2 * 4096); break; }
        munmap(w, 2 * 4096);
    }
    check(merged_ok, "I: a hundred first-page mprotect round trips never run the region table out");
    char *keep[40];
    int kept = 0, keep_ok = 1;
    for (int k = 0; k < 40; k++) {
        keep[k] = (char *)anon(2 * 4096, RW, 0);
        if (keep[k] == (char *)-1) { keep_ok = 0; break; }
        kept++;
        if (mprotect(keep[k], 4096, PROT_READ) != 0 || mprotect(keep[k], 4096, RW) != 0) { keep_ok = 0; break; }
    }
    snprintf(what, sizeof what, "I: forty live mappings each toggled on its first page still fit the table (%d kept)", kept);
    check(keep_ok && kept == 40, what);
    for (int k = 0; k < kept; k++) munmap(keep[k], 2 * 4096);

    /* mremap across a protection boundary: after mprotect the mapping is several records, and a shrink (or a move) over a range that spans them has
     * to work as it does on Linux, which treats it as one range of mappings. */
    char *m = (char *)anon(4 * 4096, RW, 0);
    mprotect(m, 4096, PROT_NONE);
    void *shr = mremap(m, 2 * 4096, 4096, MREMAP_MAYMOVE);
    snprintf(what, sizeof what, "J: mremap shrinking 2 pages to 1 across a protection boundary works (%p)", shr);
    check(shr == (void *)m, what);
    long j0 = vmdata();
    munmap(m, 4 * 4096);
    long j1 = vmdata();
    snprintf(what, sizeof what, "J: and the ledger afterwards is what is left (page 0 is PROT_NONE, page 1 was cut, pages 2 and 3 are data: %ld)", j1 - j0);
    check(j1 - j0 == -8, what);

    /* MAP_FIXED over an exact private region has its own fast path (hello65), which only swaps read-write regions in place. A region mprotect made
     * read-only used to be taken for read-write by it (the region never recorded the change); it must take the general path and still succeed. */
    char *h = (char *)anon(MB, RW, 0);
    mprotect(h, MB, PROT_READ);
    long i0 = vmdata();
    void *fx = mmap(h, MB, RW, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    long i1 = vmdata();
    snprintf(what, sizeof what, "H: MAP_FIXED read-write over a region mprotect made read-only works and counts the megabyte (%p, delta %ld)", fx, i1 - i0);
    check(fx == (void *)h && i1 - i0 == 1024, what);
    /* A read-only MAP_FIXED over a writable region is refused by the fast path on purpose (hello65: "read-only fixed replacement rejected"); Linux
     * allows it. That limit predates this test and is not asserted here. */
    munmap(h, MB);

    /* RLIMIT_DATA: three megabytes of room above what is in use now. */
    long base_bytes = vmdata() * 1024;
    struct rlimit lim = { (unsigned long)(base_bytes + 3 * MB), (unsigned long)(base_bytes + 3 * MB) };
    setrlimit(RLIMIT_DATA, &lim);
    char *x = (char *)anon(2 * MB, RW, 0);
    char *y = (char *)anon(2 * MB, PROT_READ, 0);
    long h0 = vmdata();
    errno = 0;
    long rc = mprotect(y, 2 * MB, RW);
    int err = errno;
    long h1 = vmdata();
    snprintf(what, sizeof what, "G: read-only -> writable over RLIMIT_DATA is ENOMEM and the ledger is unchanged (rc %ld, errno %d, delta %ld)", rc, err, h1 - h0);
    check(x != (char *)-1 && y != (char *)-1 && rc == -1 && err == ENOMEM && h1 == h0, what);
    mprotect(x, 2 * MB, PROT_READ);
    long h2 = vmdata();
    rc = mprotect(y, 2 * MB, RW);
    long h3 = vmdata();
    snprintf(what, sizeof what, "G: after giving the other mapping's writability up there is room (rc %ld, deltas %ld then %ld)", rc, h2 - h1, h3 - h2);
    check(rc == 0 && h2 - h1 == -2048 && h3 - h2 == 2048, what);

    print(failures == 0 ? "hello265: PASS\n" : "hello265: FAIL\n");
    return failures;
}
