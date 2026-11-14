/* hello328: setfsuid / setfsgid and the filesystem ids (Linux kernel/sys.c __sys_setfsuid, __sys_setfsgid; security/commoncap.c
 * cap_task_fix_setuid LSM_SETID_FS). Runs as root holding CAP_SETUID, CAP_SETGID, CAP_DAC_OVERRIDE, CAP_FOWNER and CAP_CHOWN.
 * Measured on the host (build with -DHOST, run under `unshare --map-auto --map-root-user`):
 *   A. setfsuid(-1) / setfsgid(-1) change nothing and return the current fs ids (initially the effective ids, 0);
 *   B. setfsuid(1000) returns the old fsuid 0, and the next call reads back 1000; setfsgid(2000) the same; /proc/self/status shows
 *      them as the fourth Uid and Gid fields while the effective ids stay 0;
 *   C. with fsuid 1000 a root-owned 0600 file cannot be opened (EACCES): the filesystem checks use the fs ids, and moving fsuid away
 *      from 0 dropped the file-system capabilities (CAP_DAC_OVERRIDE, CAP_FOWNER, CAP_CHOWN) from the effective set (CapEff);
 *   D. a file created then belongs to fsuid 1000 and fsgid 2000, not to the effective ids;
 *   E. access() still judges as the real ids, faccessat2(AT_EACCESS) as the fs ids: a root 0600 file is allowed and EACCES; a root
 *      0000 file is allowed too, since access() as real root uses the permitted capabilities, not the effective ones fsuid cut;
 *   F. chmod of the root-owned file is EPERM, of the file owned by fsuid 1000 allowed;
 *   G. setfsuid(0) brings fsuid back and the capabilities with it (CapEff as before), so the root-owned file opens again;
 *   H. setresuid / setresgid with an effective id move the fs ids with it; with every argument -1 the fs ids stay;
 *   I. without CAP_SETUID, setfsuid only takes the real, effective, saved or current fs id: anything else returns the old value
 *      and changes nothing; setfsgid likewise without CAP_SETGID;
 *   J. a forked child inherits the fs ids, and execve resets them to the effective ids. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sfsuid(long id) { return syscall(SYS_setfsuid, id); }
static long sfsgid(long id) { return syscall(SYS_setfsgid, id); }
static long sresuid(long r, long e, long s) { return syscall(SYS_setresuid, r, e, s) == -1 ? -errno : 0; }
static long sresgid(long r, long e, long s) { return syscall(SYS_setresgid, r, e, s) == -1 ? -errno : 0; }
static long op(const char *p, long fl, long mode) { long r = open(p, (int)fl, (int)mode); return r < 0 ? -errno : r; }
static long acc2(const char *p, long mode, long flags) { long r = syscall(SYS_faccessat2, AT_FDCWD, p, mode, flags); return r == -1 ? -errno : r; }
static long chm(const char *p, long mode) { return chmod(p, (mode_t)mode) == 0 ? 0 : -errno; }
static long ul(const char *p) { return unlink(p) == 0 ? 0 : -errno; }
static long fown(int fd, unsigned *uid, unsigned *gid) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -errno;
    *uid = st.st_uid;
    *gid = st.st_gid;
    return 0;
}
static long reexec(const char *self) {
    execl(self, self, "after", (char *)0);
    return -errno;
}
#define DIR_ "/tmp/h328d"
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stat.h"
static long sfsuid(long id) { return syscall1(504, id); }
static long sfsgid(long id) { return syscall1(505, id); }
static long sresuid(long r, long e, long s) { return syscall3(178, r, e, s); }
static long sresgid(long r, long e, long s) { return syscall3(180, r, e, s); }
static long op(const char *p, long fl, long mode) { return open(p, fl, mode); }
static long acc2(const char *p, long mode, long flags) { return syscall4(321, -100, (long)p, mode, flags); }
static long chm(const char *p, long mode) { return syscall2(SYS_chmod, (long)p, mode); }
static long ul(const char *p) { return unlink(p); }
static long fown(int fd, unsigned *uid, unsigned *gid) {
    struct stat st;
    long r = syscall2(SYS_fstat, fd, (long)&st);
    if (r < 0) return r;
    *uid = st.st_uid;
    *gid = st.st_gid;
    return 0;
}
static long reexec(const char *self) {
    const char *argv[3] = { self, "after", 0 };
    const char *envp[1] = { 0 };
    return syscall3(SYS_execve, (long)self, (long)argv, (long)envp);
}
#define DIR_ "/tmp/h328d"
#endif

#define F_ROOT DIR_ "/root600"
#define F_NEW DIR_ "/new"
#define F_ZERO DIR_ "/zero"

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello328:   ok   " : "hello328:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

/* The Uid/Gid line of /proc/self/status, as four numbers, and the CapEff mask. */
static char text[4096];
static int status_ids(const char *key, long out[4]) {
    out[0] = out[1] = out[2] = out[3] = -1;
    int fd = (int)op("/proc/self/status", 0, 0);
    if (fd < 0) return -1;
    long n = read(fd, text, sizeof text - 1);
    close(fd);
    if (n <= 0) return -1;
    text[n] = 0;
    char want[16];
    snprintf(want, sizeof want, "\n%s:\t", key);
    char *p = strstr(text, want);
    if (!p) return -1;
    p += strlen(want);
    for (int i = 0; i < 4; i++) {
        long v = 0;
        while (*p == '\t' || *p == ' ') p++;
        if (*p < '0' || *p > '9') return -1;
        while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
        out[i] = v;
    }
    return 0;
}
static unsigned long cap_eff(void) {
    long ids[4];
    status_ids("Uid", ids);
    char *p = strstr(text, "\nCapEff:\t");
    if (!p) return ~0UL;
    p += 9;
    unsigned long v = 0;
    for (int i = 0; i < 16; i++) {
        char c = p[i];
        v = v * 16 + (unsigned long)(c >= 'a' ? c - 'a' + 10 : c - '0');
    }
    return v;
}
#define FS_CAPS ((1UL << 0) | (1UL << 1) | (1UL << 3))

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "after") == 0) {
        long a = sfsuid(-1), b = sfsgid(-1);
        return a == 0 && b == 0 ? 0 : 1;
    }
    print("hello328: setfsuid / setfsgid\n");
    mkdir(DIR_, 0777);
    chm(DIR_, 0777);
    int f = (int)op(F_ROOT, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (f >= 0) close(f);
    f = (int)op(F_ZERO, O_CREAT | O_WRONLY | O_TRUNC, 0);
    if (f >= 0) close(f);

    long a0 = sfsuid(-1), a1 = sfsuid(-1), a2 = sfsgid(-1), a3 = sfsgid(-1);
    snprintf(msg, sizeof msg, "A: setfsuid(-1)/setfsgid(-1) read the fs ids and change nothing (%ld %ld %ld %ld)", a0, a1, a2, a3);
    check(a0 == 0 && a1 == 0 && a2 == 0 && a3 == 0, msg);

    unsigned long caps0 = cap_eff();
    long b0 = sfsuid(1000), b1 = sfsuid(-1), b2 = sfsgid(2000), b3 = sfsgid(-1);
    long u[4], g[4];
    status_ids("Uid", u);
    status_ids("Gid", g);
    snprintf(msg, sizeof msg, "B: setfsuid(1000)/setfsgid(2000) return the old ids; status shows %ld %ld %ld %ld / %ld %ld %ld %ld (%ld %ld %ld %ld)", u[0], u[1],
             u[2], u[3], g[0], g[1], g[2], g[3], b0, b1, b2, b3);
    check(b0 == 0 && b1 == 1000 && b2 == 0 && b3 == 2000 && u[0] == 0 && u[1] == 0 && u[2] == 0 && u[3] == 1000 && g[0] == 0 && g[1] == 0 && g[2] == 0 &&
              g[3] == 2000,
          msg);

    unsigned long caps1 = cap_eff();
    long c0 = op(F_ROOT, O_RDONLY, 0);
    if (c0 >= 0) close((int)c0);
    snprintf(msg, sizeof msg, "C: fsuid 1000 cannot open a root 0600 file, the fs capabilities left CapEff (%ld; %lx -> %lx)", c0, caps0, caps1);
    check(c0 == -13 && (caps0 & FS_CAPS) == FS_CAPS && (caps1 & FS_CAPS) == 0 && (caps1 & (1UL << 7)) != 0, msg);

    unsigned du = 9, dg = 9;
    int nf = (int)op(F_NEW, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    long d0 = nf >= 0 ? fown(nf, &du, &dg) : nf;
    if (nf >= 0) close(nf);
    snprintf(msg, sizeof msg, "D: a new file belongs to the fs ids (%ld: uid %u gid %u)", d0, du, dg);
    check(d0 == 0 && du == 1000 && dg == 2000, msg);

    long e0 = acc2(F_ROOT, 4, 0), e1 = acc2(F_ROOT, 4, 0x200), e2 = acc2(F_ZERO, 4, 0), e3 = acc2(F_ZERO, 4, 0x200);
    snprintf(msg, sizeof msg, "E: access judges as the real ids (permitted caps), AT_EACCESS as the fs ids (0600: %ld %ld; 0000: %ld %ld)", e0, e1, e2, e3);
    check(e0 == 0 && e1 == -13 && e2 == 0 && e3 == -13, msg);

    long f0 = chm(F_ROOT, 0644), f1 = chm(F_NEW, 0600);
    snprintf(msg, sizeof msg, "F: chmod of the root file is EPERM, of the fsuid's own file allowed (%ld %ld)", f0, f1);
    check(f0 == -1 && f1 == 0, msg);

    long g0 = sfsuid(0), g1 = sfsuid(-1);
    unsigned long caps2 = cap_eff();
    long g2 = op(F_ROOT, O_RDONLY, 0);
    if (g2 >= 0) close((int)g2);
    sfsgid(0);
    snprintf(msg, sizeof msg, "G: setfsuid(0) restores fsuid and the fs capabilities (%ld %ld; %lx; open %ld)", g0, g1, caps2, g2);
    check(g0 == 1000 && g1 == 0 && caps2 == caps0 && g2 >= 0, msg);

    sfsuid(1000);
    sfsgid(2000);
    long h0 = sresuid(-1, -1, -1), h1 = sfsuid(-1), h2 = sresgid(-1, -1, -1), h3 = sfsgid(-1);
    long h4 = sresuid(-1, 0, -1), h5 = sfsuid(-1), h6 = sresgid(-1, 0, -1), h7 = sfsgid(-1);
    snprintf(msg, sizeof msg, "H: setres[ug]id(-1,-1,-1) keep the fs ids, an effective id moves them (%ld %ld %ld %ld; %ld %ld %ld %ld)", h0, h1, h2, h3, h4,
             h5, h6, h7);
    check(h0 == 0 && h1 == 1000 && h2 == 0 && h3 == 2000 && h4 == 0 && h5 == 0 && h6 == 0 && h7 == 0, msg);

    long ic = fork();
    if (ic == 0) {
        int bits = 0;
        if (sresuid(1000, 1000, 0) != 0) _exit(255);
        if (sfsuid(-1) == 1000) bits |= 1;
        if (sfsuid(1234) == 1000 && sfsuid(-1) == 1000) bits |= 2;
        if (sfsuid(0) == 1000 && sfsuid(-1) == 0) bits |= 4;
        long fd = op(F_ROOT, O_RDONLY, 0);
        if (fd >= 0) {
            bits |= 8;
            close((int)fd);
        }
        if (sfsgid(4321) == 0 && sfsgid(-1) == 0) bits |= 16;
        _exit(bits);
    }
    int ist = -1;
    while (waitpid(ic, &ist, 0) != ic) {}
    snprintf(msg, sizeof msg, "I: unprivileged setfsuid takes only real/effective/saved/fs ids, setfsgid likewise (bits 0x%x, want 0x1f)", (ist >> 8) & 0xff);
    check(((ist >> 8) & 0xff) == 0x1f, msg);

    sfsuid(1000);
    sfsgid(2000);
    long jc = fork();
    if (jc == 0) {
        long x = sfsuid(-1), y = sfsgid(-1);
        if (x != 1000 || y != 2000) _exit(2);
        reexec(argv[0]);
        _exit(3);
    }
    int jst = -1;
    while (waitpid(jc, &jst, 0) != jc) {}
    sfsuid(0);
    sfsgid(0);
    snprintf(msg, sizeof msg, "J: a child inherits the fs ids, execve resets them to the effective ids (status 0x%x)", jst);
    check(jst == 0, msg);

    ul(F_NEW);
    ul(F_ROOT);
    ul(F_ZERO);
    rmdir(DIR_);
    print(failures == 0 ? "hello328: PASS\n" : "hello328: FAIL\n");
    return failures;
}
