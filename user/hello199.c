/// hello199: mlockall(MCL_CURRENT / MCL_FUTURE), MAP_LOCKED and the RLIMIT_MEMLOCK gates in mmap, brk and mremap,
/// checked against real Linux (host gcc programs run each scenario in a child process; every expected value below
/// was measured there). Runs unprivileged (all capabilities dropped) so the limit applies.

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
#define SYS_BRK 7
#define SYS_MMAP 8
#define SYS_MUNMAP 12
#define SYS_MREMAP 25
#define SYS_FORK 57
#define SYS_MADVISE 235
#define SYS_SETRLIMIT 237
#define SYS_MLOCK 252
#define SYS_MUNLOCK 253
#define SYS_MLOCKALL 271
#define SYS_MUNLOCKALL 272
#define SYS_CAPSET 307

#define RLIMIT_MEMLOCK 8
#define PG 4096ULL
#define PROT_RW 3
#define MAP_PRIV_ANON 0x22
#define MAP_FIXED 0x10
#define MAP_LOCKED 0x2000
#define MREMAP_MAYMOVE 1
#define MADV_DONTNEED 4
#define MCL_CURRENT 1
#define MCL_FUTURE 2
#define MCL_ONFAULT 4
#define EPERM_ (-1)
#define EAGAIN_ (-11)
#define ENOMEM_ (-12)
#define EINVAL_ (-22)

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello199:   ok   " : "hello199:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int64_t MLOCKALL(uint64_t f) { return syscall1(SYS_MLOCKALL, f); }
static int64_t MUNLOCKALL(void) { return syscall1(SYS_MUNLOCKALL, 0); }
static int64_t MLOCK(uint64_t a, uint64_t l) { return syscall2(SYS_MLOCK, a, l); }
static int64_t MADV(uint64_t a, uint64_t l) { return syscall3(SYS_MADVISE, a, l, MADV_DONTNEED); }
static int64_t MAPF(uint64_t pages, uint64_t extra) { return syscall6(SYS_MMAP, 0, pages * PG, PROT_RW, MAP_PRIV_ANON | extra, (uint64_t)-1, 0); }
static int64_t MAP(uint64_t pages) { return MAPF(pages, 0); }
static int64_t MAPFIX(uint64_t addr, uint64_t pages, uint64_t extra) {
    return syscall6(SYS_MMAP, addr, pages * PG, PROT_RW, MAP_PRIV_ANON | MAP_FIXED | extra, (uint64_t)-1, 0);
}
static int64_t BRK(uint64_t a) { return syscall1(SYS_BRK, a); }
static int64_t MREMAP(uint64_t a, uint64_t o, uint64_t n) { return syscall6(SYS_MREMAP, a, o * PG, n * PG, MREMAP_MAYMOVE, 0, 0); }
static int is_addr(int64_t v) { return v > 0x1000; }
/* Locked pages refuse MADV_DONTNEED with EINVAL; unlocked ones accept it. */
static int locked(int64_t p) { return MADV((uint64_t)p, PG) == EINVAL_; }
static int unlocked(int64_t p) { return MADV((uint64_t)p, PG) == 0; }
static void LIMIT(uint64_t pages) {
    uint64_t rl[2] = { pages * PG, pages * PG };
    syscall2(SYS_SETRLIMIT, RLIMIT_MEMLOCK, (uint64_t)rl);
}

/* Each scenario runs in a forked child so a lowered limit or a standing MCL_FUTURE never leaks into the next. */
static void scenario(void (*body)(void), const char *name) {
    int before = failures;
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        body();
        syscall1(SYS_EXIT, failures != before ? 1 : 0);
        for (;;) {}
    }
    int status = 0;
    int ok = pid > 0 && syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0) == pid && ((status >> 8) & 0xff) == 0;
    check(ok, name);
}

/* limit 4: CURRENT cannot fit what is mapped (ENOMEM); FUTURE alone has nothing to check. */
static void s_limit4(void) {
    LIMIT(4);
    check(is_addr(MAP(8)), "A: 8 unlocked pages are mapped (more than the limit)");
    check(MLOCKALL(MCL_CURRENT) == ENOMEM_, "A: MCL_CURRENT over the limit is ENOMEM");
    check(MLOCKALL(MCL_CURRENT | MCL_FUTURE) == ENOMEM_, "A: MCL_CURRENT|MCL_FUTURE is ENOMEM too");
    check(MLOCKALL(MCL_CURRENT | MCL_ONFAULT) == ENOMEM_, "A: MCL_CURRENT|MCL_ONFAULT is ENOMEM too");
    check(MLOCKALL(MCL_FUTURE) == 0, "A: MCL_FUTURE alone succeeds (nothing is locked yet)");
}

