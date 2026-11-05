/* hello234: poll() and ppoll() of moqi_libc on the real kernel. A pipe is not readable until something is written, becomes writable
 * and readable as the data arrives, reports POLLHUP once the writer has closed, and a closed descriptor is POLLNVAL; a timeout
 * runs out with 0 after roughly the time asked; a signal handler that runs during the wait makes poll fail with EINTR. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/poll.h"
#include "../lib/moqi_libc/include/select.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello234:   ok   " : "hello234:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile int hits;
static void on_usr1(int s) { (void)s; hits++; }

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello234: poll and ppoll\n");

    check(sizeof(struct pollfd) == 8 && POLLIN == 1 && POLLOUT == 4 && POLLHUP == 0x10 && POLLNVAL == 0x20, "A: struct pollfd and the event bits are glibc's");

    int p[2];
    pipe(p);
    struct pollfd fds[2] = { { p[0], POLLIN, 0 }, { p[1], POLLOUT, 0 } };

    errno = 0;
    int r = poll(fds, 2, 0);
    check(r == 1 && fds[0].revents == 0 && (fds[1].revents & POLLOUT), "B: an empty pipe is not readable, its write end is writable (1 ready)");

    write(p[1], "x", 1);
    fds[0].revents = fds[1].revents = 0;
    r = poll(fds, 2, 0);
    check(r == 2 && (fds[0].revents & POLLIN) && (fds[1].revents & POLLOUT), "B: after a write the read end is readable too (2 ready)");

    char c;
    read(p[0], &c, 1);
    fds[0].revents = 0;
    long t0 = now_ms();
    r = poll(fds, 1, 120);
    long dt = now_ms() - t0;
    check(r == 0 && fds[0].revents == 0, "C: a timeout with nothing ready returns 0");
    check(dt >= 100 && dt < 1500, "C: and waits about the 120 ms asked for");

    /* a writer in a child makes the wait end early with the data */
    long kid = fork();
    if (kid == 0) {
        struct timespec ts = { 0, 60000000L };
        nanosleep(&ts, 0);
        write(p[1], "y", 1);
        _exit(0);
    }
    t0 = now_ms();
    fds[0].revents = 0;
    r = poll(fds, 1, 3000);
    dt = now_ms() - t0;
    check(r == 1 && (fds[0].revents & POLLIN) && dt < 2000, "D: a blocked poll wakes when a child writes, long before its 3 s timeout");
    waitpid(kid, (int *)0, 0);
    read(p[0], &c, 1);

    /* hang-up and invalid descriptors */
    close(p[1]);
    fds[0].revents = 0;
    r = poll(fds, 1, 100);
    check(r == 1 && (fds[0].revents & POLLHUP), "E: when every writer has closed, the read end reports POLLHUP");
    struct pollfd bad = { 999, POLLIN, 0 };
    r = poll(&bad, 1, 0);
    check(r == 1 && bad.revents == POLLNVAL, "E: a descriptor that is not open is POLLNVAL");
    struct pollfd neg = { -1, POLLIN, 0x55 };
    r = poll(&neg, 1, 0);
    check(r == 0 && neg.revents == 0, "E: a negative descriptor is ignored and its revents cleared");
    close(p[0]);

    /* a handler that runs during the wait: EINTR */
    struct ksigaction act = { on_usr1, 0, (void *)0, 0 };
    sigaction(SIGUSR1, &act, (struct ksigaction *)0);
    hits = 0;
    pipe(p);
    long me = getpid();
    kid = fork();
    if (kid == 0) {
        struct timespec ts = { 0, 60000000L };
        nanosleep(&ts, 0);
        kill(me, SIGUSR1);
        _exit(0);
    }
    fds[0].fd = p[0];
    fds[0].events = POLLIN;
    errno = 0;
    r = poll(fds, 1, 3000);
    {
        char what[120];
        snprintf(what, sizeof what, "F: a signal handler that runs during poll makes it fail with EINTR (r=%d errno=%d hits=%d)", r, errno, (int)hits);
        check(r == -1 && errno == EINTR && hits == 1, what);
    }
    waitpid(kid, (int *)0, 0);

    /* ppoll with a timeout */
    struct timespec ts = { 0, 80000000L };
    t0 = now_ms();
    fds[0].revents = 0;
    r = ppoll(fds, 1, &ts, (const unsigned long *)0);
    dt = now_ms() - t0;
    check(r == 0 && dt >= 60 && dt < 1500, "G: ppoll with an 80 ms timespec times out with 0");

    /* ppoll with a mask that blocks SIGUSR1 for the duration: the signal does not interrupt the wait (it times out with 0), and when
     * ppoll returns the old mask is back and the pending signal is delivered, so the handler has run by the time the call returns
     * (measured on Linux 6.x: r=0 hits=1). */
    unsigned long block = 1UL << (SIGUSR1 - 1);
    hits = 0;
    kid = fork();
    if (kid == 0) {
        struct timespec ts2 = { 0, 40000000L };
        nanosleep(&ts2, 0);
        kill(me, SIGUSR1);
        _exit(0);
    }
    struct timespec ts3 = { 0, 200000000L };
    fds[0].revents = 0;
    t0 = now_ms();
    r = ppoll(fds, 1, &ts3, &block);
    dt = now_ms() - t0;
    {
        char what[160];
        snprintf(what, sizeof what, "G: with SIGUSR1 blocked by the ppoll mask, the wait runs its full 200 ms and the handler has run on return (r=%d dt=%ld hits=%d)", r, dt, (int)hits);
        check(r == 0 && dt >= 150 && hits == 1, what);
    }
    waitpid(kid, (int *)0, 0);

    /* select(): the same readiness as poll, with fd_set bit sets and a struct timeval */
    pipe(p);
    {
        fd_set rs, ws;
        struct timeval tv;
        FD_ZERO(&rs);
        FD_SET(p[0], &rs);
        tv.tv_sec = 0;
        tv.tv_usec = 100000;
        t0 = now_ms();
        r = select(p[0] + 1, &rs, (fd_set *)0, (fd_set *)0, &tv);
        dt = now_ms() - t0;
        check(r == 0 && !FD_ISSET(p[0], &rs) && dt >= 80 && dt < 1500, "H: select on an empty pipe times out with 0 after about 100 ms and clears the set");

        write(p[1], "q", 1);
        FD_ZERO(&rs);
        FD_SET(p[0], &rs);
        FD_ZERO(&ws);
        FD_SET(p[1], &ws);
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        r = select((p[0] > p[1] ? p[0] : p[1]) + 1, &rs, &ws, (fd_set *)0, &tv);
        check(r == 2 && FD_ISSET(p[0], &rs) && FD_ISSET(p[1], &ws), "H: select reports the readable read end and the writable write end (2 ready)");

        read(p[0], &c, 1);
        FD_ZERO(&rs);
        FD_SET(p[0], &rs);
        FD_SET(p[1] + 8, &rs);
        tv.tv_sec = 0;
        tv.tv_usec = 0;
        errno = 0;
        r = select(p[1] + 9, &rs, (fd_set *)0, (fd_set *)0, &tv);
        {
            char what[120];
            snprintf(what, sizeof what, "H: a descriptor that is not open in the set is -1 / EBADF (r=%d errno=%d)", r, errno);
            check(r == -1 && errno == EBADF, what);
        }

        /* a signal handler that runs during the wait: EINTR, and the handler has run when select returns */
        hits = 0;
        kid = fork();
        if (kid == 0) {
            struct timespec ts4 = { 0, 60000000L };
            nanosleep(&ts4, 0);
            kill(me, SIGUSR1);
            _exit(0);
        }
        FD_ZERO(&rs);
        FD_SET(p[0], &rs);
        errno = 0;
        r = select(p[0] + 1, &rs, (fd_set *)0, (fd_set *)0, (struct timeval *)0);
        {
            char what[120];
            snprintf(what, sizeof what, "H: a signal handler that runs during select makes it fail with EINTR (r=%d errno=%d hits=%d)", r, errno, (int)hits);
            check(r == -1 && errno == EINTR && hits == 1, what);
        }
        waitpid(kid, (int *)0, 0);
    }

    close(p[0]);
    close(p[1]);
    print(failures == 0 ? "hello234: PASS\n" : "hello234: FAIL\n");
    return failures;
}
