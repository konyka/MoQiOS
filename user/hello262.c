/* hello262: signals sent to a whole process group (kill(-pgid, sig)). Measured on Linux (gcc probes): SIGSTOP stops every member; SIGTERM sent to
 * a stopped group leaves it stopped and acts only after SIGCONT (members die of signal 15); SIGKILL ends a stopped group at once (signal 9);
 * the default SIGTSTP stops sleeping members. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"

#define SIGTSTP_ 20
#define WNOHANG_ 1

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello262:   ok   " : "hello262:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void pause_ms(int ms) {
    struct timespec ts = { 0, (long)ms * 1000000L };
    nanosleep(&ts, (struct timespec *)0);
}

static char state_of(long pid) {
    char path[48], b[512];
    snprintf(path, sizeof path, "/proc/%ld/status", pid);
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return '?';
    long n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return '?';
    b[n] = 0;
    char *s = strstr(b, "State:\t");
    return s ? s[7] : '?';
}

static int wait_letter(long pid, char want) {
    for (int i = 0; i < 200; i++) {
        if (state_of(pid) == want) return 1;
        pause_ms(10);
    }
    return 0;
}

/* A child in process group `pgid` (0 = its own group), blocked in read on a pipe nobody writes. */
static long member(long pgid) {
    int p[2];
    pipe(p);
    long k = fork();
    if (k == 0) {
        setpgid(0, pgid);
        char c;
        read(p[0], &c, 1);
        _exit(0);
    }
    setpgid(k, pgid ? pgid : k);
    return k;
}

/* Waits for `pid` for up to two seconds; returns the signal that ended it, 0 for a normal exit, -1 when it is still there. */
static int ended_by(long pid) {
    int st = 0;
    for (int i = 0; i < 200; i++) {
        long w = waitpid(pid, &st, WNOHANG_);
        if (w == pid) return st & 0x7f;
        pause_ms(10);
    }
    return -1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello262: signals to a process group\n");
    char what[240];

    long a = member(0), b = member(a);
    pause_ms(100);
    snprintf(what, sizeof what, "A: two sleepers share a process group (pgid a %ld, b %ld)", getpgid(a), getpgid(b));
    check(getpgid(a) == a && getpgid(b) == a, what);
    kill(-a, SIGSTOP);
    int sa = wait_letter(a, 'T'), sb = wait_letter(b, 'T');
    snprintf(what, sizeof what, "B: kill(-pgid, SIGSTOP) stops every member (a %d, b %d)", sa, sb);
    check(sa && sb, what);
    kill(-a, SIGTERM);
    pause_ms(200);
    char ca = state_of(a), cb = state_of(b);
    snprintf(what, sizeof what, "C: kill(-pgid, SIGTERM) to a stopped group leaves it stopped (a %c, b %c)", ca, cb);
    check(ca == 'T' && cb == 'T', what);
    kill(-a, SIGCONT);
    int ea = ended_by(a), eb = ended_by(b);
    snprintf(what, sizeof what, "C: after kill(-pgid, SIGCONT) both die of SIGTERM (a %d, b %d)", ea, eb);
    check(ea == SIGTERM && eb == SIGTERM, what);

    long c = member(0), d = member(c);
    pause_ms(100);
    kill(-c, SIGSTOP);
    wait_letter(c, 'T');
    wait_letter(d, 'T');
    kill(-c, SIGKILL);
    int ec = ended_by(c), ed = ended_by(d);
    snprintf(what, sizeof what, "D: kill(-pgid, SIGKILL) ends a stopped group at once (c %d, d %d)", ec, ed);
    check(ec == SIGKILL && ed == SIGKILL, what);

    long e = member(0);
    pause_ms(100);
    kill(-e, SIGTSTP_);
    int se = wait_letter(e, 'T');
    snprintf(what, sizeof what, "E: kill(-pgid, SIGTSTP) stops a sleeping member (%d)", se);
    check(se, what);
    kill(-e, SIGKILL);
    ended_by(e);

    print(failures == 0 ? "hello262: PASS\n" : "hello262: FAIL\n");
    return failures;
}
