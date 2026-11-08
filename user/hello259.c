/* hello259: /proc/<pid>/status. Measured on Linux (gcc probes): the file lists Name, Umask ("%04o"), State, Tgid, Ngid, Pid, PPid, TracerPid,
 * Uid and Gid (real, effective, saved, filesystem: four tab-separated numbers), FDSize, Groups (each group followed by a space), Threads and
 * NoNewPrivs, one "Key:\tvalue" line each. State is R (running) for a running process, S (sleeping) while blocked, T (stopped) after SIGSTOP
 * and Z (zombie) once it exited. A thread's status has its own Pid and the process's Tgid and PPid; Threads counts the live threads of the
 * process. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"

#define SYS_PRCTL 241
#define PR_SET_NO_NEW_PRIVS 38
#define SYS_SETGROUPS 488

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello259:   ok   " : "hello259:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void pause_ms(int ms) {
    struct timespec ts = { 0, (long)ms * 1000000L };
    nanosleep(&ts, (struct timespec *)0);
}

/* The text after "Key:\t" up to the newline, copied to out; 0 when the line is missing. */
static int field_of(const char *file, const char *key, char *out, size_t cap) {
    static char text[4096];
    int fd = (int)open(file, O_RDONLY, 0);
    if (fd < 0) return 0;
    long n = read(fd, text, sizeof text - 1);
    close(fd);
    if (n <= 0) return 0;
    text[n] = 0;
    char want[40];
    snprintf(want, sizeof want, "%s:\t", key);
    size_t kl = strlen(want);
    for (char *line = text; *line;) {
        char *end = strchr(line, '\n');
        size_t len = end ? (size_t)(end - line) : strlen(line);
        if (len >= kl && strncmp(line, want, kl) == 0) {
            size_t vl = len - kl;
            if (vl >= cap) vl = cap - 1;
            memcpy(out, line + kl, vl);
            out[vl] = 0;
            return 1;
        }
        if (!end) break;
        line = end + 1;
    }
    return 0;
}

static long num_of(const char *file, const char *key) {
    char v[128];
    if (!field_of(file, key, v, sizeof v)) return -1;
    return atol(v);
}

/* Polls the State line of /proc/<pid>/status until it starts with `want`, for up to about two seconds. */
static int wait_state(long pid, const char *want) {
    char path[48], v[64];
    snprintf(path, sizeof path, "/proc/%ld/status", pid);
    for (int i = 0; i < 200; i++) {
        if (field_of(path, "State", v, sizeof v) && strncmp(v, want, strlen(want)) == 0) return 1;
        pause_ms(10);
    }
    return 0;
}

static int up[2], down[2];
static volatile long thread_tid;