/* limit 0, no capability: EPERM for every valid request, EINVAL for bad flags first. */
static void s_limit0(void) {
    LIMIT(0);
    check(MLOCKALL(MCL_CURRENT) == EPERM_, "B: MCL_CURRENT is EPERM");
    check(MLOCKALL(MCL_FUTURE) == EPERM_, "B: MCL_FUTURE is EPERM");
    check(MLOCKALL(MCL_FUTURE | MCL_ONFAULT) == EPERM_, "B: MCL_FUTURE|MCL_ONFAULT is EPERM");
    check(MLOCKALL(0) == EINVAL_, "B: no flags is EINVAL (checked before the privilege)");
    check(MLOCKALL(MCL_ONFAULT) == EINVAL_, "B: MCL_ONFAULT alone is EINVAL");
    check(MLOCKALL(8) == EINVAL_, "B: an unknown flag is EINVAL");
    check(MUNLOCKALL() == 0, "B: munlockall needs no privilege");
    check(MAPF(1, MAP_LOCKED) == EPERM_, "B: MAP_LOCKED is EPERM");
    check(is_addr(MAP(1)), "B: a plain mapping is fine");
    check(MAPF(0, MAP_LOCKED) == EINVAL_, "B: a zero length is EINVAL before the privilege check");
}

/* limit 16 + FUTURE: every new mapping is locked and charged; over the quota is EAGAIN (not ENOMEM). */
static void s_future_quota(void) {
    LIMIT(16);
    check(MLOCKALL(MCL_FUTURE) == 0, "C: MCL_FUTURE under a 16 page limit");
    int64_t a = MAP(8);
    check(is_addr(a) && locked(a), "C: an 8 page mapping is made and locked");
    check(MAP(9) == EAGAIN_, "C: 8 + 9 pages is EAGAIN");
    int64_t c = MAP(8);
    check(is_addr(c), "C: 8 + 8 = 16 fits");
    check(MAP(1) == EAGAIN_, "C: a 17th page is EAGAIN");
    check(syscall2(SYS_MUNMAP, (uint64_t)a, 8 * PG) == 0, "C: munmap the first 8");
    int64_t d = MAP(8);
    check(is_addr(d), "C: munmap released the quota");
    check(MUNLOCKALL() == 0, "C: munlockall");
    int64_t e = MAP(40);
    check(is_addr(e) && unlocked(e), "C: after munlockall mappings are neither locked nor limited");
    check(unlocked(c), "C: and munlockall unlocked the earlier ones");
}

/* CURRENT locks what exists; FUTURE what comes later; a call without FUTURE ends FUTURE. */
static void s_current_future(void) {
    LIMIT(1000);
    int64_t a = MAP(4);
    check(unlocked(a), "D: a plain mapping is unlocked");
    check(MLOCKALL(MCL_CURRENT | MCL_FUTURE) == 0, "D: MCL_CURRENT|MCL_FUTURE");
    check(locked(a), "D: the existing mapping is locked now");
    int64_t b = MAP(4);
    check(locked(b), "D: a new mapping is locked");
    check(MLOCKALL(MCL_CURRENT) == 0, "D: MCL_CURRENT alone");
    int64_t c = MAP(4);
    check(unlocked(c), "D: MCL_CURRENT alone ended MCL_FUTURE: a new mapping is not locked");
    check(locked(a) && locked(b), "D: the earlier mappings stay locked");
    check(MUNLOCKALL() == 0, "D: munlockall");
    check(unlocked(a) && unlocked(b), "D: and unlocks them");
}

/* FUTURE does not touch what already exists. */
static void s_future_only(void) {
    int64_t a = MAP(4);
    check(MLOCKALL(MCL_FUTURE) == 0, "E: MCL_FUTURE");
    check(unlocked(a), "E: an existing mapping is unaffected");
    int64_t b = MAP(4);
    check(locked(b), "E: a new mapping is locked");
    check(MLOCKALL(MCL_CURRENT) == 0, "E: MCL_CURRENT alone");
    check(locked(b), "E: it locks the mapping made under MCL_FUTURE too");
    int64_t c = MAP(4);
    check(unlocked(c), "E: and a later one is not locked");
}

