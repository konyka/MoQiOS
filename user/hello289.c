/* hello289: under the Linux personality, syscall 231 is exit_group and 247 is waitid; the native numbers stay put.
 * Measured on the host (build with -DHOST): personality(1) makes 231 end every thread of the process (a spinning thread writes
 * nothing afterwards, the reported status keeps the low 8 bits) and 247 fills a SIGCHLD siginfo; personality(0) makes 231 the
 * native move_pages (it returns 0 for the status-only shape and does not end the process) and 247 clock_nanosleep (a short sleep
 * returns 0 and consumes the time). On the host only C and D run: Linux has no personality that renumbers its calls. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long call1(long nr, long a) { long r = syscall(nr, a); return r < 0 ? -errno : r; }
static long call5(long nr, long a, long b, long c, long d, long e) {
    long r = syscall(nr, a, b, c, d, e);
    return r < 0 ? -errno : r;
}
/* Linux's numbers are always Linux's: there is no personality to switch. */
static void set_linux(void) {}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/pthread.h"
static long call1(long nr, long a) { return syscall1(nr, a); }
static long call5(long nr, long a, long b, long c, long d, long e) { return syscall5(nr, a, b, c, d, e); }
static void set_linux(void) { syscall1(268, 1); }
#endif

#ifndef WNOHANG
#define WNOHANG 1
#endif
#ifndef P_PID
#define P_PID 1
#endif
#ifndef WEXITED
#define WEXITED 4
#endif

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello289:   ok   " : "hello289:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

static int bp[2];
static int drain(void) {
    char b[256];
    int any = 0;
    while (read(bp[0], b, sizeof b) > 0) any = 1;
    return any;
}
static int wait_writes(void) {
    for (int i = 0; i < 300; i++) {
        if (drain()) return 1;
        nap(10);
    }
    return 0;
}
static long wait_for(long c, int *st) {
    for (int i = 0; i < 300; i++) {
        long r = waitpid(c, st, WNOHANG);
        if (r != 0) return r;
        nap(10);
    }
    return 0;
}

/* si_signo@0 si_code@8 si_pid@16 si_status@24, little endian, in the kernel's 128-byte siginfo. */
struct winfo { unsigned char b[128]; };
static int rd32(const struct winfo *w, int off) {
    return (int)((unsigned)w->b[off] | ((unsigned)w->b[off + 1] << 8) | ((unsigned)w->b[off + 2] << 16) | ((unsigned)w->b[off + 3] << 24));
}
static void *spin(void *a) {
    (void)a;
    for (;;) {
        write(bp[1], "t", 1);
        nap(1);
    }
    return (void *)0;
}

int main(void) {
    pipe2(bp, O_NONBLOCK);

#ifndef HOST
    long r;
    /* A: native 231 is move_pages. The status-only shape (count 0, null pointers) succeeds and the caller keeps running. */
    r = call5(231, 0, 0, 0, 0, 0);
    snprintf(msg, sizeof msg, "A: native syscall 231 (move_pages) returns 0 for the status-only shape (%ld)", r);
    check(r == 0, msg);

    /* B: native 247 is clock_nanosleep. A 20 ms sleep returns 0 and takes at least that long. */
    struct timespec req = { 0, 20000000L }, before, after;
    clock_gettime(CLOCK_MONOTONIC, &before);
    r = call5(247, 1, 0, (long)&req, 0, 0);
    clock_gettime(CLOCK_MONOTONIC, &after);
    long elapsed = (after.tv_sec - before.tv_sec) * 1000 + (after.tv_nsec - before.tv_nsec) / 1000000;
    snprintf(msg, sizeof msg, "B: native syscall 247 (clock_nanosleep) sleeps (%ld, %ld ms)", r, elapsed);
    check(r == 0 && elapsed >= 15, msg);

#endif
    /* C: under the Linux personality, 231 ends every thread and the parent is told the low 8 bits of the status. */
    long c = fork();
    if (c == 0) {
        set_linux();
        pthread_t th;
        pthread_create(&th, (void *)0, spin, (void *)0);
        nap(50);
        call1(231, 300);
        for (;;) write(bp[1], "x", 1);
    }
    int started = wait_writes();
    int st = 0;
    long w = wait_for(c, &st);
    drain();
    nap(200);
    int quiet = !drain();
    snprintf(msg, sizeof msg, "C: Linux personality syscall 231 is exit_group: the child ends as 0x2c00 and its thread writes nothing (%ld, 0x%x, %d, %d)",
             w == c ? 1L : w, st, started, quiet);
    check(started && w == c && st == 0x2c00 && quiet, msg);
    if (w != c) {
        kill(c, 9);
        waitpid(c, &st, 0);
    }

    /* D: under the Linux personality, 247 is waitid and fills a SIGCHLD siginfo. */
    c = fork();
    if (c == 0) {
        set_linux();
        long g = fork();
        if (g == 0) _exit(7);
        struct winfo info;
        memset(&info, 0xAA, sizeof info);
        long wr = call5(247, P_PID, g, (long)&info, WEXITED, 0);
        int code = rd32(&info, 8), pid = rd32(&info, 16), status = rd32(&info, 24);
        int ok = wr == 0 && code == 1 && pid == (int)g && status == 7;
        _exit(ok ? 0 : 1);
    }
    st = 0;
    w = wait_for(c, &st);
    snprintf(msg, sizeof msg, "D: Linux personality syscall 247 is waitid: it reports the child with CLD_EXITED (%ld, 0x%x)", w == c ? 1L : w, st);
    check(w == c && st == 0, msg);
    if (w != c) {
        kill(c, 9);
        waitpid(c, &st, 0);
    }

    print(failures == 0 ? "hello289: PASS\n" : "hello289: FAIL\n");
    return failures;
}
