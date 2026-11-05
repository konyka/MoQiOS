/* hello229: SA_RESTART on the real kernel. A blocking read or waitpid that a signal handler interrupts returns -EINTR when the
 * handler was installed without SA_RESTART, and is transparently restarted (and then completes normally) when it was installed
 * with it. Sleeps, pause and sigsuspend are never restarted, whatever the flag. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"

#define SA_RESTART_BIT 0x10000000UL

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello229:   ok   " : "hello229:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile int hits;
static void on_usr1(int s) { (void)s; hits++; }

static void install(unsigned long flags) {
    struct ksigaction act = { on_usr1, flags, (void *)0, 0 };
    sigaction(SIGUSR1, &act, (struct ksigaction *)0);
    hits = 0;
}

static void pause_ms(long ms) {
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {}
}

/* Child that signals its parent after 60 ms and, when data is given, writes it 60 ms later; then exits with `code`. */
static long spawn_signaller(long parent, int wfd, const char *data, int code) {
    long pid = fork();
    if (pid == 0) {
        pause_ms(60);
        kill(parent, SIGUSR1);
        if (data) {
            pause_ms(60);
            write(wfd, data, strlen(data));
        }
        pause_ms(30);
        _exit(code);
    }
    return pid;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello229: SA_RESTART\n");
    long me = getpid();
    char buf[16];
    int p[2];

    /* A: read on an empty pipe */
    install(0);
    pipe(p);
    long kid = spawn_signaller(me, p[1], "hi", 0);
    long r = read(p[0], buf, sizeof buf);
    check(r == -EINTR && hits == 1, "A: without SA_RESTART a blocked read returns -EINTR after the handler ran");
    if (r == -EINTR) {
        r = read(p[0], buf, sizeof buf);
        check(r == 2 && buf[0] == 'h', "A: and the data is still there for the next read");
    } else {
        check(0, "A: and the data is still there for the next read (skipped: the first read was not interrupted)");
    }
    waitpid(kid, (int *)0, 0);
    close(p[0]);
    close(p[1]);

    install(SA_RESTART_BIT);
    pipe(p);
    kid = spawn_signaller(me, p[1], "hey", 0);
    r = read(p[0], buf, sizeof buf);
    check(r == 3 && buf[0] == 'h' && hits == 1, "A: with SA_RESTART the same read waits through the handler and returns the data (3 bytes, handler ran once)");
    waitpid(kid, (int *)0, 0);
    close(p[0]);
    close(p[1]);

    /* B: waitpid */
    install(0);
    kid = spawn_signaller(me, -1, (const char *)0, 7);
    int st = -1;
    r = waitpid(kid, &st, 0);
    check(r == -EINTR && hits == 1, "B: without SA_RESTART a blocked waitpid returns -EINTR");
    st = -1;
    if (r == -EINTR) r = waitpid(kid, &st, 0);
    check(r == kid && ((st >> 8) & 0xff) == 7, "B: and the child's status is still collectable");

    install(SA_RESTART_BIT);
    kid = spawn_signaller(me, -1, (const char *)0, 9);
    st = -1;
    r = waitpid(kid, &st, 0);
    check(r == kid && ((st >> 8) & 0xff) == 9 && hits == 1, "B: with SA_RESTART waitpid waits through the handler and returns the child (status 9, handler ran once)");

    /* C: sleeping is not restarted, flag or not */
    install(SA_RESTART_BIT);
    kid = spawn_signaller(me, -1, (const char *)0, 0);
    struct timespec ts = { 1, 0 };
    errno = 0;
    int nr = nanosleep(&ts, (struct timespec *)0);
    check(nr == -1 && errno == EINTR && hits == 1, "C: nanosleep is interrupted even with SA_RESTART");
    waitpid(kid, (int *)0, 0);

    /* D: a signal with no handler work to do (ignored) does not disturb a blocked read at all */
    install(SA_RESTART_BIT);
    pipe(p);
    signal(SIGUSR2, SIG_IGN);
    long k2 = fork();
    if (k2 == 0) {
        pause_ms(50);
        kill(me, SIGUSR2);
        pause_ms(50);
        write(p[1], "z", 1);
        _exit(0);
    }
    r = read(p[0], buf, sizeof buf);
    check(r == 1 && buf[0] == 'z' && hits == 0, "D: an ignored signal does not interrupt a blocked read");
    waitpid(k2, (int *)0, 0);
    close(p[0]);
    close(p[1]);

    print(failures == 0 ? "hello229: PASS\n" : "hello229: FAIL\n");
    return failures;
}