/* A failed MCL_CURRENT leaves MCL_FUTURE as it was. */
static void s_failed_current(void) {
    LIMIT(4);
    check(is_addr(MAP(8)), "F: 8 unlocked pages are mapped");
    check(MLOCKALL(MCL_FUTURE) == 0, "F: MCL_FUTURE");
    check(MLOCKALL(MCL_CURRENT) == ENOMEM_, "F: MCL_CURRENT is ENOMEM");
    check(MAP(5) == EAGAIN_, "F: MCL_FUTURE is still in force: 5 pages is EAGAIN");
    int64_t p = MAP(4);
    check(is_addr(p) && locked(p), "F: 4 pages fit and are locked");
}

/* brk grows the heap under MCL_FUTURE: locked, charged, EAGAIN reported as the unchanged break. The heap is not a
 * tracked mapping, so madvise cannot tell whether it is locked; the quota can. */
static void s_brk(void) {
    LIMIT(64);
    check(MLOCKALL(MCL_FUTURE) == 0, "G: MCL_FUTURE under a 64 page limit");
    int64_t b0 = BRK(0);
    check(BRK((uint64_t)b0 + 10 * PG) == b0 + (int64_t)(10 * PG), "G: brk +10 pages grows");
    check(MAP(55) == EAGAIN_, "G: the 10 heap pages are charged: 10 + 55 > 64");
    check(BRK((uint64_t)b0 + 100 * PG) == b0 + (int64_t)(10 * PG), "G: brk +100 pages is over the limit: the break does not move");
    check(BRK((uint64_t)b0 + 60 * PG) == b0 + (int64_t)(60 * PG), "G: brk to +60 pages grows");
    check(BRK((uint64_t)b0 + 70 * PG) == b0 + (int64_t)(60 * PG), "G: +70 pages would be over 64: refused");
    check(MAP(5) == EAGAIN_, "G: 60 heap pages + 5 > 64");
    int64_t q = MAP(4);
    check(is_addr(q) && locked(q), "G: 60 + 4 = 64 fits");
    check(syscall2(SYS_MUNMAP, (uint64_t)q, 4 * PG) == 0, "G: munmap the 4");
    check(BRK((uint64_t)b0) == b0, "G: shrinking back works");
    check(is_addr(MAP(64)), "G: the shrink released the heap's quota: 64 pages fit");
}

/* Without MCL_FUTURE the heap is not charged at all. */
static void s_brk_plain(void) {
    LIMIT(8);
    int64_t b0 = BRK(0);
    check(BRK((uint64_t)b0 + 100 * PG) == b0 + (int64_t)(100 * PG), "S: brk +100 pages grows under an 8 page limit (no MCL_FUTURE)");
    int64_t p = MAPF(8, MAP_LOCKED);
    check(is_addr(p), "S: and the heap was not charged: 8 MAP_LOCKED pages still fit");
    check(MLOCKALL(MCL_FUTURE) == 0, "S: MCL_FUTURE");
    check(BRK((uint64_t)b0 + 101 * PG) == b0 + (int64_t)(100 * PG), "S: now one more heap page is 8 + 1 > 8: refused");
}

/* mremap: growing a locked mapping is gated and the grown tail is locked. */
static void s_mremap(void) {
    LIMIT(16);
    check(MLOCKALL(MCL_FUTURE) == 0, "H: MCL_FUTURE under a 16 page limit");
    int64_t a = MAP(8);
    check(is_addr(a), "H: 8 locked pages");
    int64_t g = MREMAP((uint64_t)a, 8, 12);
    check(is_addr(g), "H: growing to 12 stays within the limit");
    check(MADV((uint64_t)g + 10 * PG, PG) == EINVAL_, "H: the grown tail is locked");
    check(MREMAP((uint64_t)g, 12, 20) == EAGAIN_, "H: growing to 20 would be 12 + 8 > 16: EAGAIN");
    check(is_addr(MREMAP((uint64_t)g, 12, 4)), "H: shrinking to 4 works");
    int64_t c = MAP(12);
    check(is_addr(c), "H: the shrink released 8 pages: 4 + 12 = 16 fits");
    check(MAP(1) == EAGAIN_, "H: a 17th is EAGAIN");
}

