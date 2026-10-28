/// hello115: identity changes and capabilities.
///
/// Launched as uid 0 holding only CAP_SETUID|CAP_SETGID.
///   A. a temporary drop (euid 1000, saved uid 0) clears the effective set
///      but keeps the permitted set; returning to euid 0 restores it.
///   B. a permanent drop (setuid 1000) clears every capability, after which
///      the process cannot become root again.
///   D. euid 0 alone grants nothing: after capset() drops every capability,
///      uid 0 is refused by file permissions, chmod/chown of others' files,
///      SysV IPC permissions and the scheduler like any other user.
///   E. supplementary groups: setgroups needs CAP_SETGID, getgroups reports
///      them, and membership grants the group class of a file's mode (tmpfs
///      and ext2) and of a SysV queue's mode.
///   F. execve: the saved uid becomes the effective uid, and a program run
///      without any root uid gets no capabilities (hello116 reports back).
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
#define SYS_SETRESGID 180
#define SYS_CAPGET    306
#define SYS_CAPSET    307
#define SYS_OPEN      9
#define SYS_CLOSE     11
#define SYS_CHMOD     90
#define SYS_CHOWN     92
#define SYS_UNLINK    111
#define SYS_GETPRIORITY 232
#define SYS_SETPRIORITY 233
#define SYS_MSGGET    156
#define SYS_MSGCTL    159
#define IPC_PRIVATE   0
#define IPC_CREAT     01000
#define IPC_RMID      0
#define EACCES_       13
#define SYS_GETGROUPS 487
#define SYS_EXECVE    59
#define SYS_CAPSET_   307
#define SYS_SETGROUPS 488
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

static void drop_all_caps(void) {
    uint32_t hdr[2] = { 0x20080522u, 0 };
    uint32_t data[6] = { 0 };
    check(syscall2(SYS_CAPSET, (uint64_t)hdr, (uint64_t)data) == 0, "D: capset drops every capability");
    struct caps c = get_caps();
    check(c.eff == 0 && c.perm == 0, "D: capget confirms no capabilities");
}

static void root_without_caps(void) {
    /* fixtures, made while still holding nothing special: root owns them */
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h115-zero");
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/h115-zero", 0x241, 0600);
    if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
    check(fd >= 0 && syscall2(SYS_CHMOD, (uint64_t)"/tmp/h115-zero", 0) == 0, "D: root creates a mode-0000 file of its own");
    /* a file owned by uid 1000: made by a child that became uid 1000 */
    syscall1(SYS_UNLINK, (uint64_t)"/tmp/h115-user");
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        syscall1(SYS_SETUID, 1000);
        int64_t uf = syscall3(SYS_OPEN, (uint64_t)"/tmp/h115-user", 0x241, 0644);
        if (uf >= 0) syscall1(SYS_CLOSE, (uint64_t)uf);
        syscall1(SYS_EXIT, uf >= 0 ? 0 : 1);
        for (;;) {}
    }
    int32_t kst = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&kst, 0);
    check(kid > 0 && kst == 0, "D: uid 1000 creates /tmp/h115-user");
    int64_t q = syscall2(SYS_MSGGET, IPC_PRIVATE, IPC_CREAT | 0600);
    check(q >= 0, "D: msgget(IPC_PRIVATE, 0600)");

    /* uid 1000's 0600 queue: uid 0 without CAP_SYS_ADMIN may neither read its state nor remove it */
    int32_t qid[1] = { -1 };
    int64_t qk = syscall1(SYS_FORK, 0);
    if (qk == 0) {
        syscall1(SYS_SETUID, 1000);
        int64_t uq = syscall2(SYS_MSGGET, IPC_PRIVATE, IPC_CREAT | 0600);
        syscall1(SYS_EXIT, uq >= 0 && uq < 200 ? (uint64_t)uq + 1 : 255);
        for (;;) {}
    }
    int32_t qst = 0;
    syscall3(SYS_WAITPID, (uint64_t)qk, (uint64_t)&qst, 0);
    int code = (qst >> 8) & 0xff;
    qid[0] = (code > 0 && code < 255) ? code - 1 : -1;
    check(qid[0] >= 0, "D: uid 1000 creates a 0600 message queue");

    drop_all_caps();
    uint32_t r, e, s;
    get_ids(&r, &e, &s);
    check(r == 0 && e == 0 && s == 0, "D: still uid 0");

    /* file permission bits apply: the owner class of mode 0000 grants nothing */
    check(syscall2(SYS_OPEN, (uint64_t)"/tmp/h115-zero", 0) == -EACCES_, "D: uid 0 without CAP_DAC_OVERRIDE cannot open a 0000 file");
    /* a root-owned 0700 ext2 directory is still searchable by its owner ... */
    check(syscall2(SYS_OPEN, (uint64_t)"/closeddir/open.txt", 0) >= 0, "D: the owner may still use its own 0700 directory");
    /* ... but another user's file cannot be chmod'ed or given away */
    check(syscall2(SYS_CHMOD, (uint64_t)"/tmp/h115-user", 0777) < 0, "D: uid 0 without CAP_FOWNER cannot chmod uid 1000's file");
    check(syscall3(SYS_CHOWN, (uint64_t)"/tmp/h115-zero", 1000, (uint64_t)-1) < 0, "D: uid 0 without CAP_CHOWN cannot give a file away");
    /* SysV IPC: mode bits decide, uid 0 is just the owner */
    int32_t ds[32];
    check(syscall3(SYS_MSGCTL, (uint64_t)q, 2 /* IPC_STAT */, (uint64_t)ds) == 0, "D: the owner may IPC_STAT its 0600 queue");
    /* scheduler: raising priority needs CAP_SYS_NICE even for uid 0 */
    check(syscall3(SYS_SETPRIORITY, 0, 0, 0) == 0, "D: raising my nice value to 0 needs nothing");
    check(syscall3(SYS_SETPRIORITY, 0, 0, (uint64_t)-1) < 0, "D: uid 0 without CAP_SYS_NICE cannot lower it again");
    check(syscall2(SYS_GETPRIORITY, 0, 0) == 20, "D: the nice value stays 0");
    check(syscall3(SYS_MSGCTL, (uint64_t)q, IPC_RMID, 0) == 0, "D: the owner removes its queue");
    if (qid[0] >= 0) {
        check(syscall3(SYS_MSGCTL, (uint64_t)qid[0], 2, (uint64_t)ds) == -EACCES_, "D: uid 0 without CAP_SYS_ADMIN cannot IPC_STAT another user's 0600 queue");
        check(syscall3(SYS_MSGCTL, (uint64_t)qid[0], IPC_RMID, 0) < 0, "D: nor remove it");
    }
    /* the queue is removed by its owner afterwards (see main_) */
}

