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
#define SYS_UNSHARE 282
#define SYS_PROCESS_MADVISE 440
#define SYS_QUOTACTL_FD 443
#define SYS_RSEQ_SLICE_YIELD 471
#define SYS_PROCESS_MRELEASE 448
#define SYS_MEMFD_SECRET 447
#define SYS_LISTNS 470
#define SYS_SET_MEMPOLICY_HOME_NODE 450
#define SYS_MAP_SHADOW_STACK 453
#define SYS_LSM_GET_SELF_ATTR 459
#define SYS_LSM_SET_SELF_ATTR 460
#define SYS_LSM_LIST_MODULES 461
#define SYS_LANDLOCK_CREATE_RULESET 444
#define SYS_LANDLOCK_ADD_RULE 445
#define SYS_LANDLOCK_RESTRICT_SELF 446
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
    failures += check(syscall4(SYS_LISTNS, (uint64_t)-1, 0, (uint64_t)ruleset_attr, sizeof(ruleset_attr)) == -ENOSYS,
                      "listns #470 returns ENOSYS");
    failures += check(unchanged(ruleset_attr, 0xC3, sizeof(ruleset_attr)), "listns preserves user buffer");
    failures += check(syscall4(SYS_SET_MEMPOLICY_HOME_NODE, 0, 0, 0, 0) == -ENOSYS,
                      "set_mempolicy_home_node #450 returns ENOSYS");
    failures += check(syscall3(SYS_MAP_SHADOW_STACK, 0, 4096, 0) == -ENOSYS,
                      "map_shadow_stack #453 returns ENOSYS");
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

    if (failures == 0) print("hello80: PASS (raw unsupported syscall ENOSYS/no-mutation contracts)\nhello80 done\n");
    else print("hello80: FAILURES\nhello80 done\n");
    exit_raw(failures != 0);
}
