/// hello118: memfd_create(2).
///
///   A. memfd_create returns a read/write fd; data written reads back after
///      lseek; ftruncate grows it with zeros; fstat reports the size.
///   B. The file has no name: two memfds with the same name are separate
///      files, and nothing appears under /tmp.
///   C. A forked child shares the open file (writes are visible across the
///      fork); MFD_CLOEXEC marks the fd close-on-exec.
///   E. File seals: with MFD_ALLOW_SEALING, F_ADD_SEALS(GROW|SHRINK|WRITE)
///      makes growth, shrinking and writes fail while reads still work;
///      F_SEAL_SEAL stops further seals; a memfd without MFD_ALLOW_SEALING
///      and an ordinary /tmp file accept no seals.
///   D. Bad flags (MFD_HUGETLB, unknown bits) and an over-long name are EINVAL.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_OPEN      9
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_FORK      57
#define SYS_FSTAT     110
#define SYS_LSEEK     197
#define SYS_FTRUNCATE 211
#define SYS_FCNTL     142
#define SYS_MEMFD     285
#define F_GETFD       1
#define FD_CLOEXEC    1
#define MFD_CLOEXEC   1
#define MFD_HUGETLB   4
#define MFD_ALLOW_SEALING 2
#define F_ADD_SEALS   1033
#define F_GET_SEALS   1034
#define F_SEAL_SEAL   1
#define F_SEAL_SHRINK 2
#define F_SEAL_GROW   4
#define F_SEAL_WRITE  8
#define EPERM_        1
#define EBUSY_        16
#define SYS_MMAP      8
#define SYS_MUNMAP    12
#define EINVAL_       22

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello118:   ok   " : "hello118:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