/* A new file takes the creator's effective gid; switch egid (CAP_SETGID) to
 * create a root:<gid> file without needing CAP_CHOWN. */
static int64_t make_group_file(const char *path, uint32_t gid) {
    syscall1(SYS_UNLINK, (uint64_t)path);
    if (syscall3(SYS_SETRESGID, KEEP, gid, KEEP) != 0) return -1;
    int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, 0x241, 0640);
    syscall3(SYS_SETRESGID, KEEP, 0, KEEP);
    if (fd < 0) return fd;
    syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"grp\n", 4);
    syscall1(SYS_CLOSE, (uint64_t)fd);
    return syscall2(SYS_CHMOD, (uint64_t)path, 0640);
}

static void supplementary_groups(void) {
    check(make_group_file("/tmp/h115-g60", 60) == 0, "E: root makes a 0640 root:60 tmpfs file");
    check(make_group_file("/tmp/h115-g70", 70) == 0, "E: and a 0640 root:70 tmpfs file");
    check(make_group_file("/testdir/h115-g60", 60) == 0, "E: and a 0640 root:60 ext2 file");
    int64_t q = syscall2(SYS_MSGGET, IPC_PRIVATE, IPC_CREAT | 0640);
    check(q >= 0, "E: msgget(IPC_PRIVATE, 0640)");
    int32_t ds[32];

    uint32_t want[2] = { 50, 60 };
    check(syscall2(SYS_SETGROUPS, 2, (uint64_t)want) == 0, "E: setgroups({50, 60}) with CAP_SETGID");
    uint32_t got[8] = { 0 };
    check(syscall2(SYS_GETGROUPS, 0, 0) == 2, "E: getgroups(0) reports 2");
    check(syscall2(SYS_GETGROUPS, 8, (uint64_t)got) == 2 && got[0] == 50 && got[1] == 60, "E: getgroups returns {50, 60}");
    check(syscall2(SYS_GETGROUPS, 1, (uint64_t)got) == -22, "E: getgroups into a too-small buffer is EINVAL");

    check(syscall1(SYS_SETGID, 1000) == 0 && syscall1(SYS_SETUID, 1000) == 0, "E: become 1000:1000");
    check(syscall2(SYS_GETGROUPS, 8, (uint64_t)got) == 2, "E: the groups survive setuid");
    int64_t fd = syscall2(SYS_OPEN, (uint64_t)"/tmp/h115-g60", 0);
    check(fd >= 0, "E: member of 60 reads a 0640 root:60 tmpfs file");
    if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
    check(syscall2(SYS_OPEN, (uint64_t)"/tmp/h115-g60", 1) == -EACCES_, "E: but cannot write it (group class has no w)");
    check(syscall2(SYS_OPEN, (uint64_t)"/tmp/h115-g70", 0) == -EACCES_, "E: not a member of 70: EACCES");
    fd = syscall2(SYS_OPEN, (uint64_t)"/testdir/h115-g60", 0);
    check(fd >= 0, "E: member of 60 reads a 0640 root:60 ext2 file");
    if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
    check(syscall3(SYS_MSGCTL, (uint64_t)q, 2, (uint64_t)ds) == -EACCES_, "E: a 0640 root:0 queue is not readable (not in group 0)");

    uint32_t none[1] = { 0 };
    check(syscall2(SYS_SETGROUPS, 1, (uint64_t)none) == -1, "E: setgroups without CAP_SETGID is EPERM");
    check(syscall2(SYS_GETGROUPS, 8, (uint64_t)got) == 2 && got[1] == 60, "E: the refused setgroups changed nothing");
    if (failures == 0 && q >= 0 && q < 200) {
        syscall1(SYS_EXIT, (uint64_t)q + 1); /* hand the queue id to the parent */
        for (;;) {}
    }
}