/* An explicit mlock before FUTURE counts toward the same quota. */
static void s_mlock_then_future(void) {
    LIMIT(16);
    int64_t a = MAP(10);
    check(MLOCK((uint64_t)a, 6 * PG) == 0, "I: mlock 6 pages");
    check(MLOCKALL(MCL_FUTURE) == 0, "I: MCL_FUTURE");
    check(is_addr(MAP(10)), "I: 6 + 10 = 16 fits");
    check(MAP(1) == EAGAIN_, "I: a 17th is EAGAIN");
    check(MLOCKALL(MCL_CURRENT) == ENOMEM_, "I: MCL_CURRENT is ENOMEM: everything mapped is more than 16 pages");
}

/* A forked child has no MCL_FUTURE and no locks; the parent keeps both. */
static void s_fork(void) {
    LIMIT(16);
    check(MLOCKALL(MCL_FUTURE) == 0, "J: MCL_FUTURE");
    int64_t a = MAP(8);
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        int ok = is_addr(MAP(100));
        int64_t c = MAP(1);
        ok = ok && is_addr(c) && unlocked(c);
        syscall1(SYS_EXIT, ok ? 0 : 1);
        for (;;) {}
    }
    int status = 0;
    check(pid > 0 && syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0) == pid && ((status >> 8) & 0xff) == 0,
          "J: the child maps 100 pages and its new pages are not locked");
    check(locked(a), "J: the parent's mapping is still locked");
    check(MAP(9) == EAGAIN_, "J: and the parent is still limited");
}

/* A PROT_NONE mapping is locked and counted. */
static void s_prot_none(void) {
    LIMIT(16);
    check(MLOCKALL(MCL_FUTURE) == 0, "K: MCL_FUTURE");
    check(is_addr(syscall6(SYS_MMAP, 0, 4 * PG, 0, MAP_PRIV_ANON, (uint64_t)-1, 0)), "K: a PROT_NONE mapping of 4 pages");
    check(MAP(13) == EAGAIN_, "K: it counts: 4 + 13 > 16");
    check(is_addr(MAP(12)), "K: 4 + 12 = 16 fits");
}

/* MAP_FIXED under FUTURE: the replaced pages are not credited by the gate, and a refused replacement changes nothing. */
static void s_map_fixed(void) {
    LIMIT(12);
    check(MLOCKALL(MCL_FUTURE) == 0, "L: MCL_FUTURE under a 12 page limit");
    int64_t p = MAP(8);
    check(MAPFIX((uint64_t)p, 8, 0) == EAGAIN_, "L: MAP_FIXED of the same 8 over them is 8 + 8 > 12: EAGAIN");
    check(locked(p), "L: the refused replacement left the old pages mapped and locked");
    check(MAPFIX((uint64_t)p, 4, 0) == p, "L: MAP_FIXED of 4 over the first 4 (8 + 4 = 12) works");
    check(locked(p), "L: the new pages are locked");
    check(MAPFIX((uint64_t)p, 5, 0) == EAGAIN_, "L: 5 over the first 5 is 8 + 5 > 12: EAGAIN");
}

/* MAP_LOCKED without mlockall. */
static void s_map_locked(void) {
    LIMIT(8);
    int64_t p = MAPF(4, MAP_LOCKED);
    check(is_addr(p) && locked(p), "M: a MAP_LOCKED mapping is made and locked");
    check(MAPF(5, MAP_LOCKED) == EAGAIN_, "M: 4 + 5 > 8 is EAGAIN");
    check(is_addr(MAPF(4, MAP_LOCKED)), "M: 4 + 4 = 8 fits");
    check(MAPF(1, MAP_LOCKED) == EAGAIN_, "M: a 9th page is EAGAIN");
    int64_t u = MAP(100);
    check(is_addr(u) && unlocked(u), "M: a plain mapping is neither locked nor limited");
}

static void s_map_locked_fixed(void) {
    LIMIT(8);
    int64_t p = MAP(8);
    check(MLOCK((uint64_t)p, 8 * PG) == 0, "N: mlock 8 pages");
    check(MAPFIX((uint64_t)p, 8, MAP_LOCKED) == EAGAIN_, "N: MAP_FIXED|MAP_LOCKED over them is 8 + 8 > 8: EAGAIN");
    check(MAPFIX((uint64_t)p, 8, 0) == p, "N: a plain MAP_FIXED over them works");
    check(unlocked(p), "N: and the replaced pages lost their lock");
}

