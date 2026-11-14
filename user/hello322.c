/* hello322: who may be sent SIGIO (Linux fs/fcntl.c __f_setown records the setter's uid and euid; sigio_perm checks them at send
 * time: owner euid is root, or owner euid or uid equals the target's uid or saved uid).
 * Measured on the host in a user namespace (build with -DHOST, run under `unshare --map-auto --map-root-user`):
 *   A. a setter with uid/euid/suid 1 makes root the owner: root gets nothing;
 *   B. a setter with uid 0 (euid 1) matches root's uid: root gets it;
 *   C. a setter with euid 0 (uid 1) is root: root gets it;
 *   D. a setter whose only 0 is its saved uid matches nothing: root gets nothing;
 *   E. a root setter reaches any target (Linux: fown euid GLOBAL_ROOT_UID; namespace root is not that, so the host run gets 0);
 *   F. a uid-1 setter reaches a target whose saved uid is 1 (uid/euid 2);
 *   G. ... and one whose uid is 1; but not one whose only 1 is its euid (H);
 *   I. the credentials are taken when the owner is set: a root setter that drops to uid 1 afterwards still reaches root;
 *   J. F_SETOWN_EX records them too: a uid-1 setter's TID owner of root gets nothing;
 *   K. a -pgrp owner set by uid 1 reaches the group members with uid 1 and skips root. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long sresuid(long r, long e, long s) { return setresuid((uid_t)r, (uid_t)e, (uid_t)s) == 0 ? 0 : -errno; }
static volatile long hits;
static void on_io(int s) { (void)s; hits++; }
static void handle_io(void) { signal(SIGIO, on_io); }
static long my_pgrp(void) { return getpgrp(); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long sresuid(long r, long e, long s) { return syscall3(178, r, e, s); }
static volatile long hits;
static void on_io(int s) { (void)s; hits++; }
static void handle_io(void) {
    struct ksigaction sa = { on_io, 0, (void *)0, 0 };
    sigaction(29, &sa, (struct ksigaction *)0);
}
static long my_pgrp(void) { return getpgid(0); }
#endif
#define C_SETFL 4
#define C_SETOWN 8
#define C_SETOWN_EX 15
#define A_SYNC 0x2000

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello322:   ok   " : "hello322:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void settle(void) { for (int i = 0; i < 20 && hits == 0; i++) usleep(5000); }
static int st_of(long c) {
    int st = -1;
    while (waitpid(c, &st, 0) != c) {}
    return (st >> 8) & 0xff;
}

/* A child with credentials (r,e,s) makes us (root) the owner of an O_ASYNC pipe; we then write. Our hits; *rc the child's status. */
static long owner_set_by(long r, long e, long s, int ex, int *rc) {
    int p[2];
    pipe(p);
    fc(p[0], C_SETFL, A_SYNC);
    long me = getpid();
    long c = fork();
    if (c == 0) {
        if (sresuid(r, e, s) != 0) _exit(9);
        struct { int type, pid; } o = { 0, (int)me };
        _exit((ex ? fc(p[0], C_SETOWN_EX, (long)&o) : fc(p[0], C_SETOWN, me)) == 0 ? 0 : 8);
    }
    *rc = st_of(c);
    hits = 0;
    write(p[1], "x", 1);
    settle();
    close(p[0]);
    close(p[1]);
    return hits;
}

/* A target child with credentials (tr,te,ts) waits; a setter child with (sr,se,ss) makes it the owner (or, with grp, makes -pgrp the
 * owner); we write. Returns the target's hits (9: setresuid failed); *root_hits our own. */
static int target(long sr, long se, long ss, long tr, long te, long ts, int grp, long *root_hits) {
    int p[2], go[2];
    pipe(p);
    pipe(go);
    fc(p[0], C_SETFL, A_SYNC);
    hits = 0;
    long t = fork();
    if (t == 0) {
        if (sresuid(tr, te, ts) != 0) _exit(9);
        write(go[1], "r", 1);
        for (int i = 0; i < 40 && hits == 0; i++) usleep(5000);
        _exit((int)hits);
    }
    char b;
    read(go[0], &b, 1);
    long pg = my_pgrp();
    long sc = fork();
    if (sc == 0) {
        if (sresuid(sr, se, ss) != 0) _exit(9);
        _exit(fc(p[0], C_SETOWN, grp ? -pg : t) == 0 ? 0 : 8);
    }
    int src = st_of(sc);
    write(p[1], "x", 1);
    int st = st_of(t);
    *root_hits = hits;
    close(p[0]);
    close(p[1]);
    close(go[0]);
    close(go[1]);
    return src != 0 ? 100 + src : st;
}

