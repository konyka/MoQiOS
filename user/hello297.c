/* hello297: splice waiting on an empty pipe reacts to signals, and pipe-to-pipe splice waits for input.
 * Measured on the host (build with -DHOST): A a handler installed without SA_RESTART ends a splice blocked on an empty pipe with
 * EINTR; B with SA_RESTART the splice runs again and returns the bytes written afterwards; C SIGSTOP stops the blocked process at
 * once (waitpid reports 0x137f), SIGCONT resumes it and the splice still gets its data; D SIGKILL kills it (status 9). E a
 * pipe-to-pipe splice from an empty pipe blocks and a handler ends it with EINTR; F with SPLICE_F_NONBLOCK it is EAGAIN; G it
 * returns the bytes once they arrive; H with the write end closed it returns 0. */
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
static long spl(long in, long out, long len, long flags) {
    long r = syscall(SYS_splice, in, 0, out, 0, len, flags);
    return r < 0 ? -errno : r;
}
static volatile int hits;
static void h(int s) { (void)s; hits++; }
static void inst(int restart) {
    struct sigaction a;
    memset(&a, 0, sizeof a);
    a.sa_handler = h;
    a.sa_flags = restart ? SA_RESTART : 0;
    sigaction(SIGUSR1, &a, 0);
}
static long wpid(long c, int *st, int opt) { long r = waitpid(c, st, opt); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
static long spl(long in, long out, long len, long flags) { return syscall6(145, in, 0, out, 0, len, flags); }
static volatile int hits;
static void h(int s) { (void)s; hits++; }
static void inst(int restart) {
    struct ksigaction a = { h, restart ? 0x10000000UL : 0, (void *)0, 0 };
    sigaction(10, &a, (struct ksigaction *)0);
}
static long wpid(long c, int *st, int opt) { return waitpid(c, st, opt); }
#endif

/* The file end of A-D: ext2 on the target (splice into a tmpfs file is not supported there yet), /tmp on the host. */
#ifdef HOST
#define FILE_PATH "/tmp/h297"
#else
#define FILE_PATH "testdir/h297"
#endif
#define S_USR1 10
#define S_KILL 9
#define S_STOP 19
#define S_CONT 18
#define O_WNOHANG 1
#define O_WUNTRACED 2
#define O_WCONTINUED 8
#define F_NONBLOCK 2

static int failures;
static char what[200];
static void check(int ok, const char *w) {
    print(ok ? "hello297:   ok   " : "hello297:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
/* Wait up to `ms` for c to report a change matching opt; 0 when it did not. */
static long waitFor(long c, int *st, int opt, int ms) {
    for (int i = 0; i < ms / 10; i++) {
        long r = wpid(c, st, opt | O_WNOHANG);
        if (r != 0) return r;
        nap(10);
    }
    return 0;
}
/* Reap c whatever state the kernel left it in. */
static int reap(long c, int fd_unblock) {
    int st = 0;
    if (waitFor(c, &st, 0, 2000) == c) return st;
    if (fd_unblock >= 0) write(fd_unblock, "zzzzzzzzzzzzzzzz", 16);
    if (waitFor(c, &st, 0, 1000) == c) return 0x7f00;
    kill(c, S_KILL);
    wpid(c, &st, 0);
    return 0x7e00;
}
static void drain(int fd) {
    char b[64];
    int fl = (int)fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    while (read(fd, b, sizeof b) > 0) {}
    fcntl(fd, F_SETFL, fl);
}

int main(void) {
    print("hello297: splice waits react to signals\n");
    int p[2], q[2];
    if (pipe(p) != 0 || pipe(q) != 0) {
        print("hello297: FAIL (pipe)\n");
        return 1;
    }
    int f = (int)open(FILE_PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
    int st = 0;

    /* A: a handler without SA_RESTART ends the wait with EINTR. */
    long c = fork();
    if (c == 0) {
        inst(0);
        long r = spl(p[0], f, 16, 0);
        _exit(r == -4 && hits == 1 ? 0 : (r == -4 ? 2 : 1));
    }
    nap(100);
    kill(c, S_USR1);
    st = reap(c, p[1]);
    drain(p[0]);
    snprintf(what, sizeof what, "A: a handler ends a pipe-to-file splice on an empty pipe with EINTR (status 0x%x)", st);
    check(st == 0, what);

    /* B: SA_RESTART runs the splice again; it returns the bytes written later. */
    c = fork();
    if (c == 0) {
        inst(1);
        long r = spl(p[0], f, 16, 0);
        _exit(r == 3 && hits == 1 ? 0 : 1);
    }
    nap(100);
    kill(c, S_USR1);
    nap(100);
    write(p[1], "abc", 3);
    st = reap(c, -1);
    drain(p[0]);
    snprintf(what, sizeof what, "B: with SA_RESTART the splice restarts and returns 3 bytes (status 0x%x)", st);
    check(st == 0, what);

    /* C: SIGSTOP stops the blocked process, SIGCONT resumes it, the splice still gets its data. */
    c = fork();
    if (c == 0) {
        long r = spl(p[0], f, 16, 0);
        _exit(r == 2 ? 0 : 1);
    }
    nap(100);
    kill(c, S_STOP);
    int sst = 0, cst = 0;
    long ws = waitFor(c, &sst, O_WUNTRACED, 1000);
    kill(c, S_CONT);
    long wc = waitFor(c, &cst, O_WCONTINUED, 1000);
    nap(50);
    write(p[1], "de", 2);
    st = reap(c, p[1]);
    drain(p[0]);
    snprintf(what, sizeof what, "C: SIGSTOP stops a blocked splice (0x%x, %s), SIGCONT resumes (0x%x, %s), it returns 2 (status 0x%x)",
             sst, ws == c ? "seen" : "not seen", cst, wc == c ? "seen" : "not seen", st);
    check(ws == c && sst == 0x137f && wc == c && cst == 0xffff && st == 0, what);

    /* D: SIGKILL kills it. */
    c = fork();
    if (c == 0) {
        spl(p[0], f, 16, 0);
        _exit(1);
    }
    nap(100);
    kill(c, S_KILL);
    st = 0;
    long wk = waitFor(c, &st, 0, 2000);
    if (wk != c) st = reap(c, p[1]);
    drain(p[0]);
    snprintf(what, sizeof what, "D: SIGKILL kills a blocked splice (status 0x%x)", st);
    check(wk == c && (st & 0x7f) == S_KILL, what);

    /* E: pipe-to-pipe from an empty pipe blocks; a handler ends it with EINTR. */
    c = fork();
    if (c == 0) {
        inst(0);
        long r = spl(p[0], q[1], 16, 0);
        _exit(r == -4 ? 0 : (r == -11 ? 3 : 1));
    }
    nap(100);
    long still = wpid(c, &st, O_WNOHANG);
    kill(c, S_USR1);
    st = reap(c, p[1]);
    drain(p[0]);
    drain(q[0]);
    snprintf(what, sizeof what, "E: a pipe-to-pipe splice from an empty pipe waits (%s) and a handler ends it with EINTR (status 0x%x)",
             still == 0 ? "waiting" : "returned", st);
    check(still == 0 && st == 0, what);

    /* F: SPLICE_F_NONBLOCK on an empty pipe is EAGAIN. */
    long r = spl(p[0], q[1], 16, F_NONBLOCK);
    snprintf(what, sizeof what, "F: SPLICE_F_NONBLOCK pipe-to-pipe on an empty pipe is EAGAIN (%ld)", r);
    check(r == -11, what);

    /* G: the pipe-to-pipe splice returns the bytes once they arrive. */
    c = fork();
    if (c == 0) {
        long r2 = spl(p[0], q[1], 16, 0);
        _exit(r2 == 4 ? 0 : 1);
    }
    nap(100);
    write(p[1], "wxyz", 4);
    st = reap(c, -1);
    char got[8] = { 0 };
    int qfl = (int)fcntl(q[0], F_GETFL, 0);
    fcntl(q[0], F_SETFL, qfl | O_NONBLOCK);
    long gn = read(q[0], got, sizeof got);
    fcntl(q[0], F_SETFL, qfl);
    snprintf(what, sizeof what, "G: a waiting pipe-to-pipe splice returns the 4 bytes written later (status 0x%x, read %ld \"%s\")", st, gn, got);
    check(st == 0 && gn == 4 && memcmp(got, "wxyz", 4) == 0, what);

    /* H: with the write end closed, an empty pipe gives 0. */
    close(p[1]);
    r = spl(p[0], q[1], 16, 0);
    snprintf(what, sizeof what, "H: pipe-to-pipe splice from an empty pipe whose writers are gone returns 0 (%ld)", r);
    check(r == 0, what);

    close(p[0]);
    close(q[0]);
    close(q[1]);
    close(f);
    unlink(FILE_PATH);
    print(failures == 0 ? "hello297: PASS\n" : "hello297: FAIL\n");
    return failures;
}
