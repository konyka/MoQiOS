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
 *   C. EPOLLONESHOT: one report, then 0 while the signal is still pending. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
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

    print(failures ? "hello446: FAIL\n" : "hello446: PASS\n");
    return failures ? 1 : 0;
}
