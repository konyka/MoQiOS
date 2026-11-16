/* hello373: net.ipv4.ping_group_range, the groups that may create ping sockets (Linux ping_init_sock checks the egid and the
 * supplementary groups against /proc/sys/net/ipv4/ping_group_range; ipv4_ping_group_range reads and writes it as two gids).
 * Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n`, so gids 0-65535 are mapped and
 * the namespace starts with the default range):
 *   D. the default reads "65534\t65534\n" and nobody, root included, may create a ping socket (EACCES);
 *   W. writing "0 0" returns 3 and reads back "0\t0\n"; root (egid 0) may then; writing "2 9" lets egid 9 and a process with
 *      egid 0 but supplementary group 7 in, not egid 10; a raw socket does not look at the range;
 *   P. writing "7" changes only the low end ("7\t9\n"); "5 3" (inverted) reads back as the empty range; "x", "-1 3" and a value past
 *      4294967294 are EINVAL and change nothing; "1 2 3" sets "1\t2\n" and returns 4 (the bytes up to the third value);
 *   U. a process with uid 1 cannot open the file for writing (EACCES) but still reads it.
 * The test restores the range it found (MoQiOS boots with the empty range too, so later tests are unaffected). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long ping_sock(void) { long s = rc(socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)); if (s >= 0) close((int)s); return s < 0 ? s : 0; }
static long raw_sock(void) { long s = rc(socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)); if (s >= 0) close((int)s); return s < 0 ? s : 0; }
static long open_(const char *p, int fl) { return rc(open(p, fl)); }
static long read_(long fd, char *b, int n) { return rc(read((int)fd, b, n)); }
static long write_(long fd, const char *b, int n) { return rc(write((int)fd, b, n)); }
static void close_(long fd) { close((int)fd); }
static long sresgid(long r, long e, long s) { return rc(setresgid((gid_t)r, (gid_t)e, (gid_t)s)); }
static long sresuid(long r, long e, long s) { return rc(setresuid((uid_t)r, (uid_t)e, (uid_t)s)); }
static long sgroups(int n, const unsigned *g) { gid_t v[4]; for (int i = 0; i < n; i++) v[i] = g[i]; return rc(setgroups(n, v)); }
static long fork_(void) { return fork(); }
static long wait_(long pid) { int st = 0; waitpid((pid_t)pid, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 255; }
static void exit_(int c) { _exit(c); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define O_RDONLY 0
#define O_WRONLY 1
static long ping_sock(void) { long s = syscall3(117, 2, 2, 1); if (s >= 0) syscall1(11, s); return s < 0 ? s : 0; }
static long raw_sock(void) { long s = syscall3(117, 2, 3, 1); if (s >= 0) syscall1(11, s); return s < 0 ? s : 0; }
static long open_(const char *p, int fl) { return syscall3(9, (long)p, fl, 0); }
static long read_(long fd, char *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const char *b, int n) { return syscall3(1, fd, (long)b, n); }
static void close_(long fd) { syscall1(11, fd); }
static long sresgid(long r, long e, long s) { return syscall3(180, r, e, s); }
static long sresuid(long r, long e, long s) { return syscall3(178, r, e, s); }
static long sgroups(int n, const unsigned *g) { return syscall2(488, n, (long)g); }
static long fork_(void) { return syscall0(57); }
static long wait_(long pid) { int st = 0; syscall3(6, pid, (long)&st, 0); return (st >> 8) & 0xff; }
static void exit_(int c) { syscall1(2, c); }
#endif
#define RANGE "/proc/sys/net/ipv4/ping_group_range"
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello373:   ok   " : "hello373:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* The file's text with tabs and newlines shown as T and N. */
static long get_range(char *out) {
    char b[48];
    long fd = open_(RANGE, O_RDONLY);
    if (fd < 0) { out[0] = 0; return fd; }
    long n = read_(fd, b, sizeof b - 1);
    close_(fd);
    if (n < 0) { out[0] = 0; return n; }
    for (long i = 0; i < n; i++) out[i] = b[i] == '\t' ? 'T' : b[i] == '\n' ? 'N' : b[i];
    out[n] = 0;
    return n;
}
static long set_range(const char *text) {
    long fd = open_(RANGE, O_WRONLY);
    if (fd < 0) return fd;
    long n = write_(fd, text, (int)strlen(text));
    close_(fd);
    return n;
}
/* ping_sock() in a child with the given credentials; the exit status encodes the result (0 ok, 13 EACCES, 99 setup failed). */
static long ping_as(long egid, int ngroups, const unsigned *groups, long uid) {
    long pid = fork_();
    if (pid == 0) {
        if (sgroups(ngroups, groups) < 0) exit_(99);
        if (sresgid(egid, egid, egid) < 0) exit_(99);
        if (uid >= 0 && sresuid(uid, uid, uid) < 0) exit_(99);
        long r = ping_sock();
        exit_(r == 0 ? 0 : (int)-r);
    }
    return pid < 0 ? pid : wait_(pid);
}
int main(void) {
    print("hello373: net.ipv4.ping_group_range\n");
    char orig[48], t[48];
    unsigned none[1] = { 0 }, g7[1] = { 7 };
    char saved[48];
    long on = get_range(orig);
    /* Keep the original as written text: "aTbN" back to "a b". */
    long k = 0;
    for (long i = 0; i < on && orig[i] != 'N'; i++) saved[k++] = orig[i] == 'T' ? ' ' : orig[i];
    saved[k] = 0;

    set_range("1 0");
    long dn = get_range(t);
    long d0 = ping_sock();
    snprintf(msg, sizeof msg, "D: the default reads [%s] (%ld bytes), ping socket as root %ld (65534T65534N 12 -13)", t, dn, d0);
    check(dn == 12 && strcmp(t, "65534T65534N") == 0 && d0 == -13, msg);

    long w1 = set_range("0 0");
    long wn = get_range(t);
    int w_read = strcmp(t, "0T0N") == 0;
    long w_root = ping_sock();
    long w2 = set_range("2 9");
    long e9 = ping_as(9, 0, none, -1), s7 = ping_as(0, 1, g7, -1), e10 = ping_as(10, 0, none, -1);
    long rw = raw_sock();
    snprintf(msg, sizeof msg, "W: write 0 0 %ld, reads [%s] %ld, root %ld; write 2 9 %ld: egid 9 %ld, supplementary 7 %ld, egid 10 %ld; raw %ld (3 0T0N 4 0 3 0 0 13 0)", w1, t, wn, w_root, w2, e9, s7, e10, rw);
    check(w1 == 3 && w_read && wn == 4 && w_root == 0 && w2 == 3 && e9 == 0 && s7 == 0 && e10 == 13 && rw == 0, msg);

    long p1 = set_range("7");
    get_range(t);
    int p_low = strcmp(t, "7T9N") == 0;
    long p2 = set_range("5 3");
    get_range(t);
    int p_inv = strcmp(t, "65534T65534N") == 0;
    set_range("1 2");
    long px = set_range("x"), pn = set_range("-1 3"), pb = set_range("0 4294967295");
    get_range(t);
    int p_kept = strcmp(t, "1T2N") == 0;
    long p3 = set_range("1 2 3");
    get_range(t);
    int p_three = strcmp(t, "1T2N") == 0;
    snprintf(msg, sizeof msg, "P: write 7 %ld low only %d; 5 3 %ld empty %d; x %ld, -1 3 %ld, past max %ld kept %d; 1 2 3 %ld kept %d (1 1 3 1 -22 -22 -22 1 4 1)", p1, p_low, p2, p_inv, px, pn, pb, p_kept, p3, p_three);
    check(p1 == 1 && p_low && p2 == 3 && p_inv && px == -22 && pn == -22 && pb == -22 && p_kept && p3 == 4 && p_three, msg);

    long pid = fork_();
    if (pid == 0) {
        if (sresuid(1, 1, 1) < 0) exit_(99);
        long o = open_(RANGE, O_WRONLY);
        char b[48];
        long r = get_range(b);
        exit_(o == -13 && r > 0 ? 0 : 1);
    }
    long uw = wait_(pid);
    snprintf(msg, sizeof msg, "U: uid 1 cannot open it for writing but reads it: child %ld (0)", uw);
    check(uw == 0, msg);

    long back = set_range(saved);
    get_range(t);
    snprintf(msg, sizeof msg, "restored [%s] (%ld)", t, back);
    print("hello373:   info ");
    print(msg);
    print("\n");

    print(failures ? "hello373: FAIL\n" : "hello373: PASS\n");
    return failures ? 1 : 0;
}