/* Like in_child, but the child exits with (queue id + 1) on success. */
static int64_t run_groups_child(void) {
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        failures = 0;
        supplementary_groups();
        syscall1(SYS_EXIT, 255);
        for (;;) {}
    }
    int32_t st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    int code = (st >> 8) & 0xff;
    return (kid > 0 && (st & 0x7f) == 0 && code > 0 && code < 255) ? code - 1 : -1;
}

static void cleanup_group_fixtures(int64_t q) {
    check(syscall1(SYS_UNLINK, (uint64_t)"/tmp/h115-g60") == 0, "E: cleanup /tmp/h115-g60");
    check(syscall1(SYS_UNLINK, (uint64_t)"/tmp/h115-g70") == 0, "E: cleanup /tmp/h115-g70");
    check(syscall1(SYS_UNLINK, (uint64_t)"/testdir/h115-g60") == 0, "E: cleanup /testdir/h115-g60");
    if (q >= 0) check(syscall3(SYS_MSGCTL, (uint64_t)q, IPC_RMID, 0) == 0, "E: cleanup the queue");
}

/* fork; in the child run `prep` then execve hello116; return its report bits */
static int exec_report(int prep) {
    int64_t kid = syscall1(SYS_FORK, 0);
    if (kid == 0) {
        if (prep == 1) {
            /* drop to uid 1000 but keep root as the saved uid */
            if (syscall3(SYS_SETRESUID, 1000, 1000, 0) != 0) syscall1(SYS_EXIT, 200);
        } else {
            /* stay root, effective set empty, permitted {SETUID, SETGID} */
            uint32_t hdr[2] = { 0x20080522u, 0 };
            uint32_t data[6] = { 0, CAP_SETUID_BIT | CAP_SETGID_BIT, 0, 0, 0, 0 };
            if (syscall2(SYS_CAPSET_, (uint64_t)hdr, (uint64_t)data) != 0) syscall1(SYS_EXIT, 201);
        }
        const char *argv[2] = { "hello116", 0 };
        syscall3(SYS_EXECVE, (uint64_t)"hello116", (uint64_t)argv, 0);
        syscall1(SYS_EXIT, 202);
        for (;;) {}
    }
    int32_t st = 0;
    syscall3(SYS_WAITPID, (uint64_t)kid, (uint64_t)&st, 0);
    if (kid <= 0 || (st & 0x7f) != 0) return -1;
    return (st >> 8) & 0xff;
}

static void exec_credentials(void) {
    int b = exec_report(1);
    check(b >= 0 && b < 200, "F: setresuid(1000,1000,0) then execve hello116");
    check(b >= 0 && (b & 1), "F: after execve the saved uid equals the effective uid");
    check(b >= 0 && (b & 2), "F: a program run with no root uid has no permitted capabilities");
    check(b >= 0 && !(b & 16), "F: so it cannot setuid(0) back to root");
    b = exec_report(2);
    check(b >= 0 && b < 200, "F: root with an empty effective set execs hello116");
    check(b >= 0 && (b & 8) && !(b & 2), "F: euid 0 keeps its permitted capabilities across execve");
    check(b >= 0 && (b & 4), "F: and euid 0 gets them effective (effective = permitted)");
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
    check(in_child(root_without_caps), "D: uid 0 without capabilities scenario");
    int64_t gq = run_groups_child();
    check(gq >= 0, "E: supplementary groups scenario");
    cleanup_group_fixtures(gq);
    exec_credentials();
    /* the scenario's uid-1000 queue: find it again (the child's variable is
     * gone) by trying the ids a fresh boot hands out, as its owner */
    {
        int64_t ck = syscall1(SYS_FORK, 0);
        if (ck == 0) {
            syscall1(SYS_SETUID, 1000);
            int removed = 0;
            for (int id = 0; id < 256; id++) {
                int32_t ds[32];
                if (syscall3(SYS_MSGCTL, (uint64_t)id, 2, (uint64_t)ds) == 0 &&
                    syscall3(SYS_MSGCTL, (uint64_t)id, IPC_RMID, 0) == 0) removed++;
            }
            syscall1(SYS_EXIT, removed == 1 ? 0 : 1);
            for (;;) {}
        }
        int32_t cst = 0;
        syscall3(SYS_WAITPID, (uint64_t)ck, (uint64_t)&cst, 0);
        check(ck > 0 && cst == 0, "D: uid 1000 removes the queue it left behind");
    }
    print(failures == 0 ? "hello115: PASS\n" : "hello115: FAIL\n");
    print("hello115 done\n");
    return failures;
}

void _start(void) {
    int f = main_();
    syscall1(SYS_EXIT, f == 0 ? 0 : 1);
    for (;;) {}
}
