/// hello118: memfd_create(2).
///
///   A. memfd_create returns a read/write fd; data written reads back after
///      lseek; ftruncate grows it with zeros; fstat reports the size.
///   B. The file has no name: two memfds with the same name are separate
///      files, and nothing appears under /tmp.
///   C. A forked child shares the open file (writes are visible across the
///      fork); MFD_CLOEXEC marks the fd close-on-exec.
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
#define EINVAL_       22

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
