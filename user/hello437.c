/* hello437: pidfd_send_signal reads its siginfo and flags (Linux kernel/signal.c do_pidfd_send_signal). A siginfo is copied in; its
 * si_signo must equal sig (EINVAL); a code that is not negative, or SI_TKILL, may only be sent to the caller's own process (EPERM).
 * The flags choose the scope: PIDFD_SIGNAL_THREAD (1), PIDFD_SIGNAL_THREAD_GROUP (2) or PIDFD_SIGNAL_PROCESS_GROUP (4), at most one;
 * other bits or two scopes are EINVAL. Without a siginfo the receiver sees SI_USER and the sender's pid. The kernel used to ignore
 * the siginfo and reject every flag.
 * Measured on the host (build with -DHOST):
 *   A. pidfd of itself, SIGUSR1 with siginfo { signo 10, code SI_QUEUE (-1), value 1234 }: 0, the handler sees code -1 and value 1234;
 *   B. si_signo 12 with sig 10: -22; flags 8: -22; flags 1|2: -22;
 *   C. to a child, code SI_QUEUE: 0 and the child reports code -1, value 77; code 0 (SI_USER, forged) to the child: -1 (EPERM);
 *   D. NULL siginfo with PIDFD_SIGNAL_THREAD_GROUP to the child: 0, the child sees code 0 (SI_USER) and si_pid of the parent;
 *   E. PIDFD_SIGNAL_PROCESS_GROUP to the child after setpgid(child, child): 0, the child gets it. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long sys4(long n, long a, long b, long c, long d) { long r = syscall(n, a, b, c, d); return r < 0 ? -errno : r; }
#define NR_PIDFD_OPEN 434
#define NR_PIDFD_SEND 424
#define NR_TIMEDWAIT 128
static long fork_(void) { return fork(); }
static long wait_(long pid, int *st) { return waitpid((pid_t)pid, st, 0); }
static long setpgid_(long a, long b) { return setpgid((pid_t)a, (pid_t)b) < 0 ? -errno : 0; }
static long pipe_(int *p) { return pipe(p) < 0 ? -errno : 0; }
static long rd(int fd, void *b, long n) { return read(fd, b, n); }
static long wr(int fd, const void *b, long n) { return write(fd, b, n); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sys4(long n, long a, long b, long c, long d) { return syscall4(n, a, b, c, d); }
#define NR_PIDFD_OPEN 434
#define NR_PIDFD_SEND 424
#define NR_TIMEDWAIT 221
static long fork_(void) { return fork(); }
static long wait_(long pid, int *st) { return waitpid(pid, st, 0); }
static long setpgid_(long a, long b) { return setpgid(a, b); }
static long pipe_(int *p) { return pipe(p); }
static long rd(int fd, void *b, long n) { return read(fd, b, n); }
static long wr(int fd, const void *b, long n) { return write(fd, b, n); }
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello437:   ok   " : "hello437:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* siginfo_t: si_signo 0, si_errno 4, si_code 8; for SI_QUEUE si_pid 16, si_uid 20, si_value 24. */
static void mkinfo(int *si, int signo, int code, int value) {
    memset(si, 0, 128);
    si[0] = signo;
    si[2] = code;
    si[4] = (int)getpid();
    si[6] = value;
}
/* Wait up to 2 s for SIGUSR1 (blocked): the signal number, code, value and sender pid. */
static long take(int *code, int *value, int *pid) {
    unsigned long set = 1UL << 9;
    long ts[2] = { 2, 0 };
    int info[32];
    memset(info, 0, sizeof info);
    long r = sys4(NR_TIMEDWAIT, (long)&set, (long)info, (long)ts, 8);
    *code = info[2];
    *pid = info[4];
    *value = info[6];
    return r;
}
int main(void) {
    print("hello437: pidfd_send_signal reads its siginfo and flags\n");
    unsigned long usr1 = 1UL << 9;
    sys4(14, 0, (long)&usr1, 0, 8);
    long me = getpid();
    long self = sys4(NR_PIDFD_OPEN, me, 0, 0, 0);
    int si[32];
    mkinfo(si, 10, -1, 1234);
    long a = sys4(NR_PIDFD_SEND, self, 10, (long)si, 0);
    int code = 99, value = 0, pid = 0;
    long ta = take(&code, &value, &pid);
    snprintf(msg, sizeof msg, "A: pidfd_open self %ld; send with SI_QUEUE %ld; taken %ld code %d value %d (>=0; 0; 10 -1 1234)", self, a, ta, code, value);
    check(self >= 0 && a == 0 && ta == 10 && code == -1 && value == 1234, msg);

    mkinfo(si, 12, -1, 1);
    long b0 = sys4(NR_PIDFD_SEND, self, 10, (long)si, 0);
    long b1 = sys4(NR_PIDFD_SEND, self, 10, 0, 8);
    long b2 = sys4(NR_PIDFD_SEND, self, 10, 0, 3);
    snprintf(msg, sizeof msg, "B: si_signo 12 for sig 10 %ld; flags 8 %ld; flags 1|2 %ld (-22 -22 -22)", b0, b1, b2);
    check(b0 == -22 && b1 == -22 && b2 == -22, msg);

    int up[2], down[2];
    pipe_(up);
    pipe_(down);
    long child = fork_();
    if (child == 0) {
        /* Report the code, value and sender of three SIGUSR1s, one per byte of the go signal. */
        char go;
        for (int k = 0; k < 3; k++) {
            if (rd(down[0], &go, 1) != 1) _exit(2);
            int c = 99, v = 0, p = 0;
            long t = take(&c, &v, &p);
            int out[4] = { (int)t, c, v, p };
            wr(up[1], out, sizeof out);
        }
        _exit(0);
    }
    long pc = sys4(NR_PIDFD_OPEN, child, 0, 0, 0);
    int rep[4];
    mkinfo(si, 10, -1, 77);
    long c0 = sys4(NR_PIDFD_SEND, pc, 10, (long)si, 0);
    wr(down[1], "g", 1);
    rd(up[0], rep, sizeof rep);
    mkinfo(si, 10, 0, 5);
    long c1 = sys4(NR_PIDFD_SEND, pc, 10, (long)si, 0);
    snprintf(msg, sizeof msg, "C: pidfd of the child %ld; SI_QUEUE send %ld, child took %d code %d value %d; forged SI_USER %ld (>=0; 0 10 -1 77; -1)", pc, c0, rep[0], rep[1],
             rep[2], c1);
    check(pc >= 0 && c0 == 0 && rep[0] == 10 && rep[1] == -1 && rep[2] == 77 && c1 == -1, msg);

    long d0 = sys4(NR_PIDFD_SEND, pc, 10, 0, 2);
    wr(down[1], "g", 1);
    rd(up[0], rep, sizeof rep);
    snprintf(msg, sizeof msg, "D: no siginfo, PIDFD_SIGNAL_THREAD_GROUP %ld; child took %d code %d pid is the parent %d (0; 10 0 1)", d0, rep[0], rep[1], rep[3] == (int)me);
    check(d0 == 0 && rep[0] == 10 && rep[1] == 0 && rep[3] == (int)me, msg);

    long pg = setpgid_(child, child);
    long e0 = sys4(NR_PIDFD_SEND, pc, 10, 0, 4);
    wr(down[1], "g", 1);
    rd(up[0], rep, sizeof rep);
    int st = -1;
    long w = wait_(child, &st);
    snprintf(msg, sizeof msg, "E: setpgid %ld; PIDFD_SIGNAL_PROCESS_GROUP %ld; child took %d; child exit 0x%x (0; 0; 10; 0)", pg, e0, rep[0], st);
    check(pg == 0 && e0 == 0 && rep[0] == 10 && w == child && st == 0, msg);

    print(failures == 0 ? "hello437: PASS\n" : "hello437: FAIL\n");
    return failures == 0 ? 0 : 1;
}
