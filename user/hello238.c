/* hello238: pselect and epoll_pwait of moqi_libc on the real kernel. Both wait like select / epoll_wait but install a signal mask
 * for the wait only. Expected values were measured against glibc on Linux: a timeout runs out with 0 and the caller's timespec is
 * left alone; a ready pipe is reported; a signal that is blocked and pending runs its handler at once when the temporary mask
 * unblocks it, the call fails with EINTR, and the old mask is back afterwards; with a NULL mask the signal stays pending and
 * the wait is a plain one. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/select.h"
#include "../lib/moqi_libc/include/epoll.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello238:   ok   " : "hello238:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile int handled;
static void on_usr1(int sig) { (void)sig; handled++; }

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello238: pselect and epoll_pwait\n");
    char what[160];

    int p[2];
    pipe(p);
    signal(SIGUSR1, on_usr1);

    /* A: pselect */
    {
        fd_set r;
        struct timespec ts = { 0, 100000000 };
        FD_ZERO(&r);
        FD_SET(p[0], &r);
        long t0 = now_ms();
        int n = pselect(p[0] + 1, &r, 0, 0, &ts, 0);
        long dt = now_ms() - t0;
        check(n == 0 && dt >= 80 && dt < 1500, "A: pselect on an empty pipe times out with 0 after about 100 ms");
        check(ts.tv_sec == 0 && ts.tv_nsec == 100000000, "A: the timespec is left unchanged (it is const)");

        write(p[1], "x", 1);
        FD_ZERO(&r);
        FD_SET(p[0], &r);
        n = pselect(p[0] + 1, &r, 0, 0, &ts, 0);
        check(n == 1 && FD_ISSET(p[0], &r), "A: a readable pipe is reported, with no mask and with a timeout");
        char c;
        read(p[0], &c, 1);

        FD_ZERO(&r);
        FD_SET(p[0], &r);
        write(p[1], "y", 1);
        n = pselect(p[0] + 1, &r, 0, 0, 0, 0);
        check(n == 1, "A: a NULL timeout with data queued returns at once");
        read(p[0], &c, 1);
    }

    /* B: a blocked, pending SIGUSR1 and a temporary empty mask */
    {
        sigset_t block, empty, cur;
        sigemptyset(&block);
        sigaddset(&block, SIGUSR1);
        sigemptyset(&empty);
        sigprocmask(SIG_BLOCK, &block, 0);
        handled = 0;
        raise(SIGUSR1);
        check(handled == 0, "B: SIGUSR1 stays pending while blocked");

        fd_set r;
        struct timespec ts = { 1, 0 };
        FD_ZERO(&r);
        FD_SET(p[0], &r);
        errno = 0;
        int n = pselect(p[0] + 1, &r, 0, 0, &ts, &empty);
        snprintf(what, sizeof what, "B: pselect with an empty mask runs the handler and fails with EINTR (n=%d errno=%d handled=%d)", n, errno, handled);
        check(n == -1 && errno == EINTR && handled == 1, what);
        sigemptyset(&cur);
        sigprocmask(SIG_BLOCK, 0, &cur);
        check(sigismember(&cur, SIGUSR1) == 1, "B: the old mask is back after pselect");

        struct epoll_event ev, out[2];
        memset(&ev, 0, sizeof ev);
        int ep = epoll_create1(0);
        ev.events = EPOLLIN;
        ev.data.fd = p[0];
        epoll_ctl(ep, EPOLL_CTL_ADD, p[0], &ev);
        handled = 0;
        raise(SIGUSR1);
        errno = 0;
        n = epoll_pwait(ep, out, 2, 1000, &empty);
        snprintf(what, sizeof what, "B: epoll_pwait with an empty mask runs the handler and fails with EINTR (n=%d errno=%d handled=%d)", n, errno, handled);
        check(n == -1 && errno == EINTR && handled == 1, what);
        sigemptyset(&cur);
        sigprocmask(SIG_BLOCK, 0, &cur);
        check(sigismember(&cur, SIGUSR1) == 1, "B: the old mask is back after epoll_pwait");

        /* a NULL mask keeps the signal blocked: a plain wait, the handler does not run */
        raise(SIGUSR1);
        handled = 0;
        long t0 = now_ms();
        n = epoll_pwait(ep, out, 2, 100, 0);
        long dt = now_ms() - t0;
        check(n == 0 && handled == 0 && dt >= 80 && dt < 1500, "B: epoll_pwait with a NULL mask is a plain wait; the blocked signal does not interrupt it");

        sigprocmask(SIG_UNBLOCK, &block, 0);
        check(handled == 1, "B: unblocking the still-pending signal runs its handler");

        write(p[1], "z", 1);
        memset(out, 0, sizeof out);
        n = epoll_pwait(ep, out, 2, 1000, &empty);
        check(n == 1 && (out[0].events & EPOLLIN) && out[0].data.fd == p[0], "B: epoll_pwait reports a ready pipe after the signal was consumed");
        close(ep);
    }

    close(p[0]);
    close(p[1]);
    print(failures == 0 ? "hello238: PASS\n" : "hello238: FAIL\n");
    return failures;
}
