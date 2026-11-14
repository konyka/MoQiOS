/* hello310: a flock belongs to its open file description and an fcntl lock to its process, and the two kinds do not interact.
 * Measured on the host (build with -DHOST), every probe below runs in a separate process with its own open of the file:
 *   A. another process opening and closing the file does not drop a flock held by someone else (probe EWOULDBLOCK);
 *   B. same for a whole-file fcntl lock;
 *   C. a second open in the SAME process cannot take a flock held through the first open (EWOULDBLOCK);
 *   D. a dup of the locking descriptor can (0), and the lock outlives closing the original while the dup is open;
 *   E. closing ANY descriptor of the file drops the process's fcntl locks, a byte range one included;
 *   F. a flock does not block an fcntl lock, nor the other way round;
 *   G. F_GETLK does not report a flock;
 *   H. a flock shared with a forked child survives the child's exit and goes with the parent's close;
 *   I. F_GETLK reports another process's write lock as F_WRLCK and its read lock as F_RDLCK, with the holder's pid;
 *   J. a second range lock by the same process does not replace the first;
 *   L. unlocking the middle of a locked range leaves both ends locked;
 *   K. two new empty files are locked independently (FAT32 root on the target, /tmp on the host). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long do_flock(long fd, long op) { long r = syscall(SYS_flock, fd, op); return r < 0 ? -errno : r; }
static long do_fcntl(long fd, long cmd, void *p) { long r = syscall(SYS_fcntl, fd, cmd, p); return r < 0 ? -errno : r; }
static const char *K1 = "/tmp/h310k1", *K2 = "/tmp/h310k2";
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
static long do_flock(long fd, long op) { return syscall2(185, fd, op); }
static long do_fcntl(long fd, long cmd, void *p) { return syscall3(142, fd, cmd, (long)p); }
static const char *K1 = "h310k1.txt", *K2 = "h310k2.txt";
#endif

#define L_EX 2
#define L_NB 4
#define L_UN 8
#define C_GETLK 5
#define C_SETLK 6
#define T_WRLCK 1
#define T_UNLCK 2

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello310:   ok   " : "hello310:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

/* x86_64 struct flock: l_type@0 l_whence@2 l_start@8 l_len@16 l_pid@24, 32 bytes. */
struct lk { unsigned char b[32]; };
static long range_lock(int fd, int cmd, int type, long start, long len, int *out_type) {
    struct lk l;
    memset(&l, 0, sizeof l);
    l.b[0] = (unsigned char)type;
    memcpy(l.b + 8, &start, 8);
    memcpy(l.b + 16, &len, 8);
    long r = do_fcntl(fd, cmd, &l);
    if (out_type) *out_type = l.b[0];
    return r;
}
static long posix_ex(int fd) { return range_lock(fd, C_SETLK, T_WRLCK, 0, 0, 0); }
static long flock_ex(int fd) { return do_flock(fd, L_EX | L_NB); }

static const char *F = "/tmp/h310a";
static int open_f(const char *p) { return open(p, O_RDWR | O_CREAT, 0600); }

/* A separate process tries one fcntl call on [start, start+len): the result, and for F_GETLK the reported type and pid. */
struct pr { long r; long type; long pid; };
static struct pr probe_range(int cmd, int type, long start, long len) {
    int pp[2];
    pipe(pp);
    long c = fork();
    if (c == 0) {
        int fd = open_f(F);
        struct lk l;
        memset(&l, 0, sizeof l);
        l.b[0] = (unsigned char)type;
        memcpy(l.b + 8, &start, 8);
        memcpy(l.b + 16, &len, 8);
        struct pr o;
        o.r = do_fcntl(fd, cmd, &l);
        o.type = l.b[0];
        int pid = 0;
        memcpy(&pid, l.b + 24, 4);
        o.pid = pid;
        write(pp[1], &o, sizeof o);
        _exit(0);
    }
    struct pr o = { -999, -1, -1 };
    read(pp[0], &o, sizeof o);
    int st;
    waitpid(c, &st, 0);
    close(pp[0]);
    close(pp[1]);
    return o;
}

/* A separate process opens `path` and tries one non-blocking lock: 0 when it gets it, else the negative errno. */
enum { P_FLOCK, P_POSIX, P_RANGE, P_GETLK };
static long probe(const char *path, int kind) {
    long c = fork();
    if (c == 0) {
        int fd = open_f(path);
        long r;
        if (kind == P_FLOCK) r = flock_ex(fd);
        else if (kind == P_POSIX) r = posix_ex(fd);
        else if (kind == P_RANGE) r = range_lock(fd, C_SETLK, T_WRLCK, 0, 10, 0);
        else {
            int t = -1;
            r = range_lock(fd, C_GETLK, T_WRLCK, 0, 0, &t);
            if (r == 0) r = -100 - t;
        }
        _exit(r < 0 ? (int)-r : 0);
    }
    int st = 0;
    waitpid(c, &st, 0);
    return -(long)((st >> 8) & 0xff);
}

/* A/B: a child holds the lock; the parent's own open+close of the file must not drop it. */
static void foreign_close(int posix, const char *name) {
    int up[2], down[2];
    pipe(up);
    pipe(down);
    long c = fork();
    if (c == 0) {
        int f = open_f(F);
        long r = posix ? posix_ex(f) : flock_ex(f);
        write(up[1], &r, sizeof r);
        char x;
        read(down[0], &x, 1);
        _exit(0);
    }
    long held = -1;
    read(up[0], &held, sizeof held);
    int fd = open_f(F);
    close(fd);
    long r = probe(F, posix ? P_POSIX : P_FLOCK);
    snprintf(msg, sizeof msg, "%s (held %ld, probe %ld)", name, held, r);
    check(held == 0 && r == -11, msg);
    write(down[1], "x", 1);
    int st;
    waitpid(c, &st, 0);
    close(up[0]);
    close(up[1]);
    close(down[0]);
    close(down[1]);
}

