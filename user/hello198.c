/// hello198: mlock / munlock / munlockall with RLIMIT_MEMLOCK, checked against real Linux (host gcc runs; every
/// expected value below was measured there). Runs unprivileged (all capabilities dropped) so the limit applies.
/// mlockall stays ENOSYS (MCL_FUTURE has no auto-lock hook in mmap yet); hello71 pins that. mlock2 is MoQiOS number 496.

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
static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_WAITPID 6
#define SYS_MMAP 8
#define SYS_MUNMAP 12
#define SYS_FORK 57
#define SYS_MPROTECT 164
#define SYS_MADVISE 235
#define SYS_SETRLIMIT 237
#define SYS_MLOCK 252
#define SYS_MUNLOCK 253
#define SYS_MLOCKALL 271
#define SYS_MUNLOCKALL 272
#define SYS_CAPSET 307
#define SYS_MLOCK2 496

#define RLIMIT_MEMLOCK 8
#define PG 4096ULL
#define PROT_R 1
#define PROT_RW 3
#define MAP_PRIV_ANON 0x22
#define MAP_FIXED 0x10
#define EPERM_ (-1)
#define ENOMEM_ (-12)
#define EINVAL_ (-22)
#define ENOSYS_ (-38)

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello198:   ok   " : "hello198:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int64_t MLOCK(uint64_t a, uint64_t l) { return syscall2(SYS_MLOCK, a, l); }
static int64_t MUNLOCK(uint64_t a, uint64_t l) { return syscall2(SYS_MUNLOCK, a, l); }
static int64_t MUNLOCKALL(void) { return syscall1(SYS_MUNLOCKALL, 0); }
static int64_t MADV(uint64_t a, uint64_t l, int64_t v) { return syscall3(SYS_MADVISE, a, l, (uint64_t)v); }
static uint64_t MAP(uint64_t pages) { return (uint64_t)syscall6(SYS_MMAP, 0, pages * PG, PROT_RW, MAP_PRIV_ANON, (uint64_t)-1, 0); }
static void LIMIT(uint64_t pages) {
    uint64_t rl[2] = { pages * PG, pages * PG };
    syscall2(SYS_SETRLIMIT, RLIMIT_MEMLOCK, (uint64_t)rl);
}

