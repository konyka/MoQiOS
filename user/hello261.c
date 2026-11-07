/* hello261: stop signals against sleeping processes, and fatal or handled signals against stopped ones. Measured on Linux (gcc probes):
 *  - a stop signal (SIGTSTP) with a handler runs the handler, the blocked read gets EINTR, and the process is never stopped;
 *  - a blocked SIGTSTP or an ignored one leaves a sleeper sleeping (S);
 *  - SIGTERM sent to a STOPPED process leaves it stopped (T): the signal stays pending and acts only after SIGCONT (default action: the process
 *    dies of signal 15; with a handler: the handler runs then and the interrupted read gets EINTR);
 *  - SIGKILL is the exception: it ends a stopped process at once. */
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

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello261:   ok   " : "hello261:   FAIL ");
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

/* Waits up to two seconds for the state letter. */
static int wait_letter(long pid, char want) {
    for (int i = 0; i < 200; i++) {
        if (state_of(pid) == want) return 1;
        pause_ms(10);
    }
    return 0;
}

static volatile int got_signal;
static void on_signal(int s) { got_signal = s; }

enum mode { M_DEFAULT, M_TSTP_HANDLER, M_TSTP_BLOCKED, M_TSTP_IGNORED, M_TERM_HANDLER };

struct sleeper { long pid; int report; int release; };

/* A child that blocks in read(); on return it writes "<result> <errno> <signal seen by the handler>" to the report pipe. This libc's read() returns
 * the negative errno itself (-EINTR), so the result alone says what happened. */
static struct sleeper spawn(enum mode m) {
    int rep[2], rel[2];
    pipe2(rep, O_NONBLOCK);
    pipe(rel);
    long k = fork();
    if (k == 0) {
        if (m == M_TSTP_HANDLER || m == M_TERM_HANDLER) {
            struct ksigaction a;
            memset(&a, 0, sizeof a);
            a.handler = on_signal;
            sigaction(m == M_TSTP_HANDLER ? SIGTSTP_ : SIGTERM, &a, (struct ksigaction *)0);
        }
        if (m == M_TSTP_BLOCKED) {
            sigset_t mask;
            sigemptyset(&mask);
            sigaddset(&mask, SIGTSTP_);
            sigprocmask(SIG_BLOCK, &mask, (sigset_t *)0);
        }
        if (m == M_TSTP_IGNORED) signal(SIGTSTP_, SIG_IGN);
        char c;
        long n = read(rel[0], &c, 1);
        int e = errno;
        char out[48];
        snprintf(out, sizeof out, "%ld %d %d", n, n < 0 ? e : 0, (int)got_signal);
        write(rep[1], out, strlen(out) + 1);
        _exit(0);
    }
    struct sleeper s = { k, rep[0], rel[1] };
    pause_ms(100);
    return s;
}

static int reported(struct sleeper s, long *n, long *err, long *sig) {
    char b[64];
    memset(b, 0, sizeof b);
    int got = 0;
    for (int i = 0; i < 200 && !got; i++) {
        got = read(s.report, b, sizeof b - 1) > 0;
        if (!got) pause_ms(10);
    }
    if (!got) return 0;
    sscanf(b, "%ld %ld %ld", n, err, sig);
    return 1;
}

static void reap(long pid) {
    kill(pid, SIGKILL);
    int st;
    waitpid(pid, &st, 0);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello261: stop and fatal signals against sleeping and stopped processes\n");
    char what[240];
    int st = 0;
    long n = -9, err = -9, sig = -9;

    struct sleeper a = spawn(M_TSTP_HANDLER);
    kill(a.pid, SIGTSTP_);
    int got = reported(a, &n, &err, &sig);
    snprintf(what, sizeof what, "A: SIGTSTP with a handler runs it and the read gets EINTR (got %d, n %ld, errno %ld, handler saw %ld)", got, n, err, sig);
    check(got && n == -EINTR && sig == SIGTSTP_, what);
    waitpid(a.pid, &st, 0);

    struct sleeper b = spawn(M_TSTP_BLOCKED);
    kill(b.pid, SIGTSTP_);
    pause_ms(200);
    char sb = state_of(b.pid);
    snprintf(what, sizeof what, "B: SIGTSTP while blocked leaves the sleeper sleeping (state %c)", sb);
    check(sb == 'S', what);
    reap(b.pid);

    struct sleeper c = spawn(M_TSTP_IGNORED);
    kill(c.pid, SIGTSTP_);
    pause_ms(200);
    char sc = state_of(c.pid);
    snprintf(what, sizeof what, "C: SIGTSTP while ignored leaves the sleeper sleeping (state %c)", sc);
    check(sc == 'S', what);
    reap(c.pid);

    /* SIGTERM to a stopped process with the default action: it stays stopped, dies of SIGTERM after SIGCONT. */
    struct sleeper d = spawn(M_DEFAULT);
    kill(d.pid, SIGSTOP);
    int d_stopped = wait_letter(d.pid, 'T');
    kill(d.pid, SIGTERM);
    pause_ms(200);
    char sd = state_of(d.pid);
    snprintf(what, sizeof what, "D: SIGTERM sent to a stopped process leaves it stopped (stopped %d, state after %c)", d_stopped, sd);
    check(d_stopped && sd == 'T', what);
    kill(d.pid, SIGCONT);
    long w = waitpid(d.pid, &st, 0);
    snprintf(what, sizeof what, "D: after SIGCONT it dies of SIGTERM (waitpid %ld, signaled %d, signal %d)", w, (st & 0x7f) != 0, st & 0x7f);
    check(w == d.pid && (st & 0x7f) == SIGTERM, what);

    /* SIGKILL ends a stopped process at once. */
    struct sleeper e = spawn(M_DEFAULT);
    kill(e.pid, SIGSTOP);
    wait_letter(e.pid, 'T');
    kill(e.pid, SIGKILL);
    long we = waitpid(e.pid, &st, 0);
    snprintf(what, sizeof what, "E: SIGKILL ends a stopped process at once (waitpid %ld, signal %d)", we, st & 0x7f);
    check(we == e.pid && (st & 0x7f) == SIGKILL, what);

    /* SIGTERM with a handler to a stopped process: stays stopped; the handler runs after SIGCONT and the read gets EINTR. */
    struct sleeper f = spawn(M_TERM_HANDLER);
    kill(f.pid, SIGSTOP);
    int f_stopped = wait_letter(f.pid, 'T');
    kill(f.pid, SIGTERM);
    pause_ms(200);
    char sf = state_of(f.pid);
    long fn = -9, ferr = -9, fsig = -9;
    int early = reported(f, &fn, &ferr, &fsig);
    snprintf(what, sizeof what, "F: SIGTERM with a handler sent to a stopped process: still stopped, handler not run yet (stopped %d, state %c, early report %d)", f_stopped, sf, early);
    check(f_stopped && sf == 'T' && !early, what);
    kill(f.pid, SIGCONT);
    int late = reported(f, &fn, &ferr, &fsig);
    snprintf(what, sizeof what, "F: after SIGCONT the handler runs and the read gets EINTR (got %d, n %ld, errno %ld, handler saw %ld)", late, fn, ferr, fsig);
    check(late && fn == -EINTR && fsig == SIGTERM, what);
    waitpid(f.pid, &st, 0);

    print(failures == 0 ? "hello261: PASS\n" : "hello261: FAIL\n");
    return failures;
}