int main(void) {
    foreign_close(0, "A: another process's open+close does not drop a flock");
    foreign_close(1, "B: another process's open+close does not drop a whole-file fcntl lock");

    {
        int f1 = open_f(F), f2 = open_f(F);
        long a = flock_ex(f1), b = flock_ex(f2);
        snprintf(msg, sizeof msg, "C: a second open in the same process cannot take the flock (%ld %ld)", a, b);
        check(a == 0 && b == -11, msg);
        close(f2);
        int f3 = dup(f1);
        long d = flock_ex(f3);
        close(f1);
        long still = probe(F, P_FLOCK);
        close(f3);
        long gone = probe(F, P_FLOCK);
        snprintf(msg, sizeof msg, "D: a dup shares the flock and keeps it after the original closes (%ld %ld %ld)", d, still, gone);
        check(d == 0 && still == -11 && gone == 0, msg);
    }
    {
        int f1 = open_f(F);
        long a = range_lock(f1, C_SETLK, T_WRLCK, 0, 10, 0);
        long held = probe(F, P_RANGE);
        int f2 = open_f(F);
        close(f2);
        long after = probe(F, P_RANGE);
        snprintf(msg, sizeof msg, "E: closing another descriptor of the file drops the process's range lock (%ld %ld %ld)", a, held, after);
        check(a == 0 && held == -11 && after == 0, msg);
        close(f1);
    }
    {
        int f1 = open_f(F);
        long a = flock_ex(f1);
        long p = probe(F, P_POSIX);
        long g = probe(F, P_GETLK);
        do_flock(f1, L_UN);
        long b = posix_ex(f1);
        long q = probe(F, P_FLOCK);
        snprintf(msg, sizeof msg, "F: flock and fcntl locks do not block each other (%ld %ld %ld %ld)", a, p, b, q);
        check(a == 0 && p == 0 && b == 0 && q == 0, msg);
        snprintf(msg, sizeof msg, "G: F_GETLK does not report a flock (%ld, want %d)", g, -100 - T_UNLCK);
        check(g == -100 - T_UNLCK, msg);
        close(f1);
    }
    {
        int f1 = open_f(F);
        long a = flock_ex(f1);
        long c = fork();
        if (c == 0) _exit(0);
        int st;
        waitpid(c, &st, 0);
        long still = probe(F, P_FLOCK);
        close(f1);
        long gone = probe(F, P_FLOCK);
        snprintf(msg, sizeof msg, "H: a flock shared with a child survives its exit and goes with the last close (%ld %ld %ld)", a, still, gone);
        check(a == 0 && still == -11 && gone == 0, msg);
    }
    {
        int f1 = open_f(F);
        long a = range_lock(f1, C_SETLK, T_WRLCK, 0, 10, 0), b = range_lock(f1, C_SETLK, 0, 20, 10, 0);
        struct pr w = probe_range(C_GETLK, T_WRLCK, 0, 5), r = probe_range(C_GETLK, T_WRLCK, 20, 5);
        struct pr n = probe_range(C_GETLK, 0, 20, 5), first = probe_range(C_SETLK, T_WRLCK, 0, 10);
        long me = getpid();
        snprintf(msg, sizeof msg, "I: F_GETLK reports a write lock as F_WRLCK and a read lock as F_RDLCK with the holder's pid (%ld %ld; %ld/%ld %ld/%ld %ld/%ld)",
                 a, b, w.type, w.pid, r.type, r.pid, n.r, n.type);
        check(a == 0 && b == 0 && w.r == 0 && w.type == T_WRLCK && w.pid == me && r.r == 0 && r.type == 0 && r.pid == me &&
              n.r == 0 && n.type == T_UNLCK, msg);
        snprintf(msg, sizeof msg, "J: a second range lock by the same process keeps the first (%ld)", first.r);
        check(first.r == -11, msg);
        close(f1);
    }
    {
        int f1 = open_f(F);
        long a = range_lock(f1, C_SETLK, T_WRLCK, 0, 100, 0), u = range_lock(f1, C_SETLK, T_UNLCK, 40, 20, 0);
        struct pr mid = probe_range(C_SETLK, T_WRLCK, 45, 10), lo = probe_range(C_SETLK, T_WRLCK, 10, 10), hi = probe_range(C_SETLK, T_WRLCK, 70, 10);
        snprintf(msg, sizeof msg, "L: unlocking the middle of a range splits it (%ld %ld; %ld %ld %ld)", a, u, mid.r, lo.r, hi.r);
        check(a == 0 && u == 0 && mid.r == 0 && lo.r == -11 && hi.r == -11, msg);
        close(f1);
    }
    {
        int k1 = open_f(K1), k2 = open_f(K2);
        long a = flock_ex(k1), b = posix_ex(k1);
        long p = probe(K2, P_FLOCK), q = probe(K2, P_POSIX), s = probe(K1, P_FLOCK);
        snprintf(msg, sizeof msg, "K: two new empty files are locked independently (%ld %ld %ld %ld %ld)", a, b, p, q, s);
        check(k1 >= 0 && k2 >= 0 && a == 0 && b == 0 && p == 0 && q == 0 && s == -11, msg);
        close(k1);
        close(k2);
        unlink(K1);
        unlink(K2);
    }
    unlink(F);
    print(failures == 0 ? "hello310: PASS\n" : "hello310: FAIL\n");
    print("hello310 done\n");
    return 0;
}
