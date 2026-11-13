/* hello290: flock and fcntl F_SETLKW block until the holder lets go, and a lock goes away with its holder.
 * Measured on the host (build with -DHOST): a blocked flock(LOCK_EX) and a blocked F_SETLKW both return 0 once a child that
 * held the lock for 300 ms drops it, and the waiting process uses almost no CPU time meanwhile (it sleeps). A child's flock
 * is gone once it exits without LOCK_UN, a child's fcntl lock is gone once it closes the descriptor (it is still alive) and
 * once it is killed by SIGKILL. Locks on two different /tmp files do not conflict. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long do_flock(long fd, long op) { long r = syscall(SYS_flock, fd, op); return r < 0 ? -errno : r; }
static long do_fcntl(long fd, long cmd, void *p) { long r = syscall(SYS_fcntl, fd, cmd, p); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
static long do_flock(long fd, long op) { return syscall2(185, fd, op); }
static long do_fcntl(long fd, long cmd, void *p) { return syscall3(142, fd, cmd, (long)p); }
#endif

#define L_SH 1
#define L_EX 2
#define L_NB 4
#define L_UN 8
#define C_SETLK 6
#define C_SETLKW 7
#define T_WRLCK 1
#define CPU_CLOCK 2

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello290:   ok   " : "hello290:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long ms_of(int clock) {
    struct timespec t;
    clock_gettime(clock, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* x86_64 struct flock: l_type@0 l_whence@2 l_start@8 l_len@16 l_pid@24, 32 bytes. */
struct lk { unsigned char b[32]; };
static long posix_lock(int fd, int cmd, int type) {
    struct lk l;
    memset(&l, 0, sizeof l);
    l.b[0] = (unsigned char)type;
    return do_fcntl(fd, cmd, &l);
}
static long lock_ex(int fd, int posix, int blocking) {
    if (posix) return posix_lock(fd, blocking ? C_SETLKW : C_SETLK, T_WRLCK);
    return do_flock(fd, blocking ? L_EX : (L_EX | L_NB));
}

static const char *F = "/tmp/h290a";
static const char *G = "/tmp/h290b";
static int sp[2];
static void ready(void) { write(sp[1], "r", 1); }
static void await_child(void) { char x; read(sp[0], &x, 1); }
static void reap(long c) { int st; waitpid(c, &st, 0); }
static int open_f(const char *p) { return open(p, O_RDWR | O_CREAT, 0600); }

/* A/B: the child takes the lock on its own open of F, holds it 300 ms and unlocks; the parent's blocking call waits it out asleep. */
static void blocked_wait(int posix, const char *name) {
    long c = fork();
    if (c == 0) {
        int f = open_f(F);
        lock_ex(f, posix, 0);
        ready();
        nap(300);
        /* Tell the parent when the lock goes away: its call must not return before this. */
        long unlock_at = ms_of(CLOCK_MONOTONIC);
        write(sp[1], &unlock_at, sizeof unlock_at);
        if (posix) posix_lock(f, C_SETLK, 2);
        else do_flock(f, L_UN);
        nap(100);
        _exit(0);
    }
    await_child();
    int fd = open_f(F);
    long busy = lock_ex(fd, posix, 0);
    long t0 = ms_of(CLOCK_MONOTONIC), c0 = ms_of(CPU_CLOCK);
    long r = lock_ex(fd, posix, 1);
    long done_at = ms_of(CLOCK_MONOTONIC);
    long waited = done_at - t0, cpu = ms_of(CPU_CLOCK) - c0;
    long unlock_at = 0;
    read(sp[0], &unlock_at, sizeof unlock_at);
    /* The bound is the holder's unlock time, not a fixed 200 ms: under load the parent can start waiting late. */
    snprintf(msg, sizeof msg, "%s: a blocked lock returns 0 once the holder unlocks, asleep (busy %ld, r %ld, waited %ld ms, %ld ms after the unlock, cpu %ld ms)",
             name, busy, r, waited, done_at - unlock_at, cpu);
    check(busy == -11 && r == 0 && unlock_at > 0 && done_at >= unlock_at && cpu < 100, msg);
    close(fd);
    reap(c);
}

/* C/D/E: the child takes the lock and then exits, closes its descriptor or is killed; the lock must be gone. */
static void lock_goes_away(int posix, int how, const char *name) {
    long c = fork();
    if (c == 0) {
        int f = open_f(F);
        lock_ex(f, posix, 0);
        if (how == 0) { ready(); _exit(0); }
        if (how == 1) close(f);
        ready();
        for (;;) nap(1000);
    }
    await_child();
    if (how == 0) reap(c);
    if (how == 2) { kill(c, SIGKILL); reap(c); }
    int fd = open_f(F);
    long r = lock_ex(fd, posix, 0);
    snprintf(msg, sizeof msg, "%s (%ld)", name, r);
    check(r == 0, msg);
    if (posix) posix_lock(fd, C_SETLK, 2);
    else do_flock(fd, L_UN);
    close(fd);
    if (how == 1) { kill(c, SIGKILL); reap(c); }
}

int main(void) {
    pipe(sp);
    blocked_wait(0, "A: flock(LOCK_EX)");
    blocked_wait(1, "B: fcntl(F_SETLKW)");
    lock_goes_away(0, 0, "C: a flock is released when its holder exits without LOCK_UN");
    lock_goes_away(1, 1, "D: an fcntl lock is released when its holder closes the descriptor");
    lock_goes_away(1, 2, "E: an fcntl lock is released when its holder is killed");

    /* F: locks on two different /tmp files are independent. */
    long c = fork();
    if (c == 0) {
        int f = open_f(F);
        lock_ex(f, 0, 0);
        lock_ex(f, 1, 0);
        ready();
        for (;;) nap(1000);
    }
    await_child();
    int g = open_f(G);
    long r1 = lock_ex(g, 0, 0), r2 = lock_ex(g, 1, 0);
    int f = open_f(F);
    long r3 = lock_ex(f, 0, 0), r4 = lock_ex(f, 1, 0);
    snprintf(msg, sizeof msg, "F: a lock on %s does not block %s, but still blocks %s (%ld %ld %ld %ld)", F, G, F, r1, r2, r3, r4);
    check(r1 == 0 && r2 == 0 && r3 == -11 && r4 == -11, msg);
    kill(c, SIGKILL);
    reap(c);
    close(f);
    close(g);
    unlink(F);
    unlink(G);

    print(failures == 0 ? "hello290: PASS\n" : "hello290: FAIL\n");
    print("hello290 done\n");
    return 0;
}
