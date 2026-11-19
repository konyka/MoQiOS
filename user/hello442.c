/* hello442: signalfd (Linux fs/signalfd.c). signalfd4(-1, mask, 8, flags) makes a descriptor that reads the caller's pending signals
 * in `mask` as 128-byte struct signalfd_siginfo records (ssi_signo at 0, ssi_code at 8, ssi_pid at 12, ssi_int at 44), dequeuing
 * them; SIGKILL and SIGSTOP are dropped from the mask; sizemask other than 8 is EINVAL, flags other than SFD_NONBLOCK|SFD_CLOEXEC
 * EINVAL; a read shorter than 128 is EINVAL; a non-blocking read with nothing pending EAGAIN; poll reports POLLIN while such a
 * signal is pending; signalfd4(fd, mask2, 8, 0) on an existing signalfd replaces its mask, on another descriptor EINVAL. The kernel
 * used to return a plain eventfd and ignore mask, sizemask and flags.
 * Measured on the host (build with -DHOST):
 *   A. sizemask 4 -> -22; flags 1 -> -22; on a pipe descriptor -> -22; SFD_NONBLOCK|SFD_CLOEXEC -> fd >= 0 with FD_CLOEXEC set;
 *   B. SIGUSR1 blocked, nothing pending: read -> -11, poll revents 0; after kill(self, SIGUSR1): poll POLLIN (1), read of 64 bytes
 *      -> -22, read of 256 -> 128 with signo 10, code 0 (SI_USER), pid self; the signal is no longer pending (rt_sigpending bit 0);
 *   C. two queued sigqueue(SIGRTMIN, 5) and (SIGRTMIN, 6) plus a pending SIGUSR2 with the mask {SIGUSR2, SIGRTMIN}: one read of 384
 *      bytes -> 384: SIGUSR2 first, then 34 code -1 (SI_QUEUE) value 5, then 34 value 6;
 *   D. signalfd4(fd, {SIGUSR1}) on the same descriptor -> the same fd; a pending SIGUSR2 is no longer readable (-11) but SIGUSR1 is. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sys4(long n, long a, long b, long c, long d) { long r = syscall(n, a, b, c, d); return r < 0 ? -errno : r; }
static long rd(long fd, void *b, long n) { long r = read((int)fd, b, n); return r < 0 ? -errno : r; }
static long poll1(long fd) { struct pollfd p = { (int)fd, POLLIN, 0 }; long r = poll(&p, 1, 0); return r < 0 ? -errno : p.revents; }
static long getfd(long fd) { return fcntl((int)fd, F_GETFD); }
static long pipe_(int *p) { return pipe(p); }
static long me(void) { return getpid(); }
#define NR_SIGNALFD4 289
#define NR_SIGPROCMASK 14
#define NR_SIGPENDING 127
#define NR_SIGQUEUEINFO 129
#define NR_KILL 62
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sys4(long n, long a, long b, long c, long d) { return syscall4(n, a, b, c, d); }
static long rd(long fd, void *b, long n) { return read((int)fd, b, n); }
static long poll1(long fd) { struct { int fd; short ev, rev; } p = { (int)fd, 1, 0 }; long r = syscall3(162, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static long getfd(long fd) { return syscall3(72, fd, 1, 0); }
static long pipe_(int *p) { return pipe(p); }
static long me(void) { return getpid(); }
#define NR_SIGNALFD4 225
#define NR_SIGPROCMASK 14
#define NR_SIGPENDING 219
#define NR_SIGQUEUEINFO 222
#define NR_KILL 62
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello442:   ok   " : "hello442:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned long bit(int s) { return 1UL << (s - 1); }
static unsigned char buf[512];
static int u32at(int off) { int v; memcpy(&v, buf + off, 4); return v; }
static long queue(int sig, int value) {
    int si[32];
    memset(si, 0, sizeof si);
    si[0] = sig;
    si[2] = -1; /* SI_QUEUE */
    si[4] = (int)me();
    si[6] = value;
    return sys4(NR_SIGQUEUEINFO, me(), sig, (long)si, 0);
}
int main(void) {
    print("hello442: signalfd reads pending signals as signalfd_siginfo\n");
    unsigned long all = bit(10) | bit(12) | bit(34);
    sys4(NR_SIGPROCMASK, 0, (long)&all, 0, 8);
    unsigned long m1 = bit(10);
    int p[2];
    pipe_(p);
    long a0 = sys4(NR_SIGNALFD4, -1, (long)&m1, 4, 0), a1 = sys4(NR_SIGNALFD4, -1, (long)&m1, 8, 1), a2 = sys4(NR_SIGNALFD4, p[0], (long)&m1, 8, 0);
    long fd = sys4(NR_SIGNALFD4, -1, (long)&m1, 8, 0x800 | 0x80000);
    long cl = fd >= 0 ? getfd(fd) : -1;
    snprintf(msg, sizeof msg, "A: sizemask 4 %ld; flags 1 %ld; on a pipe %ld; NONBLOCK|CLOEXEC fd %ld FD_CLOEXEC %ld (-22 -22 -22; >=0 1)", a0, a1, a2, fd, cl);
    check(a0 == -22 && a1 == -22 && a2 == -22 && fd >= 0 && cl == 1, msg);

    long b0 = rd(fd, buf, 256), bp0 = poll1(fd);
    sys4(NR_KILL, me(), 10, 0, 0);
    long bp1 = poll1(fd), bshort = rd(fd, buf, 64);
    memset(buf, 0, sizeof buf);
    long b1 = rd(fd, buf, 256);
    unsigned long pend = 0;
    sys4(NR_SIGPENDING, (long)&pend, 8, 0, 0);
    snprintf(msg, sizeof msg, "B: empty read %ld poll %ld; after kill poll %ld, read 64 %ld, read 256 %ld signo %d code %d pid self %d; still pending %d "
             "(-11 0; 1 -22 128 10 0 1; 0)", b0, bp0, bp1, bshort, b1, u32at(0), u32at(8), u32at(12) == (int)me(), (int)((pend >> 9) & 1));
    check(b0 == -11 && bp0 == 0 && (bp1 & 1) && bshort == -22 && b1 == 128 && u32at(0) == 10 && u32at(8) == 0 && u32at(12) == (int)me() && !((pend >> 9) & 1), msg);

    unsigned long m2 = bit(12) | bit(34);
    long same = sys4(NR_SIGNALFD4, fd, (long)&m2, 8, 0);
    long q1 = queue(34, 5), q2 = queue(34, 6);
    sys4(NR_KILL, me(), 12, 0, 0);
    memset(buf, 0, sizeof buf);
    long c = rd(fd, buf, 384);
    snprintf(msg, sizeof msg, "C: re-mask %ld (same fd); queued %ld %ld; read 384 %ld: %d, %d code %d value %d, %d value %d (fd; 0 0; 384: 12, 34 -1 5, 34 6)", same, q1, q2, c,
             u32at(0), u32at(128), u32at(136), u32at(128 + 44), u32at(256), u32at(256 + 44));
    check(same == fd && q1 == 0 && q2 == 0 && c == 384 && u32at(0) == 12 && u32at(128) == 34 && u32at(136) == -1 && u32at(128 + 44) == 5 && u32at(256) == 34 &&
              u32at(256 + 44) == 6, msg);

    sys4(NR_KILL, me(), 12, 0, 0);
    sys4(NR_KILL, me(), 10, 0, 0);
    long d0 = sys4(NR_SIGNALFD4, fd, (long)&m1, 8, 0);
    long d1 = rd(fd, buf, 128);
    int s1 = u32at(0);
    long d2 = rd(fd, buf, 128);
    pend = 0;
    sys4(NR_SIGPENDING, (long)&pend, 8, 0, 0);
    snprintf(msg, sizeof msg, "D: mask {SIGUSR1} %ld; read %ld signo %d; read again %ld; SIGUSR2 still pending %d (fd; 128 10; -11; 1)", d0, d1, s1, d2, (int)((pend >> 11) & 1));
    check(d0 == fd && d1 == 128 && s1 == 10 && d2 == -11 && ((pend >> 11) & 1), msg);
    print(failures == 0 ? "hello442: PASS\n" : "hello442: FAIL\n");
    return failures == 0 ? 0 : 1;
}