/* Linux exempts an owner whose euid is the initial namespace's root; inside a user namespace (the host run) root is not that. */
static int root_is_global(void) {
#ifdef HOST
    char buf[64] = { 0 };
    int fd = open("/proc/self/uid_map", O_RDONLY);
    if (fd < 0) return 1;
    read(fd, buf, sizeof buf - 1);
    close(fd);
    long a = -1, b = -1;
    sscanf(buf, "%ld %ld", &a, &b);
    return a == 0 && b == 0;
#else
    return 1;
#endif
}

int main(void) {
    print("hello322: SIGIO permission (sigio_perm)\n");
    handle_io();
    setpgid(0, 0);
    int rc = -1;
    long a = owner_set_by(1, 1, 1, 0, &rc);
    snprintf(msg, sizeof msg, "A: an owner set by uid 1 does not reach root (%d hits %ld)", rc, a);
    check(rc == 0 && a == 0, msg);
    long b = owner_set_by(0, 1, 1, 0, &rc);
    snprintf(msg, sizeof msg, "B: the setter's uid 0 matches root's uid (%d hits %ld)", rc, b);
    check(rc == 0 && b == 1, msg);
    long c = owner_set_by(1, 0, 1, 0, &rc);
    snprintf(msg, sizeof msg, "C: the setter's euid 0 matches (%d hits %ld)", rc, c);
    check(rc == 0 && c == 1, msg);
    long d = owner_set_by(1, 1, 0, 0, &rc);
    snprintf(msg, sizeof msg, "D: the setter's saved uid does not count (%d hits %ld)", rc, d);
    check(rc == 0 && d == 0, msg);

    long rh = 0;
    int e = target(0, 0, 0, 1, 1, 1, 0, &rh);
    int ge = root_is_global();
    snprintf(msg, sizeof msg, "E: a root setter reaches a uid 1 target when root is the initial one (%d, global %d)", e, ge);
    check(e == ge, msg);
    int f = target(1, 1, 1, 2, 2, 1, 0, &rh), g = target(1, 1, 1, 1, 2, 2, 0, &rh), h = target(1, 1, 1, 2, 1, 2, 0, &rh);
    snprintf(msg, sizeof msg, "F-H: a uid 1 setter reaches saved uid 1 (%d) and uid 1 (%d), not euid 1 alone (%d)", f, g, h);
    check(f == 1 && g == 1 && h == 0, msg);

    int ip[2];
    pipe(ip);
    fc(ip[0], C_SETFL, A_SYNC);
    long me = getpid();
    hits = 0;
    long ic = fork();
    if (ic == 0) {
        fc(ip[0], C_SETOWN, me);
        if (sresuid(1, 1, 1) != 0) _exit(9);
        _exit(write(ip[1], "x", 1) == 1 ? 0 : 8);
    }
    int ist = st_of(ic);
    settle();
    close(ip[0]);
    close(ip[1]);
    snprintf(msg, sizeof msg, "I: the setter's credentials are taken when the owner is set (%d hits %ld)", ist, hits);
    check(ist == 0 && hits == 1, msg);

    long j = owner_set_by(1, 1, 1, 1, &rc);
    snprintf(msg, sizeof msg, "J: F_SETOWN_EX records the setter too (%d hits %ld)", rc, j);
    check(rc == 0 && j == 0, msg);

    long kroot = -1;
    int k = target(1, 1, 1, 1, 1, 1, 1, &kroot);
    snprintf(msg, sizeof msg, "K: a -pgrp owner set by uid 1 reaches the uid 1 member (%d), skips root (%ld)", k, kroot);
    check(k == 1 && kroot == 0, msg);

    print(failures == 0 ? "hello322: PASS\n" : "hello322: FAIL\n");
    return failures;
}
