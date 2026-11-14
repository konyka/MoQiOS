/* hello311: F_SETLKW reports EDEADLK instead of waiting forever when the wait would close a cycle of fcntl lock owners.
 * Measured on the host (build with -DHOST):
 *   A. two processes each hold one byte and wait for the other's: the second to ask gets EDEADLK at once, the first gets its
 *      lock once the second gives up;
 *   B. a wait on a holder that is not itself waiting is no deadlock: it blocks until the holder unlocks and returns 0;
 *   C. a cycle through three processes is found too (P waits for C1, C1 for C2, C2 asks for P's byte: EDEADLK). */
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
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
static long do_fcntl(long fd, long cmd, void *p) { return syscall3(142, fd, cmd, (long)p); }
#endif

#define C_SETLK 6
#define C_SETLKW 7
#define T_WRLCK 1
#define T_UNLCK 2
#define EDEADLK_ 35

static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello311:   ok   " : "hello311:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* x86_64 struct flock: l_type@0 l_whence@2 l_start@8 l_len@16 l_pid@24, 32 bytes. */
struct lk { unsigned char b[32]; };
static long byte_lock(int fd, int cmd, int type, long at) {
    struct lk l;
    memset(&l, 0, sizeof l);
    l.b[0] = (unsigned char)type;
    long one = 1;
    memcpy(l.b + 8, &at, 8);
    memcpy(l.b + 16, &one, 8);
    return do_fcntl(fd, cmd, &l);
}

static const char *F = "/tmp/h311a";
static int open_f(void) { return open(F, O_RDWR | O_CREAT, 0600); }
static void reap(long c) { int st; waitpid(c, &st, 0); }

int main(void) {
    {
        int rp[2];
        pipe(rp);
        int fd = open_f();
        long a = byte_lock(fd, C_SETLK, T_WRLCK, 0);
        long c = fork();
        if (c == 0) {
            int f = open_f();
            long b = byte_lock(f, C_SETLK, T_WRLCK, 1);
            nap(400); /* the parent is asleep in F_SETLKW on byte 1 by now */
            long r = byte_lock(f, C_SETLKW, T_WRLCK, 0);
            long out[2] = { b, r };
            write(rp[1], out, sizeof out);
            _exit(0); /* drops byte 1: the parent's wait ends */
        }
        nap(100);
        long t0 = now_ms();
        long w = byte_lock(fd, C_SETLKW, T_WRLCK, 1);
        long waited = now_ms() - t0;
        long out[2] = { -999, -999 };
        read(rp[0], out, sizeof out);
        reap(c);
        snprintf(msg, sizeof msg, "A: the second of two crossed F_SETLKW gets EDEADLK (%ld %ld %ld)", a, out[0], out[1]);
        check(a == 0 && out[0] == 0 && out[1] == -EDEADLK_, msg);
        snprintf(msg, sizeof msg, "A: the first gets its lock once the other gives up (%ld after %ld ms)", w, waited);
        check(w == 0 && waited >= 150, msg);
        close(fd);
        close(rp[0]);
        close(rp[1]);
    }
    {
        int fd = open_f();
        long a = byte_lock(fd, C_SETLK, T_WRLCK, 0);
        int rp[2];
        pipe(rp);
        long c = fork();
        if (c == 0) {
            int f = open_f();
            long t0 = now_ms();
            long r = byte_lock(f, C_SETLKW, T_WRLCK, 0);
            long out[2] = { r, now_ms() - t0 };
            write(rp[1], out, sizeof out);
            _exit(0);
        }
        nap(300);
        byte_lock(fd, C_SETLK, T_UNLCK, 0);
        long out[2] = { -999, -999 };
        read(rp[0], out, sizeof out);
        reap(c);
        snprintf(msg, sizeof msg, "B: waiting for a holder that is not waiting is no deadlock (%ld %ld after %ld ms)", a, out[0], out[1]);
        check(a == 0 && out[0] == 0 && out[1] >= 150, msg);
        close(fd);
        close(rp[0]);
        close(rp[1]);
    }
    {
        int fd = open_f();
        long a = byte_lock(fd, C_SETLK, T_WRLCK, 0);
        int go[2], rp[2];
        pipe(go);
        pipe(rp);
        long c1 = fork();
        if (c1 == 0) {
            int f = open_f();
            byte_lock(f, C_SETLK, T_WRLCK, 1);
            char x;
            read(go[0], &x, 1);
            byte_lock(f, C_SETLKW, T_WRLCK, 2); /* waits for C2 */
            _exit(0);
        }
        long c2 = fork();
        if (c2 == 0) {
            int f = open_f();
            byte_lock(f, C_SETLK, T_WRLCK, 2);
            nap(600); /* C1 waits for byte 2 and P for byte 1 by now */
            long r = byte_lock(f, C_SETLKW, T_WRLCK, 0);
            write(rp[1], &r, sizeof r);
            _exit(0);
        }
        nap(150);
        write(go[1], "g", 1);
        nap(100);
        long w = byte_lock(fd, C_SETLKW, T_WRLCK, 1); /* waits for C1 */
        long r = -999;
        read(rp[0], &r, sizeof r);
        reap(c1);
        reap(c2);
        snprintf(msg, sizeof msg, "C: a cycle through three processes is EDEADLK (%ld %ld %ld)", a, r, w);
        check(a == 0 && r == -EDEADLK_ && w == 0, msg);
        close(fd);
    }
    unlink(F);
    print(failures == 0 ? "hello311: PASS\n" : "hello311: FAIL\n");
    print("hello311 done\n");
    return 0;
}
