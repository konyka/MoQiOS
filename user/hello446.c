/* hello446: signalfd in epoll (Linux fs/signalfd.c signalfd_poll + the sighand wait queue a signal wakes). An epoll instance holding
 * a signalfd reports EPOLLIN while one of its signals is pending for the waiting task, and a task asleep in epoll_wait wakes when such
 * a signal arrives. The kernel used to see signalfd readiness only in poll/select, so epoll_wait never reported it and slept through
 * the signal until its timeout.
 * Measured on the host (build with -DHOST):
 *   A. SIGUSR1 blocked, signalfd for it in epoll (EPOLLIN): epoll_wait(0) -> 0; after kill(self, SIGUSR1): -> 1 with events 0x1 and
 *      the registered data 7; it stays ready (level-triggered) until the signal is read: epoll_wait(0) -> 1 again, read -> 128 signo
 *      10, then epoll_wait(0) -> 0;
 *   B. a child sends SIGUSR1 to the parent 100 ms after the parent sleeps in epoll_wait(3000): the wait returns 1 in well under a
 *      second (< 1500 ms);
 *   C. EPOLLONESHOT: one report, then 0 while the signal is still pending;
 *   D. the signalfd passed over an AF_UNIX socketpair with SCM_RIGHTS: the received descriptor is a new number, the sender's is
 *      closed, and a SIGUSR1 sent to self is read through the received one (128 bytes, signo 10). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sys4(long n, long a, long b, long c, long d) { long r = syscall(n, a, b, c, d); return r < 0 ? -errno : r; }
static long rd(long fd, void *b, long n) { long r = read((int)fd, b, n); return r < 0 ? -errno : r; }
static long epcreate(void) { long r = epoll_create1(0); return r < 0 ? -errno : r; }
static long epctl(long ep, int op, long fd, unsigned ev, unsigned long data) {
    struct epoll_event e;
    e.events = ev;
    e.data.u64 = data;
    long r = epoll_ctl((int)ep, op, (int)fd, &e);
    return r < 0 ? -errno : r;
}
static long epwait(long ep, unsigned char *out, int ms) { long r = epoll_wait((int)ep, (struct epoll_event *)out, 4, ms); return r < 0 ? -errno : r; }
static long me(void) { return getpid(); }
static long fork_(void) { return fork(); }
static void exit_(int c) { _exit(c); }
static void reap(void) { int st; wait(&st); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void pause_ms(long ms) { struct timespec t = { 0, ms * 1000000 }; nanosleep(&t, 0); }
static long spair(int *sv) { long r = socketpair(1, 1, 0, sv); return r < 0 ? -errno : r; }
static long smsg(long s, void *m) { long r = sendmsg((int)s, m, 0); return r < 0 ? -errno : r; }
static long rmsg(long s, void *m) { long r = recvmsg((int)s, m, 0); return r < 0 ? -errno : r; }
static void close_(long fd) { close((int)fd); }
#define NR_SIGNALFD4 289
#define NR_SIGPROCMASK 14
#define NR_KILL 62
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sys4(long n, long a, long b, long c, long d) { return syscall4(n, a, b, c, d); }
static long rd(long fd, void *b, long n) { return read((int)fd, b, n); }
static long epcreate(void) { return syscall1(SYS_epoll_create1, 0); }
static long epctl(long ep, int op, long fd, unsigned ev, unsigned long data) {
    unsigned char e[12];
    memcpy(e, &ev, 4);
    memcpy(e + 4, &data, 8);
    return syscall4(SYS_epoll_ctl, ep, op, fd, (long)e);
}
static long epwait(long ep, unsigned char *out, int ms) { return syscall4(SYS_epoll_wait, ep, (long)out, 4, ms); }
static long me(void) { return getpid(); }
static long fork_(void) { return fork(); }
static void exit_(int c) { _exit(c); }
static void reap(void) { int st; waitpid(-1, &st, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void pause_ms(long ms) { long t[2] = { 0, ms * 1000000 }; syscall2(SYS_nanosleep, (long)t, 0); }
static long spair(int *sv) { return syscall4(53, 1, 1, 0, (long)sv); }
static long smsg(long s, void *m) { return syscall3(129, s, (long)m, 0); }
static long rmsg(long s, void *m) { return syscall3(130, s, (long)m, 0); }
static void close_(long fd) { syscall1(SYS_close, fd); }
#define NR_SIGNALFD4 225
#define NR_SIGPROCMASK 14
#define NR_KILL 62
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello446:   ok   " : "hello446:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned rd32(const unsigned char *p) { unsigned v; memcpy(&v, p, 4); return v; }
static unsigned long rd64(const unsigned char *p) { unsigned long v; memcpy(&v, p, 8); return v; }
int main(void) {
    print("hello446: a signalfd in epoll reports its signals and wakes epoll_wait\n");
    unsigned long m1 = 1UL << 9; /* SIGUSR1 */
    sys4(NR_SIGPROCMASK, 0, (long)&m1, 0, 8);
    long sfd = sys4(NR_SIGNALFD4, -1, (long)&m1, 8, 0);
    long ep = epcreate();
    long ac = epctl(ep, 1, sfd, 1, 7);
    unsigned char ev[48];
    long w0 = epwait(ep, ev, 0);
    sys4(NR_KILL, me(), 10, 0, 0);
    memset(ev, 0, sizeof ev);
    long w1 = epwait(ep, ev, 0);
    unsigned e1 = rd32(ev);
    unsigned long d1 = rd64(ev + 4);
    long w2 = epwait(ep, ev, 0);
    unsigned char rec[128];
    long r = rd(sfd, rec, sizeof rec);
    unsigned signo = rd32(rec);
    long w3 = epwait(ep, ev, 0);
    snprintf(msg, sizeof msg, "A: sfd %ld, add %ld, wait %ld, after kill %ld events 0x%x data %lu, again %ld, read %ld signo %u, after read %ld "
             "(>=0, 0, 0, 1 0x1 7, 1, 128 10, 0)", sfd, ac, w0, w1, e1, d1, w2, r, signo, w3);
    check(sfd >= 0 && ac == 0 && w0 == 0 && w1 == 1 && e1 == 1 && d1 == 7 && w2 == 1 && r == 128 && signo == 10 && w3 == 0, msg);

    long parent = me();
    long pid = fork_();
    if (pid == 0) {
        pause_ms(100);
        sys4(NR_KILL, parent, 10, 0, 0);
        exit_(0);
    }
    long t0 = now_ms();
    long wb = epwait(ep, ev, 3000);
    long dt = now_ms() - t0;
    reap();
    r = rd(sfd, rec, sizeof rec);
    snprintf(msg, sizeof msg, "B: fork %ld, wait %ld in %ld ms, read %ld (>0, 1 in <1500, 128)", pid, wb, dt, r);
    check(pid > 0 && wb == 1 && dt < 1500 && r == 128, msg);

    long mo = epctl(ep, 3, sfd, 1 | 0x40000000, 9);
    sys4(NR_KILL, me(), 10, 0, 0);
    long o1 = epwait(ep, ev, 0);
    unsigned long d2 = rd64(ev + 4);
    long o2 = epwait(ep, ev, 0);
    r = rd(sfd, rec, sizeof rec);
    snprintf(msg, sizeof msg, "C: mod oneshot %ld, wait %ld data %lu, again %ld, read %ld (0, 1 9, 0, 128)", mo, o1, d2, o2, r);
    check(mo == 0 && o1 == 1 && d2 == 9 && o2 == 0 && r == 128, msg);

    struct iov_ { void *b; unsigned long n; };
    struct mh_ { void *name; unsigned int nl; int pad; struct iov_ *iov; unsigned long iovlen; void *ctl; unsigned long ctllen; int flags; int pad2; };
    int sv[2];
    long sp = spair(sv);
    unsigned char ctl[24];
    memset(ctl, 0, sizeof ctl);
    unsigned long clen = 20;
    memcpy(ctl, &clen, 8);
    int lvl = 1, typ = 1, fdv = (int)sfd;
    memcpy(ctl + 8, &lvl, 4);
    memcpy(ctl + 12, &typ, 4);
    memcpy(ctl + 16, &fdv, 4);
    char x = 'x';
    struct iov_ v1 = { &x, 1 };
    struct mh_ mh1;
    memset(&mh1, 0, sizeof mh1);
    mh1.iov = &v1;
    mh1.iovlen = 1;
    mh1.ctl = ctl;
    mh1.ctllen = 24;
    long sn = smsg(sv[0], &mh1);
    close_(sfd);
    unsigned char rc[64];
    memset(rc, 0, sizeof rc);
    char y = 0;
    struct iov_ v2 = { &y, 1 };
    struct mh_ m2;
    memset(&m2, 0, sizeof m2);
    m2.iov = &v2;
    m2.iovlen = 1;
    m2.ctl = rc;
    m2.ctllen = sizeof rc;
    long rv = rmsg(sv[1], &m2);
    int got_fd = -1;
    if (rv == 1 && m2.ctllen >= 20 && rd32(rc + 8) == 1 && rd32(rc + 12) == 1) memcpy(&got_fd, rc + 16, 4);
    sys4(NR_KILL, me(), 10, 0, 0);
    memset(rec, 0, sizeof rec);
    r = got_fd >= 0 ? rd(got_fd, rec, sizeof rec) : -1;
    signo = rd32(rec);
    snprintf(msg, sizeof msg, "D: socketpair %ld, send %ld, recv %ld fd %d, read through it %ld signo %u (0, 1, 1 >=0, 128 10)", sp, sn, rv, got_fd, r, signo);
    check(sp == 0 && sn == 1 && rv == 1 && got_fd >= 0 && r == 128 && signo == 10, msg);

    print(failures ? "hello446: FAIL\n" : "hello446: PASS\n");
    return failures ? 1 : 0;
}
