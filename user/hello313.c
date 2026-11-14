/* hello313: open file description locks (F_OFD_GETLK 36, F_OFD_SETLK 37, F_OFD_SETLKW 38) belong to the open file description,
 * not the process, and share the byte-range lock space with ordinary fcntl locks (Linux fs/locks.c FL_OFDLCK).
 * Measured on the host (build with -DHOST):
 *   A. two opens in one process: an OFD write lock through the first blocks one through the second (EAGAIN);
 *   B. it also blocks an ordinary F_SETLK of the same process through the second open, and the other way round;
 *   C. closing another descriptor of the file does not drop the OFD lock (an fcntl lock would go);
 *   D. a dup shares it (the dup can relock), and it goes with the last close of the description;
 *   E. F_OFD_GETLK and F_GETLK report an OFD lock held elsewhere with l_pid -1;
 *   F. a nonzero l_pid is EINVAL for F_OFD_SETLK and F_OFD_GETLK;
 *   G. F_OFD_SETLKW waits for a forked child's OFD lock on its own open and gets it once the child unlocks;
 *   H. a child that inherited the description through fork shares the lock; its exit does not drop it;
 *   I. unlocking the middle of an OFD range leaves both ends locked. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long do_fcntl(long fd, long cmd, void *p) { long r = syscall(SYS_fcntl, fd, cmd, p); return r < 0 ? -errno : r; }
static const char *F = "/tmp/h313a";
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
static long do_fcntl(long fd, long cmd, void *p) { return syscall3(142, fd, cmd, (long)p); }
static const char *F = "h313a.txt";
static long now_ms(void) { long ts[2] = { 0, 0 }; syscall2(SYS_clock_gettime, 1, (long)ts); return ts[0] * 1000 + ts[1] / 1000000; }
#endif

#define C_GETLK 5
#define C_SETLK 6
#define OFD_GETLK 36
#define OFD_SETLK 37
#define OFD_SETLKW 38
#define T_RDLCK 0
#define T_WRLCK 1
#define T_UNLCK 2

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello313:   ok   " : "hello313:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

/* x86_64 struct flock: l_type@0 l_whence@2 l_start@8 l_len@16 l_pid@24, 32 bytes. */
struct lk { unsigned char b[32]; };
static long lockp(int fd, int cmd, int type, long start, long len, int pid_in, int *out_type, int *out_pid) {
    struct lk l;
    memset(&l, 0, sizeof l);
    l.b[0] = (unsigned char)type;
    memcpy(l.b + 8, &start, 8);
    memcpy(l.b + 16, &len, 8);
    memcpy(l.b + 24, &pid_in, 4);
    long r = do_fcntl(fd, cmd, &l);
    if (out_type) *out_type = l.b[0];
    if (out_pid) memcpy(out_pid, l.b + 24, 4);
    return r;
}
static long lk(int fd, int cmd, int type, long start, long len) { return lockp(fd, cmd, type, start, len, 0, 0, 0); }
static int open_f(void) { return open(F, O_RDWR | O_CREAT, 0600); }

