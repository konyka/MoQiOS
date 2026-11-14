/* hello326: O_ASYNC on the console tty (Linux drivers/tty/tty_io.c __tty_fasync, tiocsti; drivers/tty/n_tty.c n_tty_receive_buf_common
 * → kill_fasync(POLL_IN); fs/fcntl.c __f_setown with force 0).
 * Measured on the host (build with -DHOST: a pty slave in raw mode stands in for /dev/tty, the master writes stand in for TIOCSTI):
 *   A. F_SETFL O_ASYNC on the terminal reads back O_RDWR|O_ASYNC;
 *   B. enabling it on a description with no owner makes the caller the owner (the terminal's foreground group when it has one);
 *      an owner set before is kept;
 *   C. with F_SETSIG 40 an arriving character sends POLL_IN, band 0x41 and the fd;
 *   D. a second character sends again while the first is unread;
 *   E. the terminal's own writes and reads signal nothing;
 *   F. with signal 0 a plain SIGIO (SI_KERNEL, band 0) is sent;
 *   G. clearing O_ASYNC stops the signals;
 *   H. a dup shares O_ASYNC;
 *   I. a second open of the terminal is a separate description: only the armed one is signalled, both when both are armed;
 *   J. TIOCSTI on a pipe is ENOTTY; on the target also: a NULL pointer is EFAULT, and a caller in another session without
 *      CAP_SYS_ADMIN gets EPERM (Linux with LEGACY_TIOCSTI, the upstream default). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long fc(long fd, long cmd, long a) { long r = syscall(SYS_fcntl, fd, cmd, a); return r == -1 ? -errno : r; }
static long io(long fd, unsigned long cmd, void *a) { long r = ioctl(fd, cmd, a); return r == -1 ? -errno : r; }
static int master;
static char slave_name[64];
static int open_tty(void) {
    if (!master) {
        master = posix_openpt(O_RDWR | O_NOCTTY);
        grantpt(master);
        unlockpt(master);
        snprintf(slave_name, sizeof slave_name, "%s", ptsname(master));
    }
    int s = open(slave_name, O_RDWR | O_NOCTTY);
    struct termios t;
    tcgetattr(s, &t);
    cfmakeraw(&t);
    tcsetattr(s, TCSANOW, &t);
    return s;
}
static void inj(int fd, char c) { (void)fd; write(master, &c, 1); }
static void drain_out(void) { char b[64]; fcntl(master, F_SETFL, O_NONBLOCK); while (read(master, b, sizeof b) > 0) {} }
static volatile long cnt[64], code[64], band[64], sfd[64];
static void on_sig(int s, siginfo_t *si, void *u) {
    (void)u;
    cnt[s]++;
    code[s] = si->si_code;
    band[s] = si->si_band;
    sfd[s] = si->si_fd;
}
static void handle(int sig) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_sig;
    sa.sa_flags = SA_SIGINFO;
    sigaction(sig, &sa, 0);
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
static long fc(long fd, long cmd, long a) { return syscall3(142, fd, cmd, a); }
static long io(long fd, unsigned long cmd, void *a) { return syscall3(165, fd, (long)cmd, (long)a); }
static int open_tty(void) { return (int)open("/dev/tty", 2, 0); }
static void inj(int fd, char c) { io(fd, 0x5412, &c); }
static void drain_out(void) {}
static unsigned hdr[2], data[6];
static long drop_caps(void) {
    hdr[0] = 0x20080522u;
    hdr[1] = 0;
    memset(data, 0, sizeof data);
    return syscall2(307 /* native capset */, (long)hdr, (long)data);
}
struct kinfo { int signo, err, code, pad; long band; int fd; };
static volatile long cnt[64], code[64], band[64], sfd[64];
static void on_sig(int s, struct kinfo *si, void *u) {
    (void)u;
    cnt[s]++;
    code[s] = si->code;
    band[s] = si->band;
    sfd[s] = si->fd;
}
static void handle(int sig) {
    struct ksigaction sa = { (void (*)(int))on_sig, 0x4, (void *)0, 0 };
    sigaction(sig, &sa, (struct ksigaction *)0);
}
#endif