static void s_map_locked_munmap(void) {
    LIMIT(8);
    int64_t p = MAPF(4, MAP_LOCKED);
    check(syscall2(SYS_MUNMAP, (uint64_t)p, 2 * PG) == 0, "O: munmap half");
    int64_t q = MAPF(6, MAP_LOCKED);
    check(is_addr(q), "O: 2 + 6 = 8 fits after the munmap");
    check(syscall2(SYS_MUNLOCK, (uint64_t)q, 6 * PG) == 0 && unlocked(q), "O: munlock releases them");
}

static void s_map_locked_prot_none(void) {
    LIMIT(8);
    check(is_addr(syscall6(SYS_MMAP, 0, 4 * PG, 0, MAP_PRIV_ANON | MAP_LOCKED, (uint64_t)-1, 0)), "P: a PROT_NONE MAP_LOCKED mapping is made");
    check(MAPF(5, MAP_LOCKED) == EAGAIN_, "P: and counted: 4 + 5 > 8");
}

static void s_map_locked_order(void) {
    LIMIT(0);
    check(MAPF(1, MAP_LOCKED) == EPERM_, "Q: limit 0 MAP_LOCKED is EPERM");
    int64_t x = MAP(1);
    check(is_addr(x) && MAPFIX((uint64_t)x, 1, MAP_LOCKED | 0x100000) == -17, "Q: MAP_FIXED_NOREPLACE on an occupied page is EEXIST before the privilege check");
    check(syscall6(SYS_MMAP, 0x30000000ULL, PG, PROT_RW, MAP_PRIV_ANON | MAP_FIXED | MAP_LOCKED | 0x100000, (uint64_t)-1, 0) == EPERM_,
          "Q: MAP_FIXED_NOREPLACE on a free page is EPERM");
}

/* CURRENT then explicit mlock/munlock. */
static void s_current_munlock(void) {
    LIMIT(1000);
    int64_t p = MAP(8);
    check(MLOCK((uint64_t)p, 2 * PG) == 0, "R: mlock 2 pages");
    check(MLOCKALL(MCL_CURRENT) == 0, "R: MCL_CURRENT");
    check(locked(p + 7 * (int64_t)PG), "R: the last page is locked now");
    check(syscall2(SYS_MUNLOCK, (uint64_t)p, 8 * PG) == 0, "R: munlock all 8");
    check(unlocked(p + 7 * (int64_t)PG), "R: and the last page is free again");
}

void _start(void) {
    print("hello199: mlockall / MAP_LOCKED / RLIMIT_MEMLOCK in mmap, brk, mremap (expected values from real Linux)\n");

    uint32_t hdr[2] = { 0x20080522u, 0 };
    uint32_t data[6] = { 0 };
    check(syscall2(SYS_CAPSET, (uint64_t)hdr, (uint64_t)data) == 0, "capabilities dropped");

    scenario(s_limit4, "scenario A: limit 4");
    scenario(s_limit0, "scenario B: limit 0");
    scenario(s_future_quota, "scenario C: FUTURE quota");
    scenario(s_current_future, "scenario D: CURRENT / FUTURE");
    scenario(s_future_only, "scenario E: FUTURE only");
    scenario(s_failed_current, "scenario F: failed CURRENT");
    scenario(s_brk, "scenario G: brk");
    scenario(s_brk_plain, "scenario S: brk without MCL_FUTURE");
    scenario(s_mremap, "scenario H: mremap");
    scenario(s_mlock_then_future, "scenario I: mlock then FUTURE");
    scenario(s_fork, "scenario J: fork");
    scenario(s_prot_none, "scenario K: PROT_NONE");
    scenario(s_map_fixed, "scenario L: MAP_FIXED");
    scenario(s_map_locked, "scenario M: MAP_LOCKED");
    scenario(s_map_locked_fixed, "scenario N: MAP_LOCKED|MAP_FIXED");
    scenario(s_map_locked_munmap, "scenario O: MAP_LOCKED munmap");
    scenario(s_map_locked_prot_none, "scenario P: MAP_LOCKED PROT_NONE");
    scenario(s_map_locked_order, "scenario Q: check order");
    scenario(s_current_munlock, "scenario R: CURRENT then munlock");

    print(failures == 0 ? "hello199: PASS\n" : "hello199: FAIL\n");
    syscall1(SYS_EXIT, failures ? 1 : 0);
    for (;;) {}
}