void _start(void) {
    print("hello118: memfd_create\n");
    char buf[16];

    /* A */
    int64_t fd = syscall2(SYS_MEMFD, (uint64_t)"scratch", 0);
    check(fd >= 0, "A: memfd_create(\"scratch\", 0)");
    if (fd >= 0) {
        check(syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"memfd-data", 10) == 10, "A: write 10 bytes");
        check(syscall3(SYS_LSEEK, (uint64_t)fd, 0, 0) == 0, "A: lseek to 0");
        for (int i = 0; i < 16; i++) buf[i] = 0;
        check(syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, sizeof(buf)) == 10 && buf[0] == 'm' && buf[9] == 'a', "A: the data reads back");
        check(syscall2(SYS_FTRUNCATE, (uint64_t)fd, 4096) == 0, "A: ftruncate to 4096");
        uint64_t st[18];
        for (int i = 0; i < 18; i++) st[i] = 0;
        check(syscall2(SYS_FSTAT, (uint64_t)fd, (uint64_t)st) == 0 && st[6] == 4096, "A: fstat reports size 4096");
        check(syscall3(SYS_LSEEK, (uint64_t)fd, 4000, 0) == 4000 &&
              syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 8) == 8 && buf[0] == 0 && buf[7] == 0, "A: the grown range reads as zeros");
    }

    /* B */
    int64_t fd2 = syscall2(SYS_MEMFD, (uint64_t)"scratch", 0);
    check(fd2 >= 0 && fd2 != fd, "B: a second memfd with the same name");
    if (fd2 >= 0) {
        check(syscall3(SYS_READ, (uint64_t)fd2, (uint64_t)buf, sizeof(buf)) == 0, "B: it is a separate, empty file");
        syscall1(SYS_CLOSE, (uint64_t)fd2);
    }
    check(syscall2(SYS_OPEN, (uint64_t)"/tmp/scratch", 0) < 0, "B: nothing named scratch appears under /tmp");

    /* C */
    if (fd >= 0) {
        int64_t kid = syscall1(SYS_FORK, 0);
        if (kid == 0) {
            syscall3(SYS_LSEEK, (uint64_t)fd, 0, 0);
            int ok = syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"CHILD", 5) == 5;
            syscall1(SYS_EXIT, ok ? 0 : 1);
            for (;;) {}
        }
        int32_t st = -1;
        syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
        syscall3(SYS_LSEEK, (uint64_t)fd, 0, 0);
        check(kid > 0 && st == 0 && syscall3(SYS_READ, (uint64_t)fd, (uint64_t)buf, 5) == 5 && buf[0] == 'C' && buf[4] == 'D',
              "C: a forked child writes through the shared memfd");
        syscall1(SYS_CLOSE, (uint64_t)fd);
    }
    int64_t cfd = syscall2(SYS_MEMFD, (uint64_t)"cx", MFD_CLOEXEC);
    check(cfd >= 0 && syscall3(SYS_FCNTL, (uint64_t)cfd, F_GETFD, 0) == FD_CLOEXEC, "C: MFD_CLOEXEC sets FD_CLOEXEC");
    if (cfd >= 0) syscall1(SYS_CLOSE, (uint64_t)cfd);

    /* the last close frees the file: 100 cycles never exhaust the 64-entry tmpfs table */
    {
        int ok = 1;
        for (int i = 0; i < 100 && ok; i++) {
            int64_t f = syscall2(SYS_MEMFD, (uint64_t)"cycle", 0);
            if (f < 0 || syscall3(SYS_WRITE, (uint64_t)f, (uint64_t)"x", 1) != 1) ok = 0;
            if (f >= 0) syscall1(SYS_CLOSE, (uint64_t)f);
        }
        check(ok, "C: 100 create/write/close cycles do not leak tmpfs entries");
    }

    /* E */
    {
        int64_t s = syscall2(SYS_MEMFD, (uint64_t)"sealed", MFD_ALLOW_SEALING);
        check(s >= 0, "E: memfd_create(MFD_ALLOW_SEALING)");
        if (s >= 0) {
            check(syscall3(SYS_FCNTL, (uint64_t)s, F_GET_SEALS, 0) == 0, "E: no seals at first");
            check(syscall3(SYS_WRITE, (uint64_t)s, (uint64_t)"12345678", 8) == 8, "E: write 8 bytes");
            check(syscall3(SYS_FCNTL, (uint64_t)s, F_ADD_SEALS, F_SEAL_GROW | F_SEAL_SHRINK) == 0, "E: add GROW|SHRINK");
            check(syscall3(SYS_FCNTL, (uint64_t)s, F_GET_SEALS, 0) == (F_SEAL_GROW | F_SEAL_SHRINK), "E: F_GET_SEALS reports them");
            check(syscall2(SYS_FTRUNCATE, (uint64_t)s, 16) < 0, "E: growing by ftruncate is refused");
            check(syscall2(SYS_FTRUNCATE, (uint64_t)s, 4) < 0, "E: shrinking by ftruncate is refused");
            check(syscall3(SYS_WRITE, (uint64_t)s, (uint64_t)"x", 1) < 0, "E: appending past the end is refused");
            syscall3(SYS_LSEEK, (uint64_t)s, 0, 0);
            check(syscall3(SYS_WRITE, (uint64_t)s, (uint64_t)"AB", 2) == 2, "E: overwriting inside the size still works");
            check(syscall3(SYS_FCNTL, (uint64_t)s, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_SEAL) == 0, "E: add WRITE|SEAL");
            syscall3(SYS_LSEEK, (uint64_t)s, 0, 0);
            check(syscall3(SYS_WRITE, (uint64_t)s, (uint64_t)"C", 1) < 0, "E: any write is refused after F_SEAL_WRITE");
            syscall3(SYS_LSEEK, (uint64_t)s, 0, 0);
            char rb[8];
            check(syscall3(SYS_READ, (uint64_t)s, (uint64_t)rb, 8) == 8 && rb[0] == 'A' && rb[7] == '8', "E: reads still work");
            check(syscall3(SYS_FCNTL, (uint64_t)s, F_ADD_SEALS, F_SEAL_WRITE) == -EPERM_, "E: F_SEAL_SEAL forbids adding more");
            check(syscall3(SYS_FCNTL, (uint64_t)s, F_ADD_SEALS, 0x100) == -EINVAL_, "E: unknown seal bits are EINVAL (checked before F_SEAL_SEAL, as on Linux)");
            syscall1(SYS_CLOSE, (uint64_t)s);
        }
        /* seals and mmap */
        int64_t m = syscall2(SYS_MEMFD, (uint64_t)"mapped", MFD_ALLOW_SEALING);
        if (m >= 0) {
            syscall2(SYS_FTRUNCATE, (uint64_t)m, 4096);
            int64_t p = syscall6(SYS_MMAP, 0, 4096, 3, 1 /* MAP_SHARED */, (uint64_t)m, 0);
            check(p > 0, "E: MAP_SHARED|PROT_WRITE of an unsealed memfd");
            if (p > 0) {
                *(volatile char *)p = 'M';
                check(syscall3(SYS_FCNTL, (uint64_t)m, F_ADD_SEALS, F_SEAL_WRITE) == -EBUSY_, "E: F_SEAL_WRITE while a shared writable mapping exists is EBUSY");
                syscall2(SYS_MUNMAP, (uint64_t)p, 4096);
            }
            check(syscall3(SYS_FCNTL, (uint64_t)m, F_ADD_SEALS, F_SEAL_WRITE) == 0, "E: after munmap F_SEAL_WRITE is accepted");
            check(syscall6(SYS_MMAP, 0, 4096, 3, 1, (uint64_t)m, 0) == -EPERM_, "E: a new MAP_SHARED|PROT_WRITE mapping of a write-sealed memfd is EPERM");
            int64_t ro = syscall6(SYS_MMAP, 0, 4096, 1, 1, (uint64_t)m, 0);
            check(ro > 0 && *(volatile char *)ro == 'M', "E: a shared read-only mapping still works and sees the data");
            if (ro > 0) syscall2(SYS_MUNMAP, (uint64_t)ro, 4096);
            int64_t pr = syscall6(SYS_MMAP, 0, 4096, 3, 2 /* MAP_PRIVATE */, (uint64_t)m, 0);
            check(pr > 0, "E: a private writable (COW) mapping still works");
            if (pr > 0) syscall2(SYS_MUNMAP, (uint64_t)pr, 4096);
            syscall1(SYS_CLOSE, (uint64_t)m);
        }
        int64_t ns = syscall2(SYS_MEMFD, (uint64_t)"nosealing", 0);
        check(ns >= 0 && syscall3(SYS_FCNTL, (uint64_t)ns, F_GET_SEALS, 0) == F_SEAL_SEAL, "E: without MFD_ALLOW_SEALING the memfd is born F_SEAL_SEAL");
        check(ns >= 0 && syscall3(SYS_FCNTL, (uint64_t)ns, F_ADD_SEALS, F_SEAL_GROW) == -EPERM_, "E: and accepts no seals");
        if (ns >= 0) syscall1(SYS_CLOSE, (uint64_t)ns);
        int64_t tf = syscall3(SYS_OPEN, (uint64_t)"/tmp/h118-seal", 0x42 /* O_RDWR|O_CREAT */, 0600);
        check(tf >= 0 && syscall3(SYS_FCNTL, (uint64_t)tf, F_ADD_SEALS, F_SEAL_GROW) == -EPERM_, "E: an ordinary /tmp file accepts no seals");
        if (tf >= 0) syscall1(SYS_CLOSE, (uint64_t)tf);
        syscall1(87 /* unlink */, (uint64_t)"/tmp/h118-seal");
    }

    /* D */
    check(syscall2(SYS_MEMFD, (uint64_t)"h", MFD_HUGETLB) == -EINVAL_, "D: MFD_HUGETLB is EINVAL");
    check(syscall2(SYS_MEMFD, (uint64_t)"u", 0x100) == -EINVAL_, "D: unknown flags are EINVAL");
    static char longname[300];
    for (int i = 0; i < 299; i++) longname[i] = 'n';
    longname[299] = 0;
    check(syscall2(SYS_MEMFD, (uint64_t)longname, 0) == -EINVAL_, "D: a name over 249 bytes is EINVAL");

    print(failures == 0 ? "hello118: PASS\n" : "hello118: FAIL\n");
    print("hello118 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
