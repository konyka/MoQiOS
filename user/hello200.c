/* hello200: the moqi_libc mman wrappers (mmap, munmap, mprotect, madvise, msync, mincore, mremap, mlock family)
 * through the real kernel: glibc's convention (0 or the address; -1/MAP_FAILED and errno on failure), checked against
 * the errno values hello188/198/199 measured on Linux. Runs unprivileged for the RLIMIT_MEMLOCK parts. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/resource.h"
#include "../lib/moqi_libc/include/mman.h"

#define PG 4096UL
#define SYS_capset 307

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello200:   ok   " : "hello200:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void limit_pages(unsigned long pages) {
    struct rlimit rl = { pages * PG, pages * PG };
    setrlimit(RLIMIT_MEMLOCK, &rl);
}

static void scenario(void (*body)(void), const char *name) {
    int before = failures;
    long pid = fork();
    if (pid == 0) {
        body();
        _exit(failures != before ? 1 : 0);
    }
    int status = 0;
    int ok = pid > 0 && waitpid(pid, &status, 0) == pid && ((status >> 8) & 0xff) == 0;
    check(ok, name);
}

static void s_basic(void) {
    errno = 0;
    char *p = (char *)mmap((void *)0, 4 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(p != MAP_FAILED && errno == 0, "A: mmap returns an address and leaves errno alone");
    p[0] = 1; p[3 * PG] = 2;
    check(p[0] == 1 && p[3 * PG] == 2, "A: the mapping is usable");
    unsigned char vec[4] = { 9, 9, 9, 9 };
    check(mincore(p, 4 * PG, vec) == 0, "A: mincore succeeds");
    check(msync(p, PG, MS_ASYNC) == 0, "A: msync(MS_ASYNC) succeeds");
    check(mprotect(p, PG, PROT_READ) == 0, "A: mprotect succeeds");
    check(mprotect(p, PG, PROT_READ | PROT_WRITE) == 0, "A: and back to read-write");
    check(madvise(p + PG, PG, MADV_DONTNEED) == 0 && p[PG] == 0, "A: MADV_DONTNEED zero-fills the page");
    check(munmap(p, 4 * PG) == 0, "A: munmap succeeds");
}

static void s_errors(void) {
    errno = 0;
    check(mmap((void *)0, 0, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED && errno == EINVAL,
          "B: mmap of length 0 is MAP_FAILED / EINVAL");
    errno = 0;
    check(mmap((void *)0, PG, PROT_READ, MAP_PRIVATE | MAP_SHARED, -1, 0) == MAP_FAILED && errno == EINVAL,
          "B: mmap with both sharing flags is EINVAL");
    errno = 0;
    check(munmap((void *)1, PG) == -1 && errno == EINVAL, "B: munmap of an unaligned address is -1 / EINVAL");
    errno = 0;
    check(mprotect((void *)0x30000000, PG, PROT_READ) == -1 && errno == ENOMEM, "B: mprotect of an unmapped range is -1 / ENOMEM");
    errno = 0;
    check(madvise((void *)0x30000000, PG, MADV_DONTNEED) == -1 && errno == ENOMEM, "B: madvise of an unmapped range is -1 / ENOMEM");
    errno = 0;
    check(madvise((void *)0x30000000, PG, 1000) == -1 && errno == EINVAL, "B: madvise with an unknown advice is -1 / EINVAL");
    errno = 0;
    check(msync((void *)1, PG, MS_SYNC) == -1 && errno == EINVAL, "B: msync of an unaligned address is -1 / EINVAL");
    errno = 0;
    check(mlockall(0) == -1 && errno == EINVAL, "B: mlockall with no flags is -1 / EINVAL");
    /* errno is only written on failure. */
    errno = 1234;
    void *p = mmap((void *)0, PG, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(p != MAP_FAILED && errno == 1234, "B: a successful call does not touch errno");
    check(munmap(p, PG) == 0 && errno == 1234, "B: nor does a successful munmap");
}