#define C_GETFL 3
#define C_SETFL 4
#define C_GETOWN 9
#define C_SETOWN 8
#define C_SETSIG 10
#define A_SYNC 0x2000
#define LARGEFILE 0x8000
#define S_IO 29
#define S_RT 40
static int failures;
static char msg[360];
static char buf[64];
static void check(int ok, const char *w) {
    print(ok ? "hello326:   ok   " : "hello326:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void reset(void) {
    for (int i = 0; i < 64; i++) cnt[i] = 0, code[i] = band[i] = sfd[i] = -9;
}
static void await(int sig, long n) { for (int i = 0; i < 100 && cnt[sig] < n; i++) usleep(5000); }
static void quiet(void) { usleep(40000); }
static long fl(int fd) { return fc(fd, C_GETFL, 0) & ~LARGEFILE; }
static long eat(int fd) { return read(fd, buf, sizeof buf); }

int main(void) {
    print("hello326: O_ASYNC on the console tty\n");
    handle(S_IO);
    handle(S_RT);
    int t = open_tty();
    long a0 = fc(t, C_SETFL, fl(t) | A_SYNC), a1 = fl(t);
    snprintf(msg, sizeof msg, "A: F_SETFL O_ASYNC on the terminal reads back (%d %ld 0x%lx)", t, a0, a1);
    check(t >= 0 && a0 == 0 && a1 == 0x2002, msg);

    int pg = -1;
    long b0 = fc(t, C_GETOWN, 0), bp = io(t, 0x540F, &pg);
    fc(t, C_SETOWN, getpid());
    long kid = fork();
    if (kid == 0) {
        for (;;) pause();
    }
    int u = open_tty();
    fc(u, C_SETOWN, kid);
    fc(u, C_SETFL, fl(u) | A_SYNC);
    long b1 = fc(u, C_GETOWN, 0);
    close(u);
    kill(kid, 9);
    while (waitpid(kid, 0, 0) != kid) {}
    snprintf(msg, sizeof msg, "B: enabling makes the caller (or the foreground group) the owner, an earlier owner is kept (%ld; pid %ld pgrp %ld/%d; kept %ld/%ld)",
             b0, (long)getpid(), bp, pg, b1, kid);
    check((b0 == getpid() || (bp == 0 && pg > 0 && b0 == -pg)) && b1 == kid, msg);

    fc(t, C_SETSIG, S_RT);
    reset();
    inj(t, 'a');
    await(S_RT, 1);
    long c0 = cnt[S_RT], c1 = code[S_RT], c2 = band[S_RT], c3 = sfd[S_RT];
    snprintf(msg, sizeof msg, "C: an arriving character sends POLL_IN, band 0x41, the fd (hits %ld code %ld band 0x%lx fd %ld/%d)", c0, c1, c2, c3, t);
    check(c0 == 1 && c1 == 1 && c2 == 0x41 && c3 == t, msg);
    inj(t, 'b');
    await(S_RT, 2);
    snprintf(msg, sizeof msg, "D: another one signals again while unread (hits %ld)", cnt[S_RT]);
    check(cnt[S_RT] == 2, msg);

    reset();
    long e0 = eat(t);
    long e1 = write(t, "hello326: tty write\n", 20);
    drain_out();
    quiet();
    snprintf(msg, sizeof msg, "E: the terminal's own reads and writes signal nothing (read %ld write %ld hits %ld)", e0, e1, cnt[S_RT] + cnt[S_IO]);
    check(e0 == 2 && e1 == 20 && cnt[S_RT] + cnt[S_IO] == 0, msg);

    fc(t, C_SETSIG, 0);
    reset();
    inj(t, 'c');
    await(S_IO, 1);
    snprintf(msg, sizeof msg, "F: signal 0 sends a plain SIGIO (hits %ld code %ld band %ld fd %ld)", cnt[S_IO], code[S_IO], band[S_IO], sfd[S_IO]);
    check(cnt[S_IO] == 1 && code[S_IO] == 0x80 && band[S_IO] == 0 && sfd[S_IO] == 0, msg);
    eat(t);
    fc(t, C_SETSIG, S_RT);

    long g0 = fc(t, C_SETFL, fl(t) & ~A_SYNC), g1 = fl(t);
    reset();
    inj(t, 'd');
    quiet();
    snprintf(msg, sizeof msg, "G: clearing O_ASYNC stops the signals (%ld 0x%lx hits %ld)", g0, g1, cnt[S_RT]);
    check(g0 == 0 && g1 == 2 && cnt[S_RT] == 0, msg);
    eat(t);
    fc(t, C_SETFL, fl(t) | A_SYNC);

    int d = dup(t);
    long h0 = fl(d);
    close(d);
    snprintf(msg, sizeof msg, "H: a dup shares O_ASYNC (0x%lx)", h0);
    check(h0 == 0x2002, msg);

    int v = open_tty();
    long i0 = fl(v);
    reset();
    inj(t, 'e');
    await(S_RT, 1);
    quiet();
    long i1 = cnt[S_RT], i2 = sfd[S_RT];
    fc(v, C_SETOWN, getpid());
    fc(v, C_SETSIG, S_RT);
    fc(v, C_SETFL, fl(v) | A_SYNC);
    reset();
    inj(t, 'f');
    await(S_RT, 2);
    quiet();
    snprintf(msg, sizeof msg, "I: a second open is its own description (0x%lx; one armed: hits %ld fd %ld/%d; both armed: hits %ld)", i0, i1, i2, t, cnt[S_RT]);
    check(v >= 0 && i0 == 2 && i1 == 1 && i2 == t && cnt[S_RT] == 2, msg);
    eat(t);
    close(v);

    int p[2];
    pipe(p);
    char ch = 'x';
    long j0 = io(p[0], 0x5412, &ch);
    close(p[0]);
    close(p[1]);
#ifdef HOST
    snprintf(msg, sizeof msg, "J: TIOCSTI on a pipe is ENOTTY (%ld)", j0);
    check(j0 == -25, msg);
#else
    long j1 = io(t, 0x5412, 0);
    long jc = fork();
    if (jc == 0) {
        setsid();
        drop_caps();
        char z = 'z';
        _exit(io(t, 0x5412, &z) == -1 ? 0 : 1);
    }
    int jst = -1;
    while (waitpid(jc, &jst, 0) != jc) {}
    reset();
    quiet();
    long j2 = eat(t);
    snprintf(msg, sizeof msg, "J: TIOCSTI: pipe ENOTTY %ld, NULL EFAULT %ld, other session without CAP_SYS_ADMIN EPERM (child %d; queued %ld)", j0, j1, jst, j2);
    check(j0 == -25 && j1 == -14 && jst == 0 && j2 == 0, msg);
#endif
    close(t);

    print(failures == 0 ? "hello326: PASS\n" : "hello326: FAIL\n");
    return failures;
}