static void *thread_main(void *arg) {
    (void)arg;
    thread_tid = syscall0(SYS_gettid);
    char c = 1;
    write(up[1], &c, 1);
    read(down[0], &c, 1);
    return (void *)0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello259: /proc/<pid>/status\n");
    char what[240], v[200];
    const char *self = "/proc/self/status";
    long me = getpid();

    check(field_of(self, "Name", v, sizeof v) && strcmp(v, "hello259") == 0, "Name is the program's name");
    snprintf(what, sizeof what, "Tgid, Pid and PPid are getpid(), getpid() and getppid() (%ld %ld %ld)", num_of(self, "Tgid"), num_of(self, "Pid"), num_of(self, "PPid"));
    check(num_of(self, "Tgid") == me && num_of(self, "Pid") == me && num_of(self, "PPid") == getppid(), what);
    check(field_of(self, "Ngid", v, sizeof v) && strcmp(v, "0") == 0, "Ngid is 0");
    check(field_of(self, "TracerPid", v, sizeof v) && strcmp(v, "0") == 0, "TracerPid is 0 (nobody traces this process)");
    check(field_of(self, "State", v, sizeof v) && strcmp(v, "R (running)") == 0, "a process reading its own status is R (running)");

    umask(027);
    check(field_of(self, "Umask", v, sizeof v) && strcmp(v, "0027") == 0, "Umask is the octal mask, four digits (after umask(027))");
    umask(022);
    check(field_of(self, "Umask", v, sizeof v) && strcmp(v, "0022") == 0, "and follows the next umask call");

    char want[80];
    snprintf(want, sizeof want, "%u\t%u\t%u\t%u", getuid(), geteuid(), getuid(), geteuid());
    snprintf(what, sizeof what, "Uid is real, effective, saved, filesystem (got \"%s\", want \"%s\")", field_of(self, "Uid", v, sizeof v) ? v : "(missing)", want);
    check(field_of(self, "Uid", v, sizeof v) && strcmp(v, want) == 0, what);
    snprintf(want, sizeof want, "%u\t%u\t%u\t%u", getgid(), getegid(), getgid(), getegid());
    snprintf(what, sizeof what, "Gid likewise (got \"%s\", want \"%s\")", field_of(self, "Gid", v, sizeof v) ? v : "(missing)", want);
    check(field_of(self, "Gid", v, sizeof v) && strcmp(v, want) == 0, what);

    long fdsize = num_of(self, "FDSize");
    int hi = (int)open("/proc/self/status", O_RDONLY, 0);
    snprintf(what, sizeof what, "FDSize covers the highest open descriptor (FDSize %ld, highest %d)", fdsize, hi);
    check(fdsize > hi && hi >= 0, what);
    if (hi >= 0) close(hi);

    check(num_of(self, "NoNewPrivs") == 0, "NoNewPrivs starts at 0");
    long nnp_child = fork();
    if (nnp_child == 0) {
        syscall5(SYS_PRCTL, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
        _exit(num_of(self, "NoNewPrivs") == 1 ? 0 : 1);
    }
    int st = 0;
    waitpid(nnp_child, &st, 0);
    check(((st >> 8) & 0xff) == 0 && (st & 0x7f) == 0, "and is 1 after prctl(PR_SET_NO_NEW_PRIVS)");
    check(num_of(self, "NoNewPrivs") == 0, "in the child only: the parent's stays 0");

    /* Supplementary groups, listed in the order set, each followed by a space. */
    int gp[2];
    pipe(gp);
    long gk = fork();
    if (gk == 0) {
        unsigned int list[3] = { 5, 7, 9 };
        long r = syscall2(SYS_SETGROUPS, 3, (long)list);
        char got[160];
        got[0] = 0;
        int ok = r == 0 && field_of(self, "Groups", got, sizeof got);
        char out[160];
        snprintf(out, sizeof out, "%d|%s", ok, got);
        write(gp[1], out, strlen(out) + 1);
        _exit(0);
    }
    char gtext[160];
    memset(gtext, 0, sizeof gtext);
    read(gp[0], gtext, sizeof gtext - 1);
    waitpid(gk, &st, 0);
    snprintf(what, sizeof what, "Groups lists each group followed by a space after setgroups(5, 7, 9) (got \"%s\")", gtext);
    check(strcmp(gtext, "1|5 7 9 ") == 0, what);

    /* Threads: the process's count, and a thread's own status. */
    check(num_of(self, "Threads") == 1, "Threads is 1 for a process with no other thread");
    pipe(up);
    pipe(down);
    pthread_t th;
    int made = pthread_create(&th, (void *)0, thread_main, (void *)0) == 0;
    char c;
    if (made) read(up[0], &c, 1);
    snprintf(what, sizeof what, "Threads is 2 while another thread is alive (%ld)", num_of(self, "Threads"));
    check(made && num_of(self, "Threads") == 2, what);
    char tpath[48];
    snprintf(tpath, sizeof tpath, "/proc/%ld/status", (long)thread_tid);
    snprintf(what, sizeof what, "a thread's own status: Pid %ld is its tid, Tgid %ld the process, PPid %ld the process's parent, Threads %ld",
             num_of(tpath, "Pid"), num_of(tpath, "Tgid"), num_of(tpath, "PPid"), num_of(tpath, "Threads"));
    check(made && thread_tid != me && num_of(tpath, "Pid") == thread_tid && num_of(tpath, "Tgid") == me && num_of(tpath, "PPid") == getppid() &&
              num_of(tpath, "Threads") == 2, what);
    if (made) {
        write(down[1], &c, 1);
        pthread_join(th, (void **)0);
    }
    int back = 0;
    for (int i = 0; i < 200 && !back; i++) {
        back = num_of(self, "Threads") == 1;
        if (!back) pause_ms(10);
    }
    check(back, "Threads is 1 again after the thread has exited and been joined");

    /* State of another process: sleeping, stopped, running again, then zombie. */
    int sync[2];
    pipe(sync);
    long kid = fork();
    if (kid == 0) {
        char b;
        read(sync[0], &b, 1);
        _exit(0);
    }
    check(wait_state(kid, "S (sleeping)"), "a process blocked in read is S (sleeping)");
    kill(kid, SIGSTOP);
    check(wait_state(kid, "T (stopped)"), "after SIGSTOP it is T (stopped)");
    kill(kid, SIGCONT);
    check(wait_state(kid, "S (sleeping)"), "after SIGCONT it is S (sleeping) again");
    char kpath[48];
    snprintf(kpath, sizeof kpath, "/proc/%ld/status", kid);
    snprintf(what, sizeof what, "its PPid is this process (%ld) and its Tgid is its own pid", num_of(kpath, "PPid"));
    check(num_of(kpath, "PPid") == me && num_of(kpath, "Tgid") == kid && num_of(kpath, "Pid") == kid, what);
    write(sync[1], "x", 1);
    check(wait_state(kid, "Z (zombie)"), "once it has exited and not been waited for, it is Z (zombie)");
    waitpid(kid, &st, 0);

    /* A sleeper that is stopped and continued still sleeps its full time (Linux: the deadline keeps running; nanosleep returns 0), and once
     * continued it keeps running: the stop signal must not be left pending to stop it a second time. The child computes for 300 ms after the
     * sleep; the parent waits at most three seconds for its report. */
    int np[2];
    pipe2(np, O_NONBLOCK);
    long sk = fork();
    if (sk == 0) {
        struct timespec t0, t1, ts = { 0, 600 * 1000000L };
        clock_gettime(1, &t0);
        long r = nanosleep(&ts, (struct timespec *)0);
        clock_gettime(1, &t1);
        long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
        struct timespec c0, c1;
        clock_gettime(1, &c0);
        do {
            clock_gettime(1, &c1);
        } while ((c1.tv_sec - c0.tv_sec) * 1000 + (c1.tv_nsec - c0.tv_nsec) / 1000000 < 300);
        char out[48];
        snprintf(out, sizeof out, "%ld %ld", r, ms);
        write(np[1], out, strlen(out) + 1);
        _exit(0);
    }
    pause_ms(100);
    kill(sk, SIGSTOP);
    int stopped = wait_state(sk, "T (stopped)");
    pause_ms(100);
    kill(sk, SIGCONT);
    char slept[48];
    memset(slept, 0, sizeof slept);
    int got = 0;
    for (int i = 0; i < 300 && !got; i++) {
        got = read(np[0], slept, sizeof slept - 1) > 0;
        if (!got) pause_ms(10);
    }
    if (!got) kill(sk, SIGKILL);
    waitpid(sk, &st, 0);
    long srv = -99, sms = -1;
    sscanf(slept, "%ld %ld", &srv, &sms);
    snprintf(what, sizeof what, "a sleeper stopped and continued still sleeps its 600 ms (stopped %d, rc %ld, %ld ms)", stopped, srv, sms);
    check(stopped && srv == 0 && sms >= 590, what);
    check(got, "and keeps running after the continue: it was not stopped a second time");

    /* A process that is computing (never blocked) stops too, and stays stopped until SIGCONT: it must make no progress while stopped. */
    int bp[2];
    pipe2(bp, O_NONBLOCK);
    long bk = fork();
    if (bk == 0) {
        volatile unsigned long spin = 0;
        for (;;) {
            spin++;
            if ((spin & 0xFFFFF) == 0) write(bp[1], "t", 1);
        }
    }
    char tick[64];
    int started = 0;
    for (int i = 0; i < 300 && !started; i++) {
        started = read(bp[0], tick, sizeof tick) > 0;
        if (!started) pause_ms(10);
    }
    kill(bk, SIGSTOP);
    int bstopped = wait_state(bk, "T (stopped)");
    /* A process running on another CPU is marked stopped at once but only leaves its CPU at that CPU's next scheduler tick, so it may still tick the
     * pipe for a moment after status says T (seen once in six runs at SMP=8). Let that tick pass, drain, and only then require silence. */
    pause_ms(120);
    while (read(bp[0], tick, sizeof tick) > 0) {}
    pause_ms(300);
    int progress = read(bp[0], tick, sizeof tick) > 0;
    kill(bk, SIGCONT);
    int resumed = 0;
    for (int i = 0; i < 300 && !resumed; i++) {
        resumed = read(bp[0], tick, sizeof tick) > 0;
        if (!resumed) pause_ms(10);
    }
    kill(bk, SIGKILL);
    waitpid(bk, &st, 0);
    snprintf(what, sizeof what, "a computing process: SIGSTOP shows T (started %d, stopped %d)", started, bstopped);
    check(started && bstopped, what);
    check(!progress, "and it makes no progress while stopped");
    check(resumed, "and runs again after SIGCONT");

    print(failures == 0 ? "hello259: PASS\n" : "hello259: FAIL\n");
    return failures;
}
