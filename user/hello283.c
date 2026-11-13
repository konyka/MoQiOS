/// hello283: orphaned process groups (POSIX; Linux kill_orphaned_pgrp). Measured on the host (/tmp/lm/orph.c, orph2.c): when an exit leaves
/// a process group with no member whose parent is in another group of the same session, and the group has a stopped member, every member
/// gets SIGHUP then SIGCONT. Nothing is sent when the group has no stopped member, when another member still links it to the session,
/// or when the stopped child sits in its exiting session leader's own group (that group was never linked from inside the session).
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"

static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello283:   ok   " : "hello283:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static int report_fd;
static void on_hup(int s) { (void)s; char h = 'H'; write(report_fd, &h, 1); }
static void on_cont(int s) { (void)s; char c = 'C'; write(report_fd, &c, 1); }
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

/* Whether /proc/<pid>/stat reports state T: "pid (comm) T ...". */
static int is_stopped(long pid) {
    char path[32], b[128];
    snprintf(path, sizeof path, "/proc/%ld/stat", pid);
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return 0;
    long n = read(fd, b, sizeof b - 1);
    close(fd);
    if (n <= 0) return 0;
    b[n] = 0;
    char *p = strrchr(b, ')');
    return p && p[1] == ' ' && p[2] == 'T';
}

enum { D_SETSID_C_OWN_GROUP = 6, D_SETSID_C_SAME_GROUP = 7, D_OWN_GROUP = 2, C_OWN_GROUP = 3, NOT_STOPPED = 4, STILL_LINKED = 5 };

/* D forks C; C reports "R" and (except NOT_STOPPED) stops itself; D waits for "R", gives C time to stop, and exits. Returns what C saw. */
static void scenario(int mode, char *seen, int seen_len) {
    int rep[2], rdy[2], go[2];
    pipe(rep);
    pipe(rdy);
    pipe(go);
    long e = -1;
    long d = fork();
    if (d == 0) {
        if (mode == D_SETSID_C_OWN_GROUP || mode == D_SETSID_C_SAME_GROUP) setsid();
        else if (mode != C_OWN_GROUP) setpgid(0, 0);
        long c = fork();
        if (c == 0) {
            close(rep[0]);
            report_fd = rep[1];
            signal(SIGHUP, on_hup);
            signal(SIGCONT, on_cont);
            if (mode == C_OWN_GROUP || mode == D_SETSID_C_OWN_GROUP) setpgid(0, 0);
            char r = 'R';
            write(rdy[1], &r, 1);
            if (mode != NOT_STOPPED) kill(getpid(), SIGSTOP);
            for (int i = 0; i < 150; i++) nap(10);
            _exit(0);
        }
        char r = 0;
        for (int i = 0; i < 400 && read(rdy[0], &r, 1) != 1; i++) nap(5);
        if (mode == NOT_STOPPED) nap(150);
        else for (int i = 0; i < 400 && !is_stopped(c); i++) nap(5);
        /* STILL_LINKED: E must be in this group before D exits, or the group is orphaned after all (a loaded VM once let D exit
         * first and the stopped child got SIGHUP and SIGCONT). The parent writes `go` once getpgid(E) is D. */
        if (mode == STILL_LINKED) {
            char g = 0;
            read(go[0], &g, 1);
        }
        _exit(0);
    }
    if (mode == STILL_LINKED) {
        e = fork();
        if (e == 0) {
            for (int i = 0; i < 400 && getpgid(d) != d; i++) nap(5);
            setpgid(0, d);
            for (int i = 0; i < 300; i++) nap(10);
            _exit(0);
        }
        for (int i = 0; i < 400 && getpgid(e) != d; i++) nap(5);
    }
    char g = 'g';
    write(go[1], &g, 1);
    close(rep[1]);
    int st = 0;
    waitpid(d, &st, 0);
    fcntl(rep[0], F_SETFL, O_NONBLOCK);
    int n = 0;
    for (int i = 0; i < 80 && n < 2; i++) {
        long k = read(rep[0], seen + n, seen_len - 1 - n);
        if (k > 0) n += (int)k;
        else nap(10);
    }
    seen[n] = 0;
    close(rep[0]);
    close(rdy[0]);
    close(rdy[1]);
    close(go[0]);
    close(go[1]);
    if (e > 0) {
        kill(e, SIGKILL);
        waitpid(e, &st, 0);
    }
}

/* Linux sets up every pending handler frame at once (SIGHUP's first, SIGCONT's on top), so its handlers run as "CH"; this kernel sets up
 * one frame per return to user space and runs them as "HC". Only which signals arrived is compared, not their nesting order. */
static int same_set(const char *a, const char *b) {
    int ha = strchr(a, 'H') != 0, ca = strchr(a, 'C') != 0, hb = strchr(b, 'H') != 0, cb = strchr(b, 'C') != 0;
    return strlen(a) == strlen(b) && ha == hb && ca == cb;
}

static void expect(int mode, const char *want, const char *what) {
    char seen[8];
    scenario(mode, seen, sizeof seen);
    snprintf(msg, sizeof msg, "%s: the stopped child saw \"%s\" (Linux: \"%s\")", what, seen, want);
    check(same_set(seen, want), msg);
}

int main(void) {
    setsid();
    expect(D_OWN_GROUP, "CH", "own group of the exiting link, stopped member");
    expect(C_OWN_GROUP, "CH", "child's own group whose parent was the link");
    expect(D_SETSID_C_OWN_GROUP, "CH", "own group inside an exiting session leader's session");
    expect(NOT_STOPPED, "", "orphaned group without a stopped member");
    expect(STILL_LINKED, "", "group still linked by another member");
    expect(D_SETSID_C_SAME_GROUP, "", "stopped child in the session leader's own group");
    print(failures == 0 ? "hello283: PASS\n" : "hello283: FAIL\n");
    return failures;
}
