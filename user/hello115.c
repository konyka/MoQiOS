/// hello115: identity changes and capabilities.
///
/// Launched as uid 0 holding only CAP_SETUID|CAP_SETGID.
///   A. a temporary drop (euid 1000, saved uid 0) clears the effective set
///      but keeps the permitted set; returning to euid 0 restores it.
///   B. a permanent drop (setuid 1000) clears every capability, after which
///      the process cannot become root again.
///   C. without CAP_SETUID a process may still "set" its own uid (no-op) and
///      shuffle among its own real/effective/saved ids, but not pick others.

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
#define SYS_FORK      57
#define SYS_SETUID    174
#define SYS_SETGID    175
#define SYS_SETREUID  176
#define SYS_SETRESUID 178
#define SYS_GETRESUID 179
#define SYS_CAPGET    306
#define KEEP          0xFFFFFFFFull
#define CAP_SETUID_BIT (1u << 5)
#define CAP_SETGID_BIT (1u << 6)

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello115:   ok   " : "hello115:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

struct caps { uint32_t eff, perm, inh; };
static struct caps get_caps(void) {
    uint32_t hdr[2] = { 0x20080522u, 0 };
    uint32_t data[6] = { 0 };
    struct caps c = { 0xDEAD, 0xDEAD, 0xDEAD };
    if (syscall2(SYS_CAPGET, (uint64_t)hdr, (uint64_t)data) == 0) {
        c.eff = data[0];
        c.perm = data[1];
        c.inh = data[2];
    }
    return c;
}
static void get_ids(uint32_t *r, uint32_t *e, uint32_t *s) {
    *r = *e = *s = 0xDEAD;
    syscall3(SYS_GETRESUID, (uint64_t)r, (uint64_t)e, (uint64_t)s);
}

/* Runs `fn` in a child so each scenario starts from the launch identity. */
static int in_child(void (*fn)(void)) {
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        failures = 0; /* count only this scenario's checks */
        fn();
        syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
        for (;;) {}
    }
    int32_t st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    return kid > 0 && ((st >> 8) & 0xff) == 0 && (st & 0x7f) == 0;
}

static void temporary_drop(void) {
    check(syscall3(SYS_SETRESUID, KEEP, 1000, KEEP) == 0, "A: setresuid(-1, 1000, -1) as root");
    struct caps c = get_caps();
    check(c.eff == 0, "A: euid 1000 leaves no effective capabilities");
    check((c.perm & CAP_SETUID_BIT) != 0, "A: the permitted set survives while the saved uid is 0");
    check(syscall3(SYS_SETRESUID, KEEP, 0, KEEP) == 0, "A: euid 0 is reachable again through the saved uid");
    c = get_caps();
    check((c.eff & CAP_SETUID_BIT) != 0, "A: back at euid 0 the effective set is restored");
}

static void permanent_drop(void) {
    check(syscall1(SYS_SETUID, 1000) == 0, "B: setuid(1000) as root");
    uint32_t r, e, s;
    get_ids(&r, &e, &s);
    check(r == 1000 && e == 1000 && s == 1000, "B: real, effective and saved uid are all 1000");
    struct caps c = get_caps();
    check(c.eff == 0 && c.perm == 0, "B: every capability is gone");
    check(syscall1(SYS_SETUID, 0) < 0, "B: setuid(0) afterwards is refused");
    check(syscall3(SYS_SETRESUID, 0, 0, 0) < 0, "B: setresuid(0, 0, 0) afterwards is refused");
    /* gid is still 0 (its own real gid, always allowed); a foreign gid needs CAP_SETGID */
    check(syscall1(SYS_SETGID, 4242) < 0, "B: setgid to a foreign gid afterwards is refused (CAP_SETGID went too)");
    get_ids(&r, &e, &s);
    check(r == 1000 && e == 1000 && s == 1000, "B: the refused calls changed nothing");
    /* C */
    check(syscall1(SYS_SETUID, 1000) == 0, "C: setuid to my own uid needs no capability");
    check(syscall2(SYS_SETREUID, KEEP, 4242) < 0, "C: setreuid to a foreign euid is refused");
}

static void shuffle_own_ids(void) {
    /* real 1000, effective 0, saved 2000: then lose the capabilities */
    check(syscall3(SYS_SETRESUID, 1000, 0, 2000) == 0, "C: root sets r=1000 e=0 s=2000");
    check(syscall3(SYS_SETRESUID, KEEP, 2000, KEEP) == 0, "C: euid 0 -> 2000");
    struct caps c = get_caps();
    check(c.eff == 0 && c.perm == 0, "C: no uid is 0 any more, so the capabilities are gone");
    check(syscall3(SYS_SETRESUID, 2000, 1000, KEEP) == 0, "C: swapping among my own ids works without CAP_SETUID");
    check(syscall3(SYS_SETRESUID, KEEP, 0, KEEP) < 0, "C: but 0 is no longer one of them");
    uint32_t r, e, s;
    get_ids(&r, &e, &s);
    check(r == 2000 && e == 1000 && s == 2000, "C: ids are r=2000 e=1000 s=2000");
}

int main_(void) {
    print("hello115: identity changes and capabilities\n");
    uint32_t r, e, s;
    get_ids(&r, &e, &s);
    struct caps c = get_caps();
    check(r == 0 && e == 0 && s == 0, "launched as uid 0");
    check(c.eff == (CAP_SETUID_BIT | CAP_SETGID_BIT), "launched with exactly CAP_SETUID|CAP_SETGID");
    check(in_child(temporary_drop), "A: temporary drop scenario");
    check(in_child(permanent_drop), "B/C: permanent drop scenario");
    check(in_child(shuffle_own_ids), "C: own-id shuffle scenario");
    print(failures == 0 ? "hello115: PASS\n" : "hello115: FAIL\n");
    print("hello115 done\n");
    return failures;
}

void _start(void) {
    int f = main_();
    syscall1(SYS_EXIT, f == 0 ? 0 : 1);
    for (;;) {}
}
