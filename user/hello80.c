// hello80 - raw unsupported syscall contracts and user-buffer preservation.

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
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx)
                      : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10)
                      : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_ACCT 281
#define SYS_CHROOT 280
#define SYS_MEMFD_CREATE 285
#define SYS_UNSHARE 282
#define SYS_PROCESS_MADVISE 440
#define SYS_QUOTACTL_FD 443
#define SYS_RSEQ_SLICE_YIELD 471
#define SYS_PROCESS_MRELEASE 448
#define SYS_MEMFD_SECRET 447
#define SYS_LISTNS 470
#define SYS_SET_MEMPOLICY_HOME_NODE 450
#define SYS_MAP_SHADOW_STACK 453
#define SYS_STATMOUNT 457
#define SYS_LISTMOUNT 458
#define SYS_LSM_GET_SELF_ATTR 459
#define SYS_LSM_SET_SELF_ATTR 460
#define SYS_LSM_LIST_MODULES 461
#define SYS_LANDLOCK_CREATE_RULESET 444
#define SYS_LANDLOCK_ADD_RULE 445
#define SYS_LANDLOCK_RESTRICT_SELF 446
#define SYS_MSEAL 462
#define SYS_SETHOSTNAME 264
#define SYS_GETHOSTNAME 265
#define SYS_SETDOMAINNAME 266
#define SYS_SWAPON 318
#define SYS_SWAPOFF 319
#define SYS_UMOUNT2 289
#define EPERM 1
#define SYS_GETPPID 205
#define SYS_GETPRIORITY 232
#define SYS_SETPRIORITY 233
#define SYS_GETPID_L 39
#define ESRCH 3
#define SYS_SCHED_SETAFFINITY 273
#define SYS_SCHED_SETATTR 308
#define SYS_SCHED_GETATTR 309
#define SYS_SCHED_SETSCHEDULER 473
#define SYS_SCHED_GETSCHEDULER 474
#define SYS_KCMP 305
#define SYS_NAME_TO_HANDLE_AT 295
#define SYS_OPEN_BY_HANDLE_AT 296
#define ENOENT 2
#define SYS_MQ_OPEN 186
#define SYS_MQ_UNLINK 187
#define SYS_MQ_TIMEDSEND 188
#define SYS_CLOSE 11
#define EACCES 13
#define O_RDWR_ 2
#define O_CREAT_ 0x40
#define SYS_PMM_SET_RECLAIM_FLOOR 485
#define ENOSYS 38

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static int check(int ok, const char *name) {
    if (!ok) {
        print("hello80: FAIL ");
        print(name);
        print("\n");
        return 1;
    }
    return 0;
}

static int unchanged(const uint8_t *buf, uint8_t value, uint64_t len) {
    for (uint64_t i = 0; i < len; i++) {
        if (buf[i] != value) return 0;
    }
    return 1;
}

__attribute__((noreturn)) static void exit_raw(int status) {
    syscall1(SYS_EXIT, (uint64_t)status);
    for (;;) {}
}

