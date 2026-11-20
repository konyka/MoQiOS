/* hello460: pidfd flags, PIDFD_SELF_*, readiness and waitid(P_PIDFD) (Linux kernel/pid.c pidfd_open, kernel/signal.c
 * sys_pidfd_send_signal, fs/pidfs.c pidfd_poll, kernel/exit.c kernel_waitid / pidfd_get_pid). Measured on the host (build with -DHOST):
 *   A. pidfd_open(self, PIDFD_NONBLOCK) and (self, PIDFD_THREAD) succeed; F_GETFL reads 0x802 and 0x82 (O_RDWR is set as for every
 *      pidfd: 0x2); flag 2 or O_CLOEXEC is EINVAL;
 *   B. pidfd_send_signal(PIDFD_SELF_THREAD = -10000) and (PIDFD_SELF_THREAD_GROUP = -10001) deliver SIGUSR1 to the caller; -10002 is
 *      EBADF;
 *   C. a pidfd of a running child polls 0 (no POLLIN); once the child exits, poll gives POLLIN; waitid(P_PIDFD) reaps it with its
 *      pid and status 3; a second waitid is ECHILD; then poll gives POLLIN|POLLHUP (0x11);
 *   D. waitid(P_PIDFD) on a descriptor that is not a pidfd is EBADF; on the caller's own pidfd ECHILD;
 *   E. on a PIDFD_NONBLOCK pidfd of a running child, waitid(P_PIDFD, WEXITED) is EAGAIN; after the child exits it reaps;
 *   F. pidfd_getfd copies a child's pipe read end into the caller, close-on-exec (F_GETFD 1), and reading it gets what the child
 *      wrote; flags 1 is EINVAL, a closed target fd (100) EBADF, a descriptor that is not a pidfd EBADF; the caller's own pidfd
 *      works; once the child is reaped it is ESRCH. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long pidfd_open_(long pid, long fl) { return rc(syscall(SYS_pidfd_open, pid, fl)); }
static long pidfd_send_(long fd, int sig) { return rc(syscall(SYS_pidfd_send_signal, fd, sig, 0, 0)); }
static long getfl(long fd) { return rc(fcntl((int)fd, F_GETFL)); }
static long poll1(long fd, int ms, int *rev) { struct pollfd p = { (int)fd, POLLIN, 0 }; long r = rc(poll(&p, 1, ms)); *rev = p.revents; return r; }
static long waitid_(int type, long id, void *si, int opt) { return rc(syscall(SYS_waitid, type, id, si, opt, 0)); }
static long fork_(void) { return rc(fork()); }
static void exit_(int c) { _exit(c); }
static void nap(int ms) { usleep(ms * 1000); }
static long getpid_(void) { return getpid(); }
static long open_(const char *p) { return rc(open(p, 0)); }
static long sigact(int sig, void (*h)(int)) { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = h; return rc(sigaction(sig, &sa, 0)); }
static long getfd_(long pfd, long fd, long fl) { return rc(syscall(SYS_pidfd_getfd, pfd, fd, fl)); }
static long pipe_(int *p) { return rc(pipe(p)); }
static long read_(long fd, void *b, long n) { return rc(read((int)fd, b, (size_t)n)); }
static long write_(long fd, const void *b, long n) { return rc(write((int)fd, b, (size_t)n)); }
static long getfdflags(long fd) { return rc(fcntl((int)fd, F_GETFD)); }
static long waitpid_(long p) { return rc(waitpid((pid_t)p, 0, 0)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
static long pidfd_open_(long pid, long fl) { return syscall2(434, pid, fl); }
static long pidfd_send_(long fd, int sig) { return syscall4(424, fd, sig, 0, 0); }
static long getfl(long fd) { return syscall3(142, fd, 3, 0); }
static long poll1(long fd, int ms, int *rev) { short p[4] = { 0 }; int *pfd = (int *)p; pfd[0] = (int)fd; p[2] = 1; long r = syscall3(SYS_poll, (long)p, 1, ms); *rev = p[3]; return r; }
static long waitid_(int type, long id, void *si, int opt) { return syscall5(SYS_waitid, type, id, (long)si, opt, 0); }
static long fork_(void) { return syscall0(SYS_fork); }
static void exit_(int c) { syscall1(SYS_exit, c); for (;;) {} }
static void nap(int ms) { long t[2] = { 0, ms * 1000000L }; syscall2(35, (long)t, 0); }
static long getpid_(void) { return syscall0(SYS_getpid); }
static long open_(const char *p) { return syscall3(9, (long)p, 0, 0); }
static long sigact(int sig, void (*h)(int)) { struct ksigaction sa; memset(&sa, 0, sizeof sa); sa.handler = h; return sigaction(sig, &sa, 0); }
static long getfd_(long pfd, long fd, long fl) { return syscall3(438, pfd, fd, fl); }
static long pipe_(int *p) { return syscall1(SYS_pipe, (long)p); }
static long read_(long fd, void *b, long n) { return syscall3(SYS_read, fd, (long)b, n); }
static long write_(long fd, const void *b, long n) { return syscall3(SYS_write, fd, (long)b, n); }
static long getfdflags(long fd) { return syscall3(142, fd, 1, 0); }
static long waitpid_(long p) { return syscall3(SYS_waitpid, p, 0, 0); }
#endif
#define P_PIDFD_ 3
#define WEXITED_ 4
#define WNOHANG_ 1
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello460:   ok   " : "hello460:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static volatile int got;
static void on_usr1(int s) { got = s; }
/* siginfo_t: si_signo at 0, si_code at 8, si_pid at 16, si_status at 24. */
static int sig_int(const unsigned char *si, int off) { int v; memcpy(&v, si + off, 4); return v; }
int main(void) {
    print("hello460: pidfd flags, PIDFD_SELF, poll and waitid(P_PIDFD)\n");
    long me = getpid_();
    long nb = pidfd_open_(me, 0x800), th = pidfd_open_(me, 0x80);
    long fnb = getfl(nb), fth = getfl(th);
    long e2 = pidfd_open_(me, 2), ec = pidfd_open_(me, 0x80000);
    snprintf(msg, sizeof msg, "A: NONBLOCK %d F_GETFL 0x%lx; THREAD %d F_GETFL 0x%lx; flag 2 %ld, O_CLOEXEC %ld (1 0x802 1 0x82 -22 -22)", nb >= 0, fnb, th >= 0, fth, e2, ec);
    check(nb >= 0 && fnb == 0x802 && th >= 0 && fth == 0x82 && e2 == -22 && ec == -22, msg);

    sigact(10, on_usr1);
    got = 0;
    long s1 = pidfd_send_(-10000, 10);
    int g1 = got;
    got = 0;
    long s2 = pidfd_send_(-10001, 10);
    int g2 = got;
    long s3 = pidfd_send_(-10002, 10);
    snprintf(msg, sizeof msg, "B: PIDFD_SELF_THREAD %ld got %d; PIDFD_SELF_THREAD_GROUP %ld got %d; -10002 %ld (0 10 0 10 -9)", s1, g1, s2, g2, s3);
    check(s1 == 0 && g1 == 10 && s2 == 0 && g2 == 10 && s3 == -9, msg);

    long ch = fork_();
    if (ch == 0) {
        nap(300);
        exit_(3);
    }
    long cp = pidfd_open_(ch, 0);
    int rev0 = -1, rev1 = -1, rev2 = -1;
    long p0 = poll1(cp, 0, &rev0);
    long p1 = poll1(cp, 3000, &rev1);
    unsigned char si[128];
    memset(si, 0, sizeof si);
    long w1 = waitid_(P_PIDFD_, cp, si, WEXITED_);
    int wpid = sig_int(si, 16), wst = sig_int(si, 24);
    long w2 = waitid_(P_PIDFD_, cp, si, WEXITED_);
    long p2 = poll1(cp, 0, &rev2);
    snprintf(msg, sizeof msg, "C: running poll %ld 0x%x; after exit %ld 0x%x; waitid %ld pid ok %d status %d; again %ld; reaped poll %ld 0x%x (0 0; 1 0x1; 0 1 3; -10; 1 0x11)", p0,
             rev0, p1, rev1, w1, wpid == ch, wst, w2, p2, rev2);
    check(p0 == 0 && rev0 == 0 && p1 == 1 && rev1 == 1 && w1 == 0 && wpid == ch && wst == 3 && w2 == -10 && p2 == 1 && rev2 == 0x11, msg);

    long dn = open_("/dev/null");
    long d1 = waitid_(P_PIDFD_, dn, si, WEXITED_);
    long self = pidfd_open_(me, 0);
    long d2 = waitid_(P_PIDFD_, self, si, WEXITED_ | WNOHANG_);
    snprintf(msg, sizeof msg, "D: waitid(P_PIDFD) on /dev/null %ld; on its own pidfd %ld (-9 -10)", d1, d2);
    check(d1 == -9 && d2 == -10, msg);

    long ch2 = fork_();
    if (ch2 == 0) {
        nap(300);
        exit_(4);
    }
    long cn = pidfd_open_(ch2, 0x800);
    long e1 = waitid_(P_PIDFD_, cn, si, WEXITED_);
    int rev3 = -1;
    poll1(cn, 3000, &rev3);
    memset(si, 0, sizeof si);
    long e3 = waitid_(P_PIDFD_, cn, si, WEXITED_);
    snprintf(msg, sizeof msg, "E: NONBLOCK pidfd: waitid while running %ld; after exit %ld status %d (-11 0 4)", e1, e3, sig_int(si, 24));
    check(e1 == -11 && e3 == 0 && sig_int(si, 24) == 4, msg);

    int go[2], q[2];
    pipe_(go);
    pipe_(q);
    long ch3 = fork_();
    if (ch3 == 0) {
        write_(q[1], "hi", 2);
        char b;
        read_(go[0], &b, 1);
        exit_(0);
    }
    nap(50);
    long pf = pidfd_open_(ch3, 0);
    long g = getfd_(pf, q[0], 0);
    long gfl = g >= 0 ? getfdflags(g) : -1;
    char rb[4] = { 0 };
    long gn = g >= 0 ? read_(g, rb, 4) : -1;
    long gbad = getfd_(pf, 0, 1), gclosed = getfd_(pf, 100, 0), gnot = getfd_(q[1], 0, 0);
    long own = getfd_(self, go[1], 0);
    write_(go[1], "x", 1);
    waitpid_(ch3);
    long gr = getfd_(pf, 0, 0);
    snprintf(msg, sizeof msg, "F: pidfd_getfd %d cloexec %ld, read %ld \"%.2s\"; flags 1 %ld, fd 100 %ld, not a pidfd %ld; own %d; after reap %ld (1 1 2 hi -22 -9 -9 1 -3)", g >= 0,
             gfl, gn, rb, gbad, gclosed, gnot, own >= 0, gr);
    check(g >= 0 && gfl == 1 && gn == 2 && memcmp(rb, "hi", 2) == 0 && gbad == -22 && gclosed == -9 && gnot == -9 && own >= 0 && gr == -3, msg);

    print(failures ? "hello460: FAIL\n" : "hello460: PASS\n");
    return failures ? 1 : 0;
}