static void s_mremap(void) {
    char *p = (char *)mmap((void *)0, 2 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    p[0] = 7;
    char *q = (char *)mremap(p, 2 * PG, 6 * PG, MREMAP_MAYMOVE);
    check(q != MAP_FAILED && q[0] == 7, "C: mremap grows the mapping and keeps its contents");
    q[5 * PG] = 9;
    check(q[5 * PG] == 9, "C: the grown tail is usable");
    errno = 0;
    check(mremap((void *)0x30000000, PG, 2 * PG, MREMAP_MAYMOVE) == MAP_FAILED && errno == EFAULT,
          "C: mremap of an unmapped page is MAP_FAILED / EFAULT");
    char *r = (char *)mremap(q, 6 * PG, 3 * PG, 0);
    check(r == q, "C: shrinking in place returns the same address");
    /* MREMAP_FIXED reads the fifth argument. */
    char *dst = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    munmap(dst, 8 * PG);
    char *m = (char *)mremap(r, 3 * PG, 3 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, dst);
    check(m == dst && m[0] == 7, "C: MREMAP_FIXED moves the mapping to the address passed as the fifth argument");
    unsigned char v;
    check(mincore(r, PG, &v) == -1 && errno == ENOMEM, "C: and the old range is unmapped");
    /* A shrinking move also relocates (Linux: contents kept at the new address, the whole old range gone). */
    char *dst2 = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    munmap(dst2, 8 * PG);
    m[2 * PG] = 5;
    char *s2 = (char *)mremap(m, 3 * PG, 2 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, dst2);
    check(s2 == dst2 && s2[0] == 7, "C: a shrinking MREMAP_FIXED moves the mapping and keeps its contents");
    check(mincore(m, PG, &v) == -1 && errno == ENOMEM && mincore(m + 2 * PG, PG, &v) == -1, "C: the whole old range, tail page included, is unmapped");
    errno = 0;
    check(mremap(dst2, 2 * PG, 2 * PG, MREMAP_FIXED, dst2 + 16 * PG) == MAP_FAILED && errno == EINVAL, "C: MREMAP_FIXED without MREMAP_MAYMOVE is EINVAL");
    errno = 0;
    check(mremap(dst2, 2 * PG, 2 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, dst2) == MAP_FAILED && errno == EINVAL, "C: moving a mapping onto itself is EINVAL");
}

static int mapped(const void *p) {
    unsigned char v;
    return mincore((void *)p, PG, &v) == 0;
}

/* A private anonymous mapping with an unmapped page on each side. Neighbouring anonymous mappings with the same
 * protection merge into one tracked region, and the kernel only moves whole regions (a move of part of one is
 * EINVAL), so the probe keeps its mappings apart. */
static char *gmap(unsigned long pages) {
    char *m = (char *)mmap((void *)0, (pages + 2) * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    munmap(m, PG);
    munmap(m + (pages + 1) * PG, PG);
    return m + PG;
}

/* MREMAP_FIXED onto existing mappings replaces them (Linux, measured): only the moved size is replaced, the rest of a
 * bigger destination survives, the source is gone, locks follow the mapping. */
static void s_mremap_replace(void) {
    char *src = gmap(3);
    char *dst = gmap(5);
    src[0] = 7; src[2 * PG] = 9; dst[0] = 1; dst[4 * PG] = 2;
    char *r = (char *)mremap(src, 3 * PG, 3 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, dst);
    check(r == dst && dst[0] == 7 && dst[2 * PG] == 9, "F: MREMAP_FIXED onto a bigger existing mapping replaces its first 3 pages");
    check(mapped(dst + 3 * PG) && dst[4 * PG] == 2, "F: the destination's remaining 2 pages survive untouched");
    check(!mapped(src), "F: the source range is gone");

    char *big = gmap(8);
    char *small = gmap(2);
    big[3 * PG] = 99; big[5 * PG] = 4; small[0] = 5;
    r = (char *)mremap(small, 2 * PG, 2 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, big + 3 * PG);
    check(r == big + 3 * PG && r[0] == 5 && mapped(big) && mapped(big + 7 * PG), "F: moving into the middle of an 8 page mapping splits it");
    check(big[5 * PG] == 4 && mapped(big + 2 * PG) && mapped(big + 5 * PG), "F: both halves keep their pages");

    char *whole = gmap(3);
    char *holey = gmap(3);
    munmap(holey + PG, PG);
    check((char *)mremap(whole, 3 * PG, 3 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, holey) == holey, "F: a destination with a hole in it is fine");

    char *u = gmap(3);
    errno = 0;
    check(mremap(u, 3 * PG, 3 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, (void *)0x7ffffffff000UL) == MAP_FAILED && errno == EINVAL,
          "F: a destination that runs past the end of user space is EINVAL");
    errno = 0;
    check(mremap(u, 3 * PG, 3 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, (void *)0xffff800000000000UL) == MAP_FAILED && errno == EINVAL,
          "F: a kernel address is EINVAL");
    check(mapped(u), "F: and a refused move leaves the source mapped");
}

/* Locks follow a MREMAP_FIXED move; the replaced destination's locks are released. */
static void s_mremap_locks(void) {
    limit_pages(8);
    char *dst = gmap(4);
    char *src = gmap(4);
    check(mlock(dst, 4 * PG) == 0 && mlock(src, 4 * PG) == 0, "G: both mappings locked, 8 of 8 pages");
    check(mremap(src, 4 * PG, 4 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, dst) == dst, "G: move the locked source onto the locked destination");
    errno = 0;
    check(madvise(dst, PG, MADV_DONTNEED) == -1 && errno == EINVAL, "G: the moved pages are locked");
    char *e = (char *)mmap((void *)0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(mlock(e, PG) == 0, "G: the replaced destination's quota was released (4 locked, so one more fits)");
    char *lo = gmap(4);
    char *a = gmap(2);
    check(mlock(a, 2 * PG) == 0, "G: lock a 2 page source (4 + 1 + 2 = 7)");
    char *moved = (char *)mremap(a, 2 * PG, 2 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, lo + PG);
    check(moved == lo + PG && madvise(moved, PG, MADV_DONTNEED) == -1, "G: a locked source moved onto an unlocked destination stays locked");
    check(madvise(lo, PG, MADV_DONTNEED) == 0, "G: the unlocked neighbour is still unlocked");
}

/* mremap on a sub-range of a mapping (Linux, measured): the range is split off and moved or resized on its own; the
 * rest of the mapping stays where it is. */
static void s_mremap_sub(void) {
    char *a = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    for (int i = 0; i < 8; i++) a[i * PG] = (char)(i + 1);
    char *d = gmap(16);
    char *r = (char *)mremap(a + 2 * PG, 3 * PG, 3 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, d);
    check(r == d && d[0] == 3 && d[PG] == 4 && d[2 * PG] == 5, "H: MREMAP_FIXED of 3 pages out of the middle of 8 moves them with their contents");
    check(mapped(a) && mapped(a + PG) && a[0] == 1 && a[PG] == 2, "H: the head of the mapping stays");
    check(!mapped(a + 2 * PG) && !mapped(a + 3 * PG) && !mapped(a + 4 * PG), "H: the moved pages are gone from the old place");
    check(mapped(a + 5 * PG) && a[5 * PG] == 6 && a[6 * PG] == 7 && a[7 * PG] == 8, "H: and the tail stays too");

    char *b = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    for (int i = 0; i < 8; i++) b[i * PG] = (char)(i + 11);
    char *g = (char *)mremap(b + 2 * PG, 3 * PG, 6 * PG, MREMAP_MAYMOVE);
    check(g != MAP_FAILED && g != b + 2 * PG && g[0] == 13 && g[PG] == 14 && g[2 * PG] == 15, "H: growing a range in the middle moves it (the tail is in the way)");
    check(mapped(b) && mapped(b + PG) && !mapped(b + 2 * PG) && !mapped(b + 3 * PG) && !mapped(b + 4 * PG) && mapped(b + 5 * PG),
          "H: leaving a hole between the head and the tail");
    g[5 * PG] = 99;
    check(g[5 * PG] == 99, "H: and the grown part is usable");

    char *c = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    errno = 0;
    check(mremap(c + 2 * PG, 3 * PG, 6 * PG, 0) == MAP_FAILED && errno == ENOMEM, "H: growing in place without MREMAP_MAYMOVE is ENOMEM when the tail blocks it");
    check(mapped(c) && mapped(c + 7 * PG), "H: and a refused mremap leaves the mapping whole");

    char *e = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    for (int i = 0; i < 8; i++) e[i * PG] = (char)(i + 21);
    char *sh = (char *)mremap(e + 2 * PG, 3 * PG, 1 * PG, 0);
    check(sh == e + 2 * PG && e[2 * PG] == 23, "H: shrinking a range in the middle keeps its address");
    check(!mapped(e + 3 * PG) && !mapped(e + 4 * PG) && mapped(e) && mapped(e + 5 * PG) && e[5 * PG] == 26, "H: pages 3 and 4 go, the head and the tail stay");

    char *f = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(mremap(f + 2 * PG, 3 * PG, 3 * PG, 0) == f + 2 * PG, "H: a same-size mremap of a middle range returns the same address");
    check(mapped(f + 2 * PG) && mapped(f + 7 * PG), "H: and changes nothing");

    char *h = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    h[3 * PG] = 33;
    char *dst = gmap(8);
    char *m = (char *)mremap(h + 3 * PG, PG, 4 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, dst);
    check(m == dst && m[0] == 33 && !mapped(h + 3 * PG) && mapped(h) && mapped(h + 7 * PG), "H: a FIXED move of one page out of the middle that also grows it to 4");

    char *j = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    char *dst2 = gmap(8);
    munmap(dst2, 8 * PG); /* an empty destination, so "only 1 page exists there" means the move made one page */
    char *mv = (char *)mremap(j + 2 * PG, 3 * PG, 1 * PG, MREMAP_MAYMOVE | MREMAP_FIXED, dst2);
    check(mv == dst2, "H: a FIXED move of 3 pages out of the middle that shrinks them to 1 returns the new address");
    check(!mapped(j + 2 * PG) && !mapped(j + 3 * PG) && !mapped(j + 4 * PG), "H: and all three old pages are gone from the old place");
    check(mapped(dst2) && !mapped(dst2 + PG), "H: only 1 page exists at the new place");
    check(mapped(j) && mapped(j + PG) && mapped(j + 5 * PG) && mapped(j + 7 * PG), "H: and the head and the tail are intact");

    /* A range that ends past the mapping is not a sub-range: Linux allows it, this kernel refuses it (documented). */
    char *k = (char *)mmap((void *)0, 4 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    errno = 0;
    char *kr = (char *)mremap(k + 2 * PG, 4 * PG, 4 * PG, MREMAP_MAYMOVE);
    check(kr == MAP_FAILED, "H: a range that runs past the end of its mapping is refused (this kernel; Linux accepts it)");
}

static void s_lock(void) {
    limit_pages(8);
    char *p = (char *)mmap((void *)0, 12 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(mlock(p, 4 * PG) == 0, "D: mlock succeeds within the limit");
    errno = 0;
    check(madvise(p, PG, MADV_DONTNEED) == -1 && errno == EINVAL, "D: a locked page refuses MADV_DONTNEED (-1 / EINVAL)");
    errno = 0;
    check(mlock(p + 4 * PG, 8 * PG) == -1 && errno == ENOMEM, "D: mlock over the limit is -1 / ENOMEM");
    check(mlock2(p + 4 * PG, 4 * PG, MLOCK_ONFAULT) == 0, "D: mlock2(MLOCK_ONFAULT) fits the rest of the limit");
    check(munlock(p, 8 * PG) == 0, "D: munlock succeeds");
    check(madvise(p, PG, MADV_DONTNEED) == 0, "D: and the page accepts MADV_DONTNEED again");
    errno = 0;
    check(mlock2(p, PG, 2) == -1 && errno == EINVAL, "D: mlock2 with an unknown flag is -1 / EINVAL");
}

static void s_lockall(void) {
    limit_pages(16);
    check(mlockall(MCL_FUTURE) == 0, "E: mlockall(MCL_FUTURE) succeeds");
    char *a = (char *)mmap((void *)0, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(a != MAP_FAILED && madvise(a, PG, MADV_DONTNEED) == -1 && errno == EINVAL, "E: a new mapping is locked");
    errno = 0;
    check(mmap((void *)0, 9 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED && errno == EAGAIN,
          "E: over the limit mmap is MAP_FAILED / EAGAIN");
    errno = 0;
    check(mremap(a, 8 * PG, 20 * PG, MREMAP_MAYMOVE) == MAP_FAILED && errno == EAGAIN, "E: mremap growth over the limit is EAGAIN");
    check(munlockall() == 0, "E: munlockall succeeds");
    char *b = (char *)mmap((void *)0, 64 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(b != MAP_FAILED, "E: afterwards mappings are not limited");
    errno = 0;
    check(mmap((void *)0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_LOCKED, -1, 0) != MAP_FAILED,
          "E: a MAP_LOCKED page fits again");
    limit_pages(0);
    errno = 0;
    check(mmap((void *)0, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_LOCKED, -1, 0) == MAP_FAILED && errno == EPERM,
          "E: with a zero limit MAP_LOCKED is MAP_FAILED / EPERM");
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello200: libc mman wrappers\n");

    unsigned int hdr[2] = { 0x20080522u, 0 };
    unsigned int data[6] = { 0 };
    check(syscall2(SYS_capset, (long)hdr, (long)data) == 0, "capabilities dropped");

    scenario(s_basic, "scenario A: the usual calls");
    scenario(s_errors, "scenario B: errors and errno");
    scenario(s_mremap, "scenario C: mremap");
    scenario(s_mremap_replace, "scenario F: MREMAP_FIXED replaces existing mappings");
    scenario(s_mremap_locks, "scenario G: locks follow a MREMAP_FIXED move");
    scenario(s_mremap_sub, "scenario H: mremap on a sub-range");
    scenario(s_lock, "scenario D: mlock family");
    scenario(s_lockall, "scenario E: mlockall / MAP_LOCKED");

    print(failures == 0 ? "hello200: PASS\n" : "hello200: FAIL\n");
    return failures;
}
