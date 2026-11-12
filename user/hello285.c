/// hello285: waitid(idtype, id, infop, options). Measured on the host with the raw syscall (build with -DHOST): success returns 0 and
/// fills a SIGCHLD siginfo (si_code CLD_EXITED/KILLED/STOPPED/CONTINUED, si_pid, si_status); WNOWAIT leaves the child waitable;
/// WNOHANG with nothing to report returns 0 with si_signo cleared; bad idtype/options/id are EINVAL, no such child is ECHILD.
/// The fifth argument (struct rusage) is filled with the child's CPU time only when a child was reported, and is EFAULT when unwritable.
/// Only six siginfo fields are written (si_signo, si_errno, si_code, si_pid, si_uid, si_status); the rest of the buffer stays as the caller left it.
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
static long wid(long type, long id, void *info, long opt) {
    long r = syscall(SYS_waitid, type, id, info, opt, 0);
    return r < 0 ? -errno : r;
}
static long widr(long type, long id, void *info, long opt, void *ru) {
    long r = syscall(SYS_waitid, type, id, info, opt, ru);
    return r < 0 ? -errno : r;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/errno.h"
static long wid(long type, long id, void *info, long opt) { return syscall5(SYS_waitid, type, id, (long)info, opt, 0); }
static long widr(long type, long id, void *info, long opt, void *ru) { return syscall5(SYS_waitid, type, id, (long)info, opt, (long)ru); }
#endif

#ifndef P_ALL
#define P_ALL 0
#define P_PID 1
#define P_PGID 2
#endif
#ifndef WEXITED
#define WEXITED 4
#endif
#ifndef WSTOPPED
#define WSTOPPED 2
#endif
#ifndef WCONTINUED
#define WCONTINUED 8
#endif
#ifndef WNOWAIT
#define WNOWAIT 0x01000000
#endif
#ifndef WNOHANG
#define WNOHANG 1
#endif
#ifndef SIGSTOP
#define SIGSTOP 19
#endif
#ifndef SIGCONT
#define SIGCONT 18
#endif
#ifndef CLD_EXITED
#define CLD_EXITED 1
#define CLD_KILLED 2
#define CLD_STOPPED 5
#define CLD_CONTINUED 6
#endif

static int failures;
static char msg[220];
static void check(int ok, const char *w) {
    print(ok ? "hello285:   ok   " : "hello285:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

/* si_signo@0 si_code@8 si_pid@16 si_uid@20 si_status@24, little endian. */
static int info_signo(const unsigned char *b) { return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24); }
static int info_code(const unsigned char *b) { return b[8] | (b[9] << 8) | (b[10] << 16) | (b[11] << 24); }
static int info_pid(const unsigned char *b) { return b[16] | (b[17] << 8) | (b[18] << 16) | (b[19] << 24); }
static int info_status(const unsigned char *b) { return b[24] | (b[25] << 8) | (b[26] << 16) | (b[27] << 24); }

/* struct rusage: ru_utime {sec@0, usec@8}, ru_stime {sec@16, usec@24}. */
static long ru_cpu_ms(const unsigned char *b) {
    long v[4];
    memcpy(v, b, sizeof v);
    return v[0] * 1000 + v[1] / 1000 + v[2] * 1000 + v[3] / 1000;
}
static int all_byte(const unsigned char *b, int n, unsigned char x) {
    for (int i = 0; i < n; i++) if (b[i] != x) return 0;
    return 1;
}
static void spin_ms(long ms) {
    struct timespec a, b;
    clock_gettime(1, &a);
    do clock_gettime(1, &b);
    while ((b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000 < ms);
}

static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

static char state_of(long pid) {
    char path[32], b[128];
    snprintf(path, sizeof path, "/proc/%ld/stat", pid);
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return 0;
    long n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return 0;
    b[n] = 0;
    char *p = strrchr(b, ')');
    return p && p[1] == ' ' ? p[2] : 0;
}
static void wait_state(long pid, char want) {
    for (int i = 0; i < 400 && state_of(pid) != want; i++) nap(5);
}

int main(void) {
    unsigned char info[128];
    long r, st;

    memset(info, 0x5a, sizeof info);
    r = wid(P_PID, 0, info, WEXITED);
    check(r == -22, "A: P_PID with id 0 is EINVAL");
    r = wid(7, 1, info, WEXITED);
    check(r == -22, "A: an unknown idtype is EINVAL");
    r = wid(P_ALL, 0, info, WNOHANG);
    check(r == -22, "A: options without WEXITED/WSTOPPED/WCONTINUED are EINVAL");
    r = wid(P_ALL, 0, info, WEXITED | 0x100000);
    check(r == -22, "A: an unknown option bit is EINVAL");
    r = wid(P_PID, 0x7fffffff, info, WEXITED | WNOHANG);
    check(r == -10, "A: a pid that is not a child is ECHILD");

    long c = fork();
    if (c == 0) { nap(30000); _exit(0); }
    memset(info, 0x5a, sizeof info);
    r = wid(P_ALL, 0, info, WEXITED | WNOHANG);
    snprintf(msg, sizeof msg, "B: a live child with WNOHANG returns 0 and clears si_signo (%ld, signo %d)", r, info_signo(info));
    check(r == 0 && info_signo(info) == 0, msg);
    kill(c, 9);
    memset(info, 0x5a, sizeof info);
    r = wid(P_PID, c, info, WEXITED | WNOWAIT);
    snprintf(msg, sizeof msg, "B: WNOWAIT reports the kill as CLD_KILLED/9 (%ld, code %d, pid %d, status %d)", r, info_code(info), info_pid(info), info_status(info));
    check(r == 0 && info_signo(info) == 17 && info_code(info) == CLD_KILLED && info_pid(info) == (int)c && info_status(info) == 9, msg);
    r = wid(P_PID, c, info, WEXITED | WNOWAIT);
    check(r == 0 && info_code(info) == CLD_KILLED && info_status(info) == 9, "B: WNOWAIT reports the same zombie again");
    r = wid(P_PID, c, 0, WEXITED);
    check(r == 0, "B: a null infop still reaps");
    r = wid(P_PID, c, info, WEXITED | WNOHANG);
    check(r == -10, "B: after the reap the child is ECHILD");
    st = 0;
    errno = 0;
    r = waitpid(c, (int *)&st, WNOHANG);
    check(r == -10 || (r < 0 && errno == 10), "B: waitpid agrees the child was reaped");

    c = fork();
    if (c == 0) _exit(7);
    nap(50);
    memset(info, 0x5a, sizeof info);
    r = wid(P_ALL, 0, info, WEXITED);
    snprintf(msg, sizeof msg, "C: P_ALL reports exit(7) as CLD_EXITED (%ld, code %d, pid %d, status %d)", r, info_code(info), info_pid(info), info_status(info));
    check(r == 0 && info_code(info) == CLD_EXITED && info_pid(info) == (int)c && info_status(info) == 7, msg);
    r = wid(P_ALL, 0, info, WEXITED | WNOHANG);
    check(r == -10, "C: the exit was reaped");

    c = fork();
    if (c == 0) { kill(getpid(), SIGSTOP); nap(30000); _exit(0); }
    wait_state(c, 'T');
    memset(info, 0x5a, sizeof info);
    r = wid(P_PID, c, info, WEXITED | WNOHANG);
    check(r == 0 && info_signo(info) == 0, "D: a stopped child is not an exit");
    r = wid(P_PID, c, info, WSTOPPED | WNOWAIT);
    snprintf(msg, sizeof msg, "D: WSTOPPED reports CLD_STOPPED/19 (%ld, code %d, status %d)", r, info_code(info), info_status(info));
    check(r == 0 && info_code(info) == CLD_STOPPED && info_pid(info) == (int)c && info_status(info) == 19, msg);
    r = wid(P_PID, c, info, WSTOPPED | WNOWAIT);
    check(r == 0 && info_code(info) == CLD_STOPPED, "D: WNOWAIT does not consume the stop");
    r = wid(P_PID, c, info, WSTOPPED | WNOHANG);
    check(r == 0 && info_code(info) == CLD_STOPPED, "D: the stop is consumed once");
    r = wid(P_PID, c, info, WSTOPPED | WNOHANG);
    check(r == 0 && info_signo(info) == 0, "D: a consumed stop is not reported again");
    kill(c, SIGCONT);
    memset(info, 0x5a, sizeof info);
    r = wid(P_PID, c, info, WCONTINUED);
    snprintf(msg, sizeof msg, "D: WCONTINUED reports CLD_CONTINUED/18 (%ld, code %d, status %d)", r, info_code(info), info_status(info));
    check(r == 0 && info_code(info) == CLD_CONTINUED && info_status(info) == 18, msg);
    setpgid(c, c);
    kill(c, 9);
    memset(info, 0x5a, sizeof info);
    r = wid(P_PGID, c, info, WEXITED);
    snprintf(msg, sizeof msg, "D: P_PGID reports the kill (%ld, code %d, pid %d)", r, info_code(info), info_pid(info));
    check(r == 0 && info_code(info) == CLD_KILLED && info_pid(info) == (int)c, msg);

    unsigned char ru[144];
    c = fork();
    if (c == 0) { spin_ms(250); _exit(3); }
    memset(ru, 0x5a, sizeof ru);
    r = widr(P_PID, c, info, WEXITED | WNOHANG, ru);
    check(r == 0 && all_byte(ru, sizeof ru, 0x5a), "E: WNOHANG with nothing to report leaves the rusage untouched");
    memset(ru, 0x5a, sizeof ru);
    r = widr(P_PID, c, info, WEXITED | WNOWAIT, ru);
    snprintf(msg, sizeof msg, "E: WNOWAIT fills the rusage with the child's CPU time (%ld, %ld ms)", r, ru_cpu_ms(ru));
    check(r == 0 && ru_cpu_ms(ru) >= 100 && ru[140] == 0, msg);
    memset(ru, 0x5a, sizeof ru);
    r = widr(P_PID, c, info, WEXITED, ru);
    snprintf(msg, sizeof msg, "E: the reap fills the rusage too (%ld, status %d, %ld ms)", r, info_status(info), ru_cpu_ms(ru));
    check(r == 0 && info_status(info) == 3 && ru_cpu_ms(ru) >= 100 && ru_cpu_ms(ru) < 5000 && ru[140] == 0, msg);
    c = fork();
    if (c == 0) _exit(0);
    r = widr(P_PID, c, info, WEXITED, (void *)8);
    check(r == -14, "E: an unwritable rusage is EFAULT");
    wid(P_PID, c, info, WEXITED);

    /* F: waitid writes six fields and leaves the rest of the caller's buffer, both when it reports a child and when WNOHANG finds nothing. */
    c = fork();
    if (c == 0) { nap(30000); _exit(0); }
    memset(info, 0xAA, sizeof info);
    r = wid(P_PID, c, info, WEXITED | WNOHANG);
    int kept = 1;
    for (int i = 12; i < 16; i++) if (info[i] != 0xAA) kept = 0;
    for (int i = 28; i < 128; i++) if (info[i] != 0xAA) kept = 0;
    snprintf(msg, sizeof msg, "F: WNOHANG with nothing to report clears the six fields and leaves the rest (%ld, signo %d, kept %d)", r, info_signo(info), kept);
    check(r == 0 && info_signo(info) == 0 && info_code(info) == 0 && info_pid(info) == 0 && info_status(info) == 0 && kept, msg);
    kill(c, 9);
    memset(info, 0xAA, sizeof info);
    r = wid(P_PID, c, info, WEXITED);
    kept = 1;
    for (int i = 12; i < 16; i++) if (info[i] != 0xAA) kept = 0;
    for (int i = 28; i < 128; i++) if (info[i] != 0xAA) kept = 0;
    snprintf(msg, sizeof msg, "F: a reported child fills the six fields and leaves the rest (%ld, code %d, status %d, kept %d)", r, info_code(info), info_status(info), kept);
    check(r == 0 && info_signo(info) == 17 && info_code(info) == CLD_KILLED && info_pid(info) == (int)c && info_status(info) == 9 && kept, msg);

    print(failures == 0 ? "hello285: PASS\n" : "hello285: FAIL\n");
    return failures;
}
