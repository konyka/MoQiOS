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

    /* E: the other blocking calls that restart: readv on a pipe, wait4, and recvfrom on a socket. */
    struct iovec_ { void *base; unsigned long len; };
    install(0);
    pipe(p);
    kid = spawn_signaller(me, p[1], "ab", 0);
    struct iovec_ iov = { buf, sizeof buf };
    r = syscall3(19 /* readv */, p[0], (long)&iov, 1);
    check(r == -EINTR && hits == 1, "E: without SA_RESTART a blocked readv returns -EINTR");
    if (r == -EINTR) r = syscall3(19, p[0], (long)&iov, 1);
    waitpid(kid, (int *)0, 0);
    close(p[0]);
    close(p[1]);
    install(SA_RESTART_BIT);
    pipe(p);
    kid = spawn_signaller(me, p[1], "abc", 0);
    iov.base = buf;
    iov.len = sizeof buf;
    r = syscall3(19, p[0], (long)&iov, 1);
    check(r == 3 && hits == 1, "E: with SA_RESTART readv waits through the handler and returns the data (3 bytes)");
    waitpid(kid, (int *)0, 0);
    close(p[0]);
    close(p[1]);

    install(SA_RESTART_BIT);
    kid = spawn_signaller(me, -1, (const char *)0, 5);
    st = -1;
    r = syscall4(61 /* wait4 */, kid, (long)&st, 0, 0);
    check(r == kid && ((st >> 8) & 0xff) == 5 && hits == 1, "E: with SA_RESTART wait4 waits through the handler and returns the child (status 5)");
    install(0);
    kid = spawn_signaller(me, -1, (const char *)0, 6);
    r = syscall4(61, kid, (long)&st, 0, 0);
    check(r == -EINTR && hits == 1, "E: without SA_RESTART a blocked wait4 returns -EINTR");
    waitpid(kid, (int *)0, 0);

    int sv[2];
    install(0);
    long sr = syscall4(128 /* socketpair */, 1 /* AF_UNIX */, 1 /* SOCK_STREAM */, 0, (long)sv);
    check(sr == 0, "E: socketpair for the socket cases");
    if (sr == 0) {
        kid = spawn_signaller(me, sv[1], "sock", 0);
        r = syscall6(45 /* recvfrom */, sv[0], (long)buf, sizeof buf, 0, 0, 0);
        check(r == -EINTR && hits == 1, "E: without SA_RESTART a blocked recvfrom returns -EINTR");
        if (r == -EINTR) syscall6(45, sv[0], (long)buf, sizeof buf, 0, 0, 0);
        waitpid(kid, (int *)0, 0);
        install(SA_RESTART_BIT);
        kid = spawn_signaller(me, sv[1], "sock", 0);
        r = syscall6(45, sv[0], (long)buf, sizeof buf, 0, 0, 0);
        check(r == 4 && buf[0] == 's' && hits == 1, "E: with SA_RESTART recvfrom waits through the handler and returns the data (4 bytes)");
        waitpid(kid, (int *)0, 0);
        close(sv[0]);
        close(sv[1]);
    }

    /* F: a blocking write to a full pipe waits for room (pipe capacity is 4095 bytes). */
    static char big[10000];
    for (int i = 0; i < 10000; i++) big[i] = (char)(i % 251);
    install(0);
    signal(SIGPIPE, SIG_IGN);

    /* F1: 10000 bytes through a 4095-byte pipe to a slow reader arrive complete and in order. */
    pipe(p);
    kid = fork();
    if (kid == 0) {
        close(p[1]);
        pause_ms(100);
        long total = 0;
        int ok = 1;
        for (;;) {
            char rb[512];
            long n = read(p[0], rb, sizeof rb);
            if (n <= 0) break;
            for (long i = 0; i < n; i++) if (rb[i] != (char)((total + i) % 251)) ok = 0;
            total += n;
        }
        _exit(ok && total == 10000 ? 0 : 1);
    }
    close(p[0]);
    r = write(p[1], big, 10000);
    close(p[1]);
    st = -1;
    waitpid(kid, &st, 0);
    check(r == 10000, "F: a blocking write of 10000 bytes to a pipe that holds 4095 returns 10000");
    check(((st >> 8) & 0xff) == 0 && (st & 0x7f) == 0, "F: and the slow reader got all 10000 bytes in order");

    /* F2: a full pipe: a non-blocking write says EAGAIN; a blocking one waits, is interrupted by a handler without SA_RESTART
     * (EINTR), and runs on to completion with SA_RESTART once the reader makes room. */
    pipe(p);
    r = write(p[1], big, 4095);
    check(r == 4095, "F: the pipe takes 4095 bytes");
    long fl = syscall3(142 /* fcntl */, p[1], 3 /* F_GETFL */, 0);
    syscall3(142, p[1], 4 /* F_SETFL */, fl | 0x800 /* O_NONBLOCK */);
    r = write(p[1], big, 10);
    check(r == -EAGAIN, "F: a non-blocking write to a full pipe is -EAGAIN");
    syscall3(142, p[1], 4, fl);

    kid = spawn_signaller(me, -1, (const char *)0, 0);
    r = write(p[1], big, 10);
    check(r == -EINTR && hits == 1, "F: a blocking write to a full pipe is interrupted by a handler (EINTR, nothing written)");
    waitpid(kid, (int *)0, 0);

    install(SA_RESTART_BIT);
    kid = fork();
    if (kid == 0) {
        pause_ms(60);
        kill(me, SIGUSR1);
        pause_ms(60);
        char rb[5000];
        long n = read(p[0], rb, sizeof rb);
        _exit(n == 4095 ? 0 : 1);
    }
    r = write(p[1], big, 10);
    check(r == 10 && hits == 1, "F: with SA_RESTART the blocked write waits through the handler and completes when the reader makes room");
    st = -1;
    waitpid(kid, &st, 0);
    check(((st >> 8) & 0xff) == 0, "F: and the reader saw the 4095 bytes first");
    close(p[0]);
    close(p[1]);

    /* F3: the reader goes away while the writer waits: EPIPE (SIGPIPE is ignored here). */
    install(0);
    pipe(p);
    r = write(p[1], big, 4095);
    kid = fork();
    if (kid == 0) {
        pause_ms(80);
        close(p[0]);
        _exit(0);
    }
    close(p[0]);
    r = write(p[1], big, 10);
    check(r == -32 /* EPIPE */, "F: a writer waiting on a full pipe whose last reader closes gets EPIPE");
    waitpid(kid, (int *)0, 0);
    close(p[1]);

    /* G: a write of up to the pipe's capacity (4095 bytes) is atomic: it goes in whole or not at all, and while a writer waits for
     * room nothing of its data is in the pipe for another writer's bytes to be mixed into. */
    install(0);
    pipe(p);
    memset(big, 'F', 2000);
    r = write(p[1], big, 2000);
    long fl2 = syscall3(142, p[1], 3, 0);
    syscall3(142, p[1], 4, fl2 | 0x800);
    memset(big, 'N', 3000);
    r = write(p[1], big, 3000);
    check(r == -EAGAIN, "G: a non-blocking write that does not fit whole is -EAGAIN (nothing written)");
    syscall3(142, p[1], 4, fl2);
    kid = fork();
    if (kid == 0) {
        static char bb[3000];
        memset(bb, 'B', sizeof bb);
        write(p[1], bb, sizeof bb);
        _exit(0);
    }
    pause_ms(80);
    syscall3(142, p[1], 4, fl2 | 0x800);
    memset(big, 'C', 100);
    r = write(p[1], big, 100);
    check(r == 100, "G: a small write goes in while a big one waits for room (the waiting writer left no partial data behind)");
    syscall3(142, p[1], 4, fl2);
    static char got[6000];
    long have = 0;
    while (have < 2100) {
        long n = read(p[0], got + have, 2100 - have);
        if (n <= 0) break;
        have += n;
    }
    int first_ok = have == 2100;
    for (int i = 0; i < 2000 && first_ok; i++) if (got[i] != 'F') first_ok = 0;
    for (int i = 2000; i < 2100 && first_ok; i++) if (got[i] != 'C') first_ok = 0;
    check(first_ok, "G: the pipe held the 2000 filler bytes and then the 100 small-write bytes");
    have = 0;
    while (have < 3000) {
        long n = read(p[0], got + have, 3000 - have);
        if (n <= 0) break;
        have += n;
    }
    int second_ok = have == 3000;
    for (int i = 0; i < 3000 && second_ok; i++) if (got[i] != 'B') second_ok = 0;
    check(second_ok, "G: and the big write then arrived whole, 3000 bytes in one piece");
    waitpid(kid, (int *)0, 0);
    close(p[0]);
    close(p[1]);

    print(failures == 0 ? "hello229: PASS\n" : "hello229: FAIL\n");
    return failures;
}