/* A separate process opens the file and tries one non-blocking lock on [start, start+len): 0 or the negative errno. */
static long probe(int cmd, long start, long len) {
    long c = fork();
    if (c == 0) {
        int fd = open_f();
        long r = lk(fd, cmd, T_WRLCK, start, len);
        _exit(r < 0 ? (int)-r : 0);
    }
    int st = 0;
    waitpid(c, &st, 0);
    return -(long)((st >> 8) & 0xff);
}
int main(void) {
    print("hello313: open file description (OFD) locks\n");
    int f1 = open_f(), f2 = open_f();
    long a1 = lk(f1, OFD_SETLK, T_WRLCK, 0, 10), a2 = lk(f2, OFD_SETLK, T_WRLCK, 0, 10);
    snprintf(msg, sizeof msg, "A: two opens in one process conflict on OFD locks (%ld %ld)", a1, a2);
    check(a1 == 0 && a2 == -11, msg);

    long b1 = lk(f2, C_SETLK, T_WRLCK, 0, 10);
    lk(f1, OFD_SETLK, T_UNLCK, 0, 10);
    long b2 = lk(f2, C_SETLK, T_WRLCK, 20, 5), b3 = lk(f1, OFD_SETLK, T_WRLCK, 20, 5);
    lk(f2, C_SETLK, T_UNLCK, 20, 5);
    snprintf(msg, sizeof msg, "B: an OFD lock and an fcntl lock of the same process conflict both ways (%ld %ld %ld)", b1, b2, b3);
    check(b1 == -11 && b2 == 0 && b3 == -11, msg);

    long c0 = lk(f1, OFD_SETLK, T_WRLCK, 0, 10);
    close(f2);
    long c1 = probe(C_SETLK, 0, 10);
    snprintf(msg, sizeof msg, "C: closing another descriptor of the file keeps the OFD lock (%ld, probe %ld)", c0, c1);
    check(c0 == 0 && c1 == -11, msg);

    int f3 = dup(f1);
    long d0 = lk(f3, OFD_SETLK, T_WRLCK, 0, 10);
    close(f1);
    long d1 = probe(C_SETLK, 0, 10);
    close(f3);
    long d2 = probe(C_SETLK, 0, 10);
    snprintf(msg, sizeof msg, "D: a dup shares the OFD lock, which goes with the last close (%ld %ld %ld)", d0, d1, d2);
    check(d0 == 0 && d1 == -11 && d2 == 0, msg);

    /* E/F: a child holds an OFD lock; the parent asks about it. */
    int up[2], down[2];
    pipe(up);
    pipe(down);
    long c = fork();
    if (c == 0) {
        int fd = open_f();
        long r = lk(fd, OFD_SETLK, T_WRLCK, 0, 10);
        write(up[1], &r, sizeof r);
        char x;
        read(down[0], &x, 1);
        lk(fd, OFD_SETLK, T_UNLCK, 0, 10);
        _exit(0);
    }
    long held = -1;
    read(up[0], &held, sizeof held);
    int fe = open_f();
    int t1 = -1, p1 = 0, t2 = -1, p2 = 0;
    long e1 = lockp(fe, OFD_GETLK, T_WRLCK, 0, 10, 0, &t1, &p1);
    long e2 = lockp(fe, C_GETLK, T_WRLCK, 0, 10, 0, &t2, &p2);
    snprintf(msg, sizeof msg, "E: F_OFD_GETLK and F_GETLK report the OFD lock with pid -1 (held %ld, %ld t%d p%d, %ld t%d p%d)", held, e1, t1,
             p1, e2, t2, p2);
    check(held == 0 && e1 == 0 && t1 == T_WRLCK && p1 == -1 && e2 == 0 && t2 == T_WRLCK && p2 == -1, msg);
    long g1 = lockp(fe, OFD_SETLK, T_WRLCK, 40, 1, 7, 0, 0), g2 = lockp(fe, OFD_GETLK, T_WRLCK, 40, 1, 7, 0, 0);
    snprintf(msg, sizeof msg, "F: a nonzero l_pid is EINVAL for F_OFD_SETLK and F_OFD_GETLK (%ld %ld)", g1, g2);
    check(g1 == -22 && g2 == -22, msg);

    /* G: F_OFD_SETLKW waits until the child unlocks. */
    long t0 = now_ms();
    long wc = fork();
    if (wc == 0) {
        struct timespec ts = { 0, 300000000L };
        nanosleep(&ts, 0);
        write(down[1], "x", 1);
        _exit(0);
    }
    long w = lk(fe, OFD_SETLKW, T_WRLCK, 0, 10);
    long waited = now_ms() - t0;
    snprintf(msg, sizeof msg, "G: F_OFD_SETLKW waits for the holder and then gets the lock (%ld after %ld ms)", w, waited);
    check(w == 0 && waited >= 200, msg);
    int st;
    waitpid(wc, &st, 0);
    waitpid(c, &st, 0);
    lk(fe, OFD_SETLK, T_UNLCK, 0, 0);

    /* H: a forked child shares the parent's description, so it shares the lock; its exit keeps it. */
    lk(fe, OFD_SETLK, T_WRLCK, 0, 10);
    long hc = fork();
    if (hc == 0) {
        long r = lk(fe, OFD_SETLK, T_WRLCK, 0, 10);
        _exit(r < 0 ? (int)-r : 0);
    }
    waitpid(hc, &st, 0);
    long h0 = -(long)((st >> 8) & 0xff);
    long h1 = probe(C_SETLK, 0, 10);
    snprintf(msg, sizeof msg, "H: a forked child shares the OFD lock and its exit keeps it (child %ld, probe %ld)", h0, h1);
    check(h0 == 0 && h1 == -11, msg);

    /* I: unlock the middle of [0,10). */
    lk(fe, OFD_SETLK, T_UNLCK, 3, 4);
    long i0 = probe(C_SETLK, 0, 3), i1 = probe(C_SETLK, 3, 4), i2 = probe(C_SETLK, 7, 3);
    snprintf(msg, sizeof msg, "I: unlocking the middle of an OFD range keeps both ends (%ld %ld %ld)", i0, i1, i2);
    check(i0 == -11 && i1 == 0 && i2 == -11, msg);
    close(fe);
    close(up[0]);
    close(up[1]);
    close(down[0]);
    close(down[1]);
    unlink(F);
    print(failures == 0 ? "hello313: PASS\n" : "hello313: FAIL\n");
    return failures;
}
