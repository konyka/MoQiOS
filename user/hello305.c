/* hello305: a blocking read of /dev/mouse with no motion waits for an event instead of returning 0. MoQiOS-specific device; the rules
 * follow Linux's /dev/input/mice and the psaux driver: a blocking read with nothing queued sleeps until data arrives, a signal ends
 * the sleep (EINTR without SA_RESTART, the handler runs), O_NONBLOCK gives EAGAIN, and the sleeping reader uses no CPU.
 * A: O_NONBLOCK with nothing queued is EAGAIN; B: a blocking read is still waiting after 300 ms (it neither returned 0 nor spun:
 * the child's CPU time over the wait stays under 50 ms); C: SIGUSR1 without SA_RESTART ends it with EINTR after the handler ran;
 * D: SIGKILL ends a blocked reader at once (status 9); E: SIGSTOP stops a blocked reader (0x137f) and SIGCONT puts it back (0xffff). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"

#define S_KILL 9
#define S_USR1 10
#define S_STOP 19
#define S_CONT 18
#define O_WNOHANG 1
#define O_WUNTRACED 2
#define O_WCONTINUED 8

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello305:   ok   " : "hello305:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long reap_within(long c, int *st, int opt, int ms) {
    for (int i = 0; i < ms / 5; i++) {
        long r = waitpid(c, st, opt | O_WNOHANG);
        if (r != 0) return r;
        nap(5);
    }
    return 0;
}
static volatile int hits;
static void on_usr1(int s) { (void)s; hits++; }
/* CPU time of the calling process in ms (CLOCK_PROCESS_CPUTIME_ID). */
static long cpu_ms(void) {
    long t[2] = { 0, 0 };
    syscall2(SYS_clock_gettime, 2, (long)t);
    return t[0] * 1000 + t[1] / 1000000;
}

int main(void) {
    print("hello305: a blocking /dev/mouse read waits for an event\n");
    int fd = (int)open("/dev/mouse", O_RDONLY | O_NONBLOCK, 0);
    if (fd < 0) {
        print("hello305: no /dev/mouse, nothing to test\n");
        print("hello305: PASS\n");
        return 0;
    }
    char b[16];
    /* Drain anything the boot left queued so the device is empty. */
    while (read(fd, b, sizeof b) > 0) {}
    long r = read(fd, b, sizeof b);
    snprintf(what, sizeof what, "A: O_NONBLOCK with nothing queued is EAGAIN (%ld)", r);
    check(r == -11, what);
    close(fd);

    /* B and C: the child reads without O_NONBLOCK and reports what read returned, its CPU time and the handler count on a pipe. */
    int rp[2];
    pipe(rp);
    long c = fork();
    if (c == 0) {
        struct ksigaction a = { on_usr1, 0, (void *)0, 0 };
        sigaction(S_USR1, &a, (struct ksigaction *)0);
        int mfd = (int)open("/dev/mouse", O_RDONLY, 0);
        long c0 = cpu_ms();
        char mb[16];
        long rr = read(mfd, mb, sizeof mb);
        long out[3] = { rr, cpu_ms() - c0, hits };
        write(rp[1], out, sizeof out);
        _exit(0);
    }
    nap(300);
    int st = 0;
    long early = waitpid(c, &st, O_WNOHANG);
    kill(c, S_USR1);
    long out[3] = { 0, 0, 0 };
    long got = read(rp[0], out, sizeof out);
    reap_within(c, &st, 0, 2000);
    snprintf(what, sizeof what, "B: a blocking read with no motion is still waiting after 300 ms (%s) and used %ld ms of CPU", early == 0 ? "yes" : "no",
             out[1]);
    check(early == 0 && got == (long)sizeof out && out[1] < 50, what);
    snprintf(what, sizeof what, "C: SIGUSR1 without SA_RESTART ends the read with EINTR after the handler ran (read %ld, handler %ld)", out[0], out[2]);
    check(got == (long)sizeof out && out[0] == -4 && out[2] == 1, what);

    /* D: SIGKILL ends a blocked reader at once. */
    c = fork();
    if (c == 0) {
        int mfd = (int)open("/dev/mouse", O_RDONLY, 0);
        char mb[16];
        read(mfd, mb, sizeof mb);
        _exit(1);
    }
    nap(100);
    early = waitpid(c, &st, O_WNOHANG);
    kill(c, S_KILL);
    long reaped = reap_within(c, &st, 0, 2000);
    snprintf(what, sizeof what, "D: SIGKILL ends a blocked reader (was waiting %s, reaped %s, status 0x%x)", early == 0 ? "yes" : "no",
             reaped == c ? "yes" : "no", st);
    check(early == 0 && reaped == c && (st & 0x7f) == S_KILL, what);

    /* E: SIGSTOP and SIGCONT on a blocked reader. */
    c = fork();
    if (c == 0) {
        int mfd = (int)open("/dev/mouse", O_RDONLY, 0);
        char mb[16];
        for (;;) read(mfd, mb, sizeof mb);
    }
    nap(100);
    kill(c, S_STOP);
    int sst = 0, cst = 0;
    long ws = reap_within(c, &sst, O_WUNTRACED, 3000);
    kill(c, S_CONT);
    long wc = reap_within(c, &cst, O_WCONTINUED, 3000);
    kill(c, S_KILL);
    reap_within(c, &st, 0, 2000);
    snprintf(what, sizeof what, "E: SIGSTOP stops a blocked reader (0x%x) and SIGCONT continues it (0x%x)", ws == c ? sst : 0, wc == c ? cst : 0);
    check(ws == c && sst == 0x137f && wc == c && cst == 0xffff, what);

    print(failures == 0 ? "hello305: PASS\n" : "hello305: FAIL\n");
    return failures;
}
