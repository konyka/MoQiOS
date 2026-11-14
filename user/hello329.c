/* hello329: who may open another process's /proc/<pid>/maps and /proc/<pid>/fd (Linux fs/proc/task_mmu.c proc_maps_open ->
 * proc_mem_open -> mm_access(PTRACE_MODE_READ_FSCREDS), kernel/ptrace.c __ptrace_may_access; fs/proc/fd.c proc_fd_permission, the
 * directory being mode 0500 owned by the target's effective ids, fs/proc/base.c task_dump_owner). Runs as root holding CAP_SETUID,
 * CAP_SETGID, CAP_SYS_PTRACE and CAP_DAC_OVERRIDE. A target child takes the listed ids and waits; an observer child takes its own ids
 * and capabilities and opens the target's maps and fd directory. Measured on the host (build with -DHOST, run under
 * `unshare --map-auto --map-root-user`; the host target calls PR_SET_DUMPABLE, which MoQiOS has no notion of):
 *   A. observer and target both uid 1000 everywhere: maps and fd open;
 *   B. a target with saved uid 0, C. with real uid 0, D. with saved gid 0, E. with an effective gid other than the observer's: maps
 *      is EACCES (the caller's fsuid must equal all three target uids and its fsgid all three target gids), fd still opens (the
 *      directory belongs to the target's effective uid, which is the observer's fsuid);
 *   F. root without capabilities, target uid 1000: both EACCES;
 *   G. root without capabilities but fsuid 1000: both open (the checks use the fs ids);
 *   H. root holding only CAP_SYS_PTRACE: maps opens, fd is EACCES (the directory permission is a DAC check);
 *   I. root holding only CAP_DAC_OVERRIDE: maps is EACCES, fd opens;
 *   K. a process always reaches its own maps and fd, here root with fsuid 1000 and no capabilities. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sfsuid(long id) { return syscall(SYS_setfsuid, id); }
static long sresuid(long r, long e, long s) { return syscall(SYS_setresuid, r, e, s) == -1 ? -errno : 0; }
static long sresgid(long r, long e, long s) { return syscall(SYS_setresgid, r, e, s) == -1 ? -errno : 0; }
static long capset_(const void *h, const void *d) { return syscall(SYS_capset, h, d) == -1 ? -errno : 0; }
static long op(const char *p) { long r = open(p, O_RDONLY); return r < 0 ? -errno : r; }
static void dumpable(void) { prctl(PR_SET_DUMPABLE, 1); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
static long sfsuid(long id) { return syscall1(504, id); }
static long sresuid(long r, long e, long s) { return syscall3(178, r, e, s); }
static long sresgid(long r, long e, long s) { return syscall3(180, r, e, s); }
static long capset_(const void *h, const void *d) { return syscall2(307, (long)h, (long)d); }
static long op(const char *p) { return open(p, O_RDONLY, 0); }
static void dumpable(void) {}
#endif

#define EACCES_ 13
#define CAP_DAC_OVERRIDE_BIT (1u << 1)
#define CAP_SETGID_BIT (1u << 6)
#define CAP_SETUID_BIT (1u << 7)
#define CAP_SYS_PTRACE_BIT (1u << 19)
#define KEEP_CAPS 0xffffffffu

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello329:   ok   " : "hello329:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

struct cap_hdr { unsigned version; int pid; };
struct cap_data { unsigned eff, perm, inh; };
static long setcaps(unsigned eff) {
    struct cap_hdr h = { 0x20080522u, 0 };
    struct cap_data d[2] = { { eff, eff, 0 }, { 0, 0, 0 } };
    return capset_(&h, d);
}
static long try_open(const char *p) {
    long r = op(p);
    if (r >= 0) {
        close((int)r);
        return 0;
    }
    return r;
}
static void paths(long pid, char maps[48], char fd[48]) {
    snprintf(maps, 48, "/proc/%ld/maps", pid);
    snprintf(fd, 48, "/proc/%ld/fd", pid);
}
/* Result bits an observer exits with: maps opened 1, maps EACCES 2, fd opened 4, fd EACCES 8; 64 + n for a failed setup step n. */
static int bits(long maps, long fd) {
    return (maps == 0 ? 1 : 0) | (maps == -EACCES_ ? 2 : 0) | (fd == 0 ? 4 : 0) | (fd == -EACCES_ ? 8 : 0);
}