void _start(void) {
    print("hello198: mlock/munlock + RLIMIT_MEMLOCK (expected values from real Linux)\n");

    /* Drop every capability: CAP_IPC_LOCK would bypass the limit. Limits are only ever lowered from here on. */
    uint32_t hdr[2] = { 0x20080522u, 0 };
    uint32_t data[6] = { 0 };
    check(syscall2(SYS_CAPSET, (uint64_t)hdr, (uint64_t)data) == 0, "capabilities dropped");

    /* ---- limit 4 pages ---- */
    LIMIT(4);
    uint64_t p = MAP(32);
    check(p > 0x1000, "32 pages mapped");
    check(MLOCK(p, 4 * PG) == 0, "A: lock 4 pages (limit 4)");
    check(syscall2(SYS_MUNMAP, p, 2 * PG) == 0, "A: munmap the first 2 locked pages");
    check(MLOCK(p + 10 * PG, 2 * PG) == 0, "A: 2 still locked + 2 more = 4, so it fits (munmap released the quota)");
    check(MLOCK(p + 12 * PG, 1 * PG) == ENOMEM_, "A: a 5th page is ENOMEM");
    check((int64_t)syscall6(SYS_MMAP, p + 2 * PG, PG, PROT_RW, MAP_PRIV_ANON | MAP_FIXED, (uint64_t)-1, 0) == (int64_t)(p + 2 * PG),
          "A: MAP_FIXED over a locked page");
    check(MLOCK(p + 12 * PG, 1 * PG) == 0, "A: the replaced page released its lock");
    check(MLOCK(p + 13 * PG, 1 * PG) == ENOMEM_, "A: but the quota is full again");
    check(MUNLOCKALL() == 0, "A: munlockall");

    uint64_t q = MAP(32);
    check(MLOCK(q, 2 * PG) == 0, "B: lock 2 pages");
    check(syscall3(SYS_MPROTECT, q, 2 * PG, PROT_R) == 0, "B: mprotect them read-only");
    check(MLOCK(q + 4 * PG, 3 * PG) == ENOMEM_, "B: mprotect does not unlock: 2 + 3 > 4");
    check(MLOCK(q + 4 * PG, 2 * PG) == 0, "B: 2 + 2 = 4");
    check(MUNLOCKALL() == 0, "B: munlockall");
    check(syscall3(SYS_MPROTECT, q, 2 * PG, PROT_RW) == 0, "B: restore write access");

    check(MLOCK(q, 4 * PG) == 0, "C: lock 4 pages");
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        syscall1(SYS_EXIT, MLOCK(q + 10 * PG, 4 * PG) == 0 ? 0 : 1);
        for (;;) {}
    }
    int status = 0;
    check(pid > 0 && syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0) == pid && ((status >> 8) & 0xff) == 0,
          "C: a forked child starts with no locks (it may lock a full quota)");
    check(MLOCK(q + 10 * PG, 1 * PG) == ENOMEM_, "C: the parent still holds its 4");
    check(MUNLOCKALL() == 0, "C: munlockall");

    uint8_t *m = (uint8_t *)q;
    for (int i = 0; i < 3 * (int)PG; i++) m[i] = 0x5A;
    check(MLOCK(q + PG, PG) == 0, "D: lock page 1");
    check(MADV(q, 3 * PG, 4) == EINVAL_, "D: MADV_DONTNEED over a locked page is EINVAL");
    check(MADV(q + PG, PG, 8) == EINVAL_, "D: MADV_FREE on a locked page is EINVAL");
    check(MADV(q + PG, PG, 4) == EINVAL_, "D: MADV_DONTNEED on exactly the locked page is EINVAL");
    check(m[PG] == 0x5A && m[2 * PG] == 0x5A, "D: the locked page and its neighbour keep their data");
    check(MUNLOCK(q + PG, PG) == 0, "D: munlock");
    check(MADV(q + PG, PG, 4) == 0, "D: DONTNEED works after munlock");
    check(MUNLOCK(q + 20 * PG, PG) == 0, "D: munlock of a never-locked page succeeds");

    /* ---- limit 2 pages ---- */
    LIMIT(2);
    check(MLOCK(0x30000000ULL, PG) == ENOMEM_, "E: an unmapped page is ENOMEM");
    check(MLOCK(0x30000000ULL, 3 * PG) == ENOMEM_, "E: an unmapped 3-page range is ENOMEM");
    check(MLOCK(q, 3 * PG) == ENOMEM_, "E: 3 pages over a 2-page limit is ENOMEM");
    check(MLOCK(q, 2 * PG) == 0, "E: 2 pages fit");
    check(MLOCK(q, 2 * PG) == 0, "E: locking them again changes nothing");
    check(MLOCK(q + 2 * PG, PG) == ENOMEM_, "E: a 3rd page is ENOMEM");
    check(MUNLOCK(q, PG) == 0, "E: munlock one");
    check(MLOCK(q + 2 * PG, PG) == 0, "E: now the 3rd page fits");
    check(MLOCK(q + 3 * PG, PG) == ENOMEM_, "E: a 3rd locked page is ENOMEM");
    check(MUNLOCKALL() == 0, "E: munlockall");
    check(MLOCK(q + 100, PG) == 0, "F: a range straddling a page boundary counts 2 pages");
    check(MLOCK(q + PG + 5, 1) == 0, "F: a byte inside the second of them is already locked");
    check(MLOCK(q + 2 * PG, 1) == ENOMEM_, "F: the next page is over the limit");
    check(MUNLOCKALL() == 0, "F: munlockall");
    check(MLOCK(q + 100, 0) == 0, "G: an unaligned zero-length mlock still locks the page it starts in");
    check(MLOCK(q + PG, 2 * PG) == ENOMEM_, "G: so 1 + 2 pages is over the limit of 2");
    check(MLOCK(q + PG, PG) == 0, "G: and 1 + 1 fits");
    check(MUNLOCK(q + 100, 0) == 0, "G: an unaligned zero-length munlock unlocks that page");
    check(MLOCK(q + 2 * PG, PG) == 0, "G: freeing it made room");
    check(MUNLOCKALL() == 0, "G: munlockall");

    /* ---- mlock2 (MoQiOS number 496; flags: only MLOCK_ONFAULT = 1, anything else EINVAL) ---- */
    /* still at limit 2 (a process cannot raise its hard limit again); the quota checks below fit in 2 pages */
    check(syscall3(SYS_MLOCK2, q, PG, 0) == 0, "J: mlock2 flags 0 locks like mlock");
    check(syscall3(SYS_MLOCK2, q + PG, PG, 1) == 0, "J: MLOCK_ONFAULT is accepted (the second of the 2 allowed pages)");
    check(syscall3(SYS_MLOCK2, q + 2 * PG, PG, 1) == ENOMEM_, "J: and ONFAULT is charged like any lock: a 3rd page is ENOMEM");
    check(syscall3(SYS_MLOCK2, q, PG, 2) == EINVAL_, "J: an unknown flag is EINVAL");
    check(syscall3(SYS_MLOCK2, q, PG, 3) == EINVAL_, "J: ONFAULT with an unknown flag is EINVAL");
    check(syscall3(SYS_MLOCK2, q, PG, 0x100) == EINVAL_, "J: 0x100 is EINVAL");
    check(syscall3(SYS_MLOCK2, q, PG, 0xFFFFFFFFu) == EINVAL_, "J: all bits is EINVAL");
    check(syscall3(SYS_MLOCK2, q, 0, 0) == 0 && syscall3(SYS_MLOCK2, q, 0, 1) == 0, "J: length 0 with valid flags succeeds");
    check(syscall3(SYS_MLOCK2, q, 0, 2) == EINVAL_, "J: length 0 with a bad flag is EINVAL (flags first)");
    check(syscall3(SYS_MLOCK2, 0x30000000ULL, PG, 2) == EINVAL_, "J: flags are checked before the range");
    check(syscall3(SYS_MLOCK2, 0x30000000ULL, PG, 0) == ENOMEM_, "J: an unmapped range is ENOMEM");
    check(MADV(q, PG, 4) == EINVAL_, "J: an mlock2-locked page refuses MADV_DONTNEED");
    check(MUNLOCKALL() == 0, "J: munlockall");
    /* ---- limit 0: no privilege, no locking ---- */
    LIMIT(0);
    check(MLOCK(q, 0) == EPERM_, "H: mlock with a zero limit is EPERM even for length 0");
    check(MLOCK(0x30000000ULL, PG) == EPERM_, "H: and for an unmapped range");
    check(MLOCK(q, PG) == EPERM_, "H: and for a mapped one");
    check(MUNLOCK(q, PG) == 0, "H: munlock needs no privilege");
    check(MUNLOCK(0x30000000ULL, PG) == ENOMEM_, "H: munlock of an unmapped range is ENOMEM");
    check(MUNLOCKALL() == 0, "H: munlockall");
    check(syscall1(SYS_MLOCKALL, 1) == ENOSYS_, "I: mlockall is still not implemented (ENOSYS; real Linux says EPERM at limit 0)");

    check(syscall3(SYS_MLOCK2, q, PG, 0) == EPERM_ && syscall3(SYS_MLOCK2, q, PG, 1) == EPERM_, "J: a zero limit is EPERM for valid flags");
    check(syscall3(SYS_MLOCK2, q, PG, 2) == EINVAL_, "J: but a bad flag is EINVAL even at limit 0");
    check(syscall3(SYS_MLOCK2, q, 0, 2) == EINVAL_, "J: and for length 0");

    print(failures == 0 ? "hello198: PASS\n" : "hello198: FAIL\n");
    syscall1(SYS_EXIT, failures ? 1 : 0);
    for (;;) {}
}