void _start(void) {
    int failures = 0;
    uint8_t acct_buf[32];
    uint8_t iov_buf[32];
    uint8_t ruleset_attr[32];
    uint8_t rule_attr[32];

    for (uint64_t i = 0; i < sizeof(acct_buf); i++) acct_buf[i] = 0xA1;
    for (uint64_t i = 0; i < sizeof(iov_buf); i++) iov_buf[i] = 0xB2;
    for (uint64_t i = 0; i < sizeof(ruleset_attr); i++) ruleset_attr[i] = 0xC3;
    for (uint64_t i = 0; i < sizeof(rule_attr); i++) rule_attr[i] = 0xD4;

    print("hello80: start\n");
    failures += check(syscall1(SYS_ACCT, (uint64_t)acct_buf) == -ENOSYS, "acct #281 returns ENOSYS");
    failures += check(syscall1(SYS_CHROOT, (uint64_t)acct_buf) == -ENOSYS, "chroot #280 returns ENOSYS");
    failures += check(unchanged(acct_buf, 0xA1, sizeof(acct_buf)), "chroot preserves user buffer");
    /* memfd_create is implemented now (hello118); an unknown flag must still fail without side effects */
    failures += check(syscall2(SYS_MEMFD_CREATE, (uint64_t)acct_buf, 0x100) == -22,
                      "memfd_create #285 rejects unknown flags");
    failures += check(unchanged(acct_buf, 0xA1, sizeof(acct_buf)), "acct preserves user buffer");
    failures += check(syscall1(SYS_UNSHARE, 0x10000000) == -ENOSYS, "unshare #282 returns ENOSYS");
    failures += check(syscall5(SYS_PROCESS_MADVISE, (uint64_t)-1, (uint64_t)iov_buf, 1, 0, 0) == -ENOSYS,
                      "process_madvise #440 returns ENOSYS");
    failures += check(unchanged(iov_buf, 0xB2, sizeof(iov_buf)), "process_madvise preserves user buffer");
    failures += check(syscall4(SYS_QUOTACTL_FD, (uint64_t)-1, 0, 0, (uint64_t)acct_buf) == -ENOSYS,
                      "quotactl_fd #443 returns ENOSYS");
    failures += check(unchanged(acct_buf, 0xA1, sizeof(acct_buf)), "quotactl_fd preserves user buffer");
    failures += check(syscall2(SYS_RSEQ_SLICE_YIELD, 0, 0) == -ENOSYS,
                      "rseq_slice_yield #471 returns ENOSYS");
    failures += check(syscall2(SYS_PROCESS_MRELEASE, (uint64_t)-1, 0) == -ENOSYS,
                      "process_mrelease #448 returns ENOSYS");
    failures += check(syscall1(SYS_MEMFD_SECRET, 0) == -ENOSYS,
                      "memfd_secret #447 returns ENOSYS");
    failures += check(syscall1(SYS_MEMFD_SECRET, 0xFFFFFFFFu) == -ENOSYS,
                      "memfd_secret rejects flags without side effects");
    failures += check(syscall4(467 /* open_tree_attr */, (uint64_t)-100, (uint64_t)"/", 0, (uint64_t)ruleset_attr) == -ENOSYS,
                      "open_tree_attr #467 returns ENOSYS");
    failures += check(syscall2(468 /* file_getattr */, 1, (uint64_t)ruleset_attr) == -ENOSYS,
                      "file_getattr #468 returns ENOSYS");
    failures += check(unchanged(ruleset_attr, 0xC3, sizeof(ruleset_attr)), "file_getattr preserves user buffer");
    failures += check(syscall2(469 /* file_setattr */, 1, (uint64_t)ruleset_attr) == -ENOSYS,
                      "file_setattr #469 returns ENOSYS");
    failures += check(syscall4(SYS_LISTNS, (uint64_t)-1, 0, (uint64_t)ruleset_attr, sizeof(ruleset_attr)) == -ENOSYS,
                      "listns #470 returns ENOSYS");
    failures += check(unchanged(ruleset_attr, 0xC3, sizeof(ruleset_attr)), "listns preserves user buffer");
    failures += check(syscall4(SYS_SET_MEMPOLICY_HOME_NODE, 0, 0, 0, 0) == -ENOSYS,
                      "set_mempolicy_home_node #450 returns ENOSYS");
    failures += check(syscall3(SYS_MAP_SHADOW_STACK, 0, 4096, 0) == -ENOSYS,
                      "map_shadow_stack #453 returns ENOSYS");
    failures += check(syscall4(SYS_STATMOUNT, 0, (uint64_t)ruleset_attr, sizeof(ruleset_attr), 0) == -ENOSYS,
                      "statmount #457 returns ENOSYS");
    failures += check(unchanged(ruleset_attr, 0xC3, sizeof(ruleset_attr)), "statmount preserves user buffer");
    failures += check(syscall5(SYS_LISTMOUNT, 0, 0, (uint64_t)ruleset_attr, sizeof(ruleset_attr), 0) == -ENOSYS,
                      "listmount #458 returns ENOSYS");
    failures += check(unchanged(ruleset_attr, 0xC3, sizeof(ruleset_attr)), "listmount preserves user buffer");
    failures += check(syscall4(SYS_LSM_GET_SELF_ATTR, 0, (uint64_t)ruleset_attr, sizeof(ruleset_attr), 0) == -ENOSYS,
                      "lsm_get_self_attr #459 returns ENOSYS");
    failures += check(unchanged(ruleset_attr, 0xC3, sizeof(ruleset_attr)), "lsm_get_self_attr preserves user buffer");
    failures += check(syscall4(SYS_LSM_SET_SELF_ATTR, 0, (uint64_t)ruleset_attr, sizeof(ruleset_attr), 0) == -ENOSYS,
                      "lsm_set_self_attr #460 returns ENOSYS");
    failures += check(syscall3(SYS_LSM_LIST_MODULES, (uint64_t)ruleset_attr, sizeof(ruleset_attr), 0) == -ENOSYS,
                      "lsm_list_modules #461 returns ENOSYS");
    failures += check(unchanged(ruleset_attr, 0xC3, sizeof(ruleset_attr)), "lsm_list_modules preserves user buffer");
    failures += check(syscall3(SYS_LANDLOCK_CREATE_RULESET, (uint64_t)ruleset_attr, sizeof(ruleset_attr), 0) == -ENOSYS,
                      "landlock_create_ruleset #444 returns ENOSYS");
    failures += check(unchanged(ruleset_attr, 0xC3, sizeof(ruleset_attr)), "landlock ruleset buffer preserved");
    failures += check(syscall4(SYS_LANDLOCK_ADD_RULE, (uint64_t)-1, 0, (uint64_t)rule_attr, sizeof(rule_attr)) == -ENOSYS,
                      "landlock_add_rule #445 returns ENOSYS");
    failures += check(unchanged(rule_attr, 0xD4, sizeof(rule_attr)), "landlock rule buffer preserved");
    failures += check(syscall2(SYS_LANDLOCK_RESTRICT_SELF, (uint64_t)-1, 0) == -ENOSYS,
                      "landlock_restrict_self #446 returns ENOSYS");
    /* name_to_handle_at must not hand out a "handle" for a path that does not
     * exist (it used to hash the path string). File handles are not supported:
     * open_by_handle_at is ENOSYS-class, so name_to_handle_at must say so too
     * and leave the caller's buffers untouched. */
    {
        uint8_t handle[32];
        int32_t mount_id = 0x5A5A5A5A;
        for (int i = 0; i < 32; i++) handle[i] = 0xE5;
        int64_t nh = syscall5(SYS_NAME_TO_HANDLE_AT, (uint64_t)-100, (uint64_t)"/no/such/file", (uint64_t)handle, (uint64_t)&mount_id, 0);
        failures += check(nh == -ENOSYS, "name_to_handle_at returns ENOSYS (file handles are not supported)");
        failures += check(unchanged(handle, 0xE5, sizeof(handle)) && mount_id == 0x5A5A5A5A,
                          "name_to_handle_at leaves the handle and mount id untouched");
        failures += check(syscall3(SYS_OPEN_BY_HANDLE_AT, (uint64_t)-1, (uint64_t)handle, 0) == -ENOSYS,
                          "open_by_handle_at returns ENOSYS");
    }

    /* The reclaim-floor test hook changes how every physical allocation in the
     * system behaves; an unprivileged process must not be able to set it. The
     * hook returns the previous floor, so a refused call must also leave it at 0
     * (checked by restoring with a second refused call). */
    failures += check(syscall1(SYS_PMM_SET_RECLAIM_FLOOR, 1ull << 40) == -EPERM,
                      "pmm_set_reclaim_floor by an unprivileged process is EPERM");
    failures += check(syscall1(SYS_PMM_SET_RECLAIM_FLOOR, 0) == -EPERM,
                      "and so is resetting it (the floor was never changed)");

    /* POSIX message queues carry an owner and a mode like files: init (uid 0)
     * created /h80-root with 0600 and /h80-open with 0666. */
    {
        failures += check(syscall4(SYS_MQ_OPEN, (uint64_t)"/h80-root", O_RDWR_, 0, 0) == -EACCES,
                          "mq_open of root's 0600 queue by uid 1000 is EACCES");
        failures += check(syscall1(SYS_MQ_UNLINK, (uint64_t)"/h80-root") == -EACCES,
                          "mq_unlink of root's queue by uid 1000 is EACCES");
        int64_t still = syscall4(SYS_MQ_OPEN, (uint64_t)"/h80-root", O_RDWR_ | O_CREAT_ | 0x80 /* O_EXCL */, 0600, 0);
        failures += check(still == -17 /* EEXIST */, "root's queue still exists after the refused unlink");
        if (still >= 0) syscall1(SYS_CLOSE, (uint64_t)still);
        /* init's umask (022) turned the requested 0666 into 0644 */
        int64_t oq = syscall4(SYS_MQ_OPEN, (uint64_t)"/h80-open", 0 /* O_RDONLY */, 0, 0);
        failures += check(oq >= 0, "mq_open(O_RDONLY) of root's 0644 queue by uid 1000 succeeds");
        if (oq >= 0) syscall1(SYS_CLOSE, (uint64_t)oq);
        failures += check(syscall4(SYS_MQ_OPEN, (uint64_t)"/h80-open", O_RDWR_, 0, 0) == -EACCES,
                          "mq_open(O_RDWR) of it is EACCES: the creator's umask removed the others' write bit");
        int64_t mine = syscall4(SYS_MQ_OPEN, (uint64_t)"/h80-mine", O_RDWR_ | O_CREAT_, 0600, 0);
        failures += check(mine >= 0, "uid 1000 creates its own 0600 queue");
        if (mine >= 0) syscall1(SYS_CLOSE, (uint64_t)mine);
        failures += check(syscall1(SYS_MQ_UNLINK, (uint64_t)"/h80-mine") == 0,
                          "and may unlink its own queue");
    }

    /* mseal promises that a mapping can no longer be changed; reporting success
     * without sealing anything would silently defeat that hardening. */
    failures += check(syscall3(SYS_MSEAL, (uint64_t)acct_buf & ~0xFFFull, 4096, 0) == -ENOSYS,
                      "mseal #462 returns ENOSYS instead of claiming a seal it does not enforce");

    /* Privileged system-wide state: this program runs as uid 1000 with no
     * capabilities, so every call below must be refused (EPERM) and leave
     * the state unchanged. */
    {
        char before[65], after[65];
        for (int i = 0; i < 65; i++) { before[i] = 0; after[i] = 0; }
        syscall2(SYS_GETHOSTNAME, (uint64_t)before, 64);
        failures += check(syscall2(SYS_SETHOSTNAME, (uint64_t)"h80-pwned", 9) == -EPERM,
                          "sethostname by an unprivileged process is EPERM");
        syscall2(SYS_GETHOSTNAME, (uint64_t)after, 64);
        int same = 1;
        for (int i = 0; i < 65; i++) if (before[i] != after[i]) same = 0;
        failures += check(same, "the hostname is unchanged");
        failures += check(syscall2(SYS_SETDOMAINNAME, (uint64_t)"h80-pwned", 9) == -EPERM,
                          "setdomainname by an unprivileged process is EPERM");
        failures += check(syscall2(SYS_SWAPON, (uint64_t)"/dev/vblk1", 0) == -EPERM,
                          "swapon by an unprivileged process is EPERM");
        failures += check(syscall1(SYS_SWAPOFF, (uint64_t)"/dev/vblk1") == -EPERM,
                          "swapoff by an unprivileged process is EPERM");
        failures += check(syscall2(SYS_UMOUNT2, (uint64_t)"/mnt/none", 0) == -EPERM,
                          "umount2 by an unprivileged process is EPERM");
    }

    /* setpriority on another user's process (our parent is init, uid 0) needs
     * CAP_SYS_NICE; on our own process lowering the priority is always allowed,
     * raising it (a lower nice) is not. Out-of-range arguments must not panic. */
    {
        int64_t ppid = syscall1(SYS_GETPPID, 0);
        int64_t before = syscall2(SYS_GETPRIORITY, 0, (uint64_t)ppid);
        failures += check(syscall3(SYS_SETPRIORITY, 0, (uint64_t)ppid, 19) == -EPERM,
                          "setpriority on init (another user's process) is EPERM");
        failures += check(syscall2(SYS_GETPRIORITY, 0, (uint64_t)ppid) == before,
                          "init's priority is unchanged");
        int64_t me = syscall1(SYS_GETPID_L, 0);
        failures += check(syscall3(SYS_SETPRIORITY, 0, (uint64_t)me, 5) == 0,
                          "setpriority lowering my own priority (nice 5) succeeds");
        failures += check(syscall3(SYS_SETPRIORITY, 0, 0, (uint64_t)-5) == -EPERM,
                          "setpriority raising my own priority (nice -5) without CAP_SYS_NICE is EPERM");
        failures += check(syscall3(SYS_SETPRIORITY, 0, 1ull << 40, 0) == -ESRCH,
                          "setpriority with a pid beyond 32 bits is ESRCH, not a kernel panic");
        failures += check(syscall2(SYS_GETPRIORITY, 0, 1ull << 40) == -ESRCH,
                          "getpriority with a pid beyond 32 bits is ESRCH, not a kernel panic");
        failures += check(syscall3(SYS_SETPRIORITY, 0, 0, 1ull << 40) == 0,
                          "setpriority with an absurd nice clamps to 19 instead of panicking");
    }

    /* The rest of the scheduler interface follows the same owner/CAP_SYS_NICE
     * rules, and realtime classes always need CAP_SYS_NICE. kcmp may only
     * inspect processes the caller could ptrace-read (here: its own). */
    {
        int64_t ppid = syscall1(SYS_GETPPID, 0);
        uint64_t mask = 1;
        failures += check(syscall3(SYS_SCHED_SETAFFINITY, (uint64_t)ppid, 8, (uint64_t)&mask) == -EPERM,
                          "sched_setaffinity on init is EPERM");
        failures += check(syscall3(SYS_SCHED_SETAFFINITY, 0, 8, (uint64_t)&mask) == 0,
                          "sched_setaffinity on myself succeeds");
        int32_t prio = 10;
        int64_t init_pol = syscall1(SYS_SCHED_GETSCHEDULER, (uint64_t)ppid);
        int32_t zero_prio = 0;
        failures += check(syscall3(SYS_SCHED_SETSCHEDULER, (uint64_t)ppid, 0, (uint64_t)&zero_prio) == -EPERM,
                          "sched_setscheduler on init is EPERM");
        failures += check(syscall3(SYS_SCHED_SETSCHEDULER, (uint64_t)ppid, 0, (uint64_t)&prio) == -22,
                          "sched_setscheduler with an invalid priority is EINVAL before any permission check");
        failures += check(syscall1(SYS_SCHED_GETSCHEDULER, (uint64_t)ppid) == init_pol,
                          "init's scheduling policy is unchanged");
        failures += check(syscall3(SYS_SCHED_SETSCHEDULER, 0, 1 /* SCHED_FIFO */, (uint64_t)&prio) == -EPERM,
                          "sched_setscheduler(SCHED_FIFO) on myself without CAP_SYS_NICE is EPERM");
        failures += check(syscall1(SYS_SCHED_GETSCHEDULER, 0) == 0,
                          "my policy stays SCHED_OTHER");
        int32_t zero = 0;
        failures += check(syscall3(SYS_SCHED_SETSCHEDULER, 0, 0, (uint64_t)&zero) == 0,
                          "sched_setscheduler(SCHED_OTHER) on myself succeeds");
        /* struct sched_attr: size, policy, flags(u64), nice, priority, ... (48 bytes) */
        uint32_t attr[12];
        for (int i = 0; i < 12; i++) attr[i] = 0;
        attr[0] = 48; attr[1] = 1; /* SCHED_FIFO */ attr[5] = 10;
        failures += check(syscall3(SYS_SCHED_SETATTR, 0, (uint64_t)attr, 0) == -EPERM,
                          "sched_setattr(SCHED_FIFO) on myself without CAP_SYS_NICE is EPERM");
        attr[1] = 0; attr[5] = 0; attr[4] = 0;
        failures += check(syscall3(SYS_SCHED_SETATTR, (uint64_t)ppid, (uint64_t)attr, 0) == -EPERM,
                          "sched_setattr on init is EPERM");
        failures += check(syscall5(SYS_KCMP, (uint64_t)ppid, (uint64_t)ppid, 1 /* KCMP_VM */, 0, 0) == -EPERM,
                          "kcmp on init (another user's process) is EPERM");
        int64_t me = syscall1(SYS_GETPID_L, 0);
        failures += check(syscall5(SYS_KCMP, (uint64_t)me, (uint64_t)me, 1 /* KCMP_VM */, 0, 0) == 0,
                          "kcmp of myself with myself is 0");
    }

    if (failures == 0) print("hello80: PASS (raw unsupported syscall ENOSYS/no-mutation contracts)\nhello80 done\n");
    else print("hello80: FAILURES\nhello80 done\n");
    exit_raw(failures != 0);
}