static int run(long tr, long te, long ts, long tgr, long tge, long tgs, long orr, long oe, long os, long ogr, long oge, long ogs, long ofs,
               unsigned ocaps) {
    int ready[2], hold[2];
    if (pipe(ready) != 0 || pipe(hold) != 0) return 64;
    long t = fork();
    if (t == 0) {
        close(hold[1]);
        if (sresgid(tgr, tge, tgs) != 0) _exit(1);
        if (sresuid(tr, te, ts) != 0) _exit(2);
        dumpable();
        char c = 1;
        write(ready[1], &c, 1);
        read(hold[0], &c, 1);
        _exit(0);
    }
    char c = 0;
    read(ready[0], &c, 1);
    int result = 64;
    if (c == 1) {
        long o = fork();
        if (o == 0) {
            char maps[48], fd[48];
            paths(t, maps, fd);
            if (sresgid(ogr, oge, ogs) != 0) _exit(65);
            if (sresuid(orr, oe, os) != 0) _exit(66);
            if (ofs >= 0) sfsuid(ofs);
            if (ocaps != KEEP_CAPS && setcaps(ocaps) != 0) _exit(67);
            long a = try_open(maps);
            long b = try_open(fd);
            _exit(bits(a, b));
        }
        int st = 0;
        while (waitpid(o, &st, 0) != o) {}
        result = (st >> 8) & 0xff;
    }
    close(hold[1]);
    int tst = 0;
    while (waitpid(t, &tst, 0) != t) {}
    close(ready[0]);
    close(ready[1]);
    close(hold[0]);
    return result;
}

static void expect(const char *what, int got, int want) {
    snprintf(msg, sizeof msg, "%s: maps %s, fd %s (result %d, want %d)", what, (want & 1) ? "opens" : "EACCES", (want & 4) ? "opens" : "EACCES", got,
             want);
    check(got == want, msg);
}

int main(void) {
    print("hello329: /proc/<pid>/maps and /proc/<pid>/fd access\n");
    const int both = 1 | 4, maps_only = 1 | 8, fd_only = 2 | 4, none = 2 | 8;
    const unsigned ids = CAP_SETUID_BIT | CAP_SETGID_BIT;
    expect("A: same ids everywhere", run(1000, 1000, 1000, 0, 0, 0, 1000, 1000, 1000, 0, 0, 0, -1, KEEP_CAPS), both);
    expect("B: target saved uid 0", run(1000, 1000, 0, 0, 0, 0, 1000, 1000, 1000, 0, 0, 0, -1, KEEP_CAPS), fd_only);
    expect("C: target real uid 0", run(0, 1000, 1000, 0, 0, 0, 1000, 1000, 1000, 0, 0, 0, -1, KEEP_CAPS), fd_only);
    expect("D: target saved gid 0", run(1000, 1000, 1000, 2000, 2000, 0, 1000, 1000, 1000, 2000, 2000, 2000, -1, KEEP_CAPS), fd_only);
    expect("E: target effective gid differs", run(1000, 1000, 1000, 2000, 0, 2000, 1000, 1000, 1000, 2000, 2000, 2000, -1, KEEP_CAPS), fd_only);
    expect("F: root without capabilities", run(1000, 1000, 1000, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, ids), none);
    expect("G: root without capabilities, fsuid 1000", run(1000, 1000, 1000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1000, ids), both);
    expect("H: root with CAP_SYS_PTRACE only", run(1000, 1000, 1000, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, ids | CAP_SYS_PTRACE_BIT), maps_only);
    expect("I: root with CAP_DAC_OVERRIDE only", run(1000, 1000, 1000, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, ids | CAP_DAC_OVERRIDE_BIT), fd_only);

    int ks[2];
    long k = -1;
    if (pipe(ks) == 0) k = fork();
    if (k == 0) {
        if (setcaps(ids) != 0) _exit(65);
        sfsuid(1000);
        char maps[48], fd[48];
        paths(getpid(), maps, fd);
        long a = try_open(maps);
        long b = try_open(fd);
        _exit(bits(a, b));
    }
    int kst = 0;
    if (k > 0)
        while (waitpid(k, &kst, 0) != k) {}
    expect("K: its own process, root with fsuid 1000 and no capabilities", k > 0 ? (kst >> 8) & 0xff : 64, both);

    print(failures ? "hello329: FAIL\n" : "hello329: PASS\n");
    return failures ? 1 : 0;
}
