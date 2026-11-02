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
    scenario(s_lock, "scenario D: mlock family");
    scenario(s_lockall, "scenario E: mlockall / MAP_LOCKED");

    print(failures == 0 ? "hello200: PASS\n" : "hello200: FAIL\n");
    return failures;
}
