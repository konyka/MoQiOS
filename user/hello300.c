/* hello300: a SIGSTOP that lands while a process blocks in eventfd read, timerfd read, mq_receive, epoll_wait, a socket recv or
 * nanosleep stops it at once (waitpid reports 0x137f), nothing runs while it is stopped, and after SIGCONT (0xffff) the wait goes on
 * and completes when its event arrives. Measured on the host (build with -DHOST): 30/30 rounds for each wait, also under
 * taskset -c 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long efd_new(void) { return eventfd(0, 0); }
static long tfd_new(void) { return timerfd_create(CLOCK_MONOTONIC, 0); }
static long tfd_arm(long fd, long ns) {
    struct itimerspec its = { { 0, 0 }, { 0, ns } };
    return timerfd_settime((int)fd, 0, &its, 0);
}
static long mq_new(const char *n) {
    struct mq_attr a = { 0, 4, 16, 0 };
    return mq_open(n, O_CREAT | O_RDWR, 0600, &a);
}
static long mq_put(long q) { return mq_send((mqd_t)q, "m", 1, 0); }
static long mq_get(long q) { char b[16]; return mq_receive((mqd_t)q, b, sizeof b, 0); }
static void mq_gone(long q, const char *n) { mq_close((mqd_t)q); mq_unlink(n); }
static long sockpair(int sv[2]) { return socketpair(AF_UNIX, SOCK_STREAM, 0, sv); }
static long ep_new(int fd) {
    int ep = epoll_create1(0);
    struct epoll_event ev = { EPOLLIN, { 0 } };
    epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
    return ep;
}
static long ep_wait(long ep) { struct epoll_event ev; return epoll_wait((int)ep, &ev, 1, -1); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/epoll.h"
static long efd_new(void) { return syscall2(169, 0, 0); }
static long tfd_new(void) { return syscall2(170, 1, 0); }
static long tfd_arm(long fd, long ns) {
    long its[4] = { 0, 0, 0, ns };
    return syscall4(171, fd, 0, (long)its, 0);
}
static long mq_new(const char *n) {
    long a[4] = { 0, 4, 16, 0 };
    return syscall4(186, (long)n, 02 | 0x40, 0600, (long)a);
}
static long mq_put(long q) { return syscall5(188, q, (long)"m", 1, 0, 0); }
static long mq_get(long q) { char b[16]; return syscall5(189, q, (long)b, sizeof b, 0, 0); }
static void mq_gone(long q, const char *n) { close((int)q); syscall1(187, (long)n); }
static long sockpair(int sv[2]) { return syscall4(53, 1, 1, 0, (long)sv); }
static long ep_new(int fd) {
    int ep = epoll_create1(0);
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = EPOLLIN;
    epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
    return ep;
}
static long ep_wait(long ep) { struct epoll_event ev; return epoll_wait((int)ep, &ev, 1, -1); }
#endif

#define S_KILL 9
#define S_STOP 19
#define S_CONT 18
#define O_WNOHANG 1
#define O_WUNTRACED 2
#define O_WCONTINUED 8
#define ROUNDS 30
#define RACE_ROUNDS 200

static int failures;
static char what[200];
static void check(int ok, const char *w) {
    print(ok ? "hello300:   ok   " : "hello300:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static int bp[2];
static int drain(void) {
    char b[64];
    int any = 0;
    while (read(bp[0], b, sizeof b) > 0) any = 1;
    return any;
}
static long wait_report(long c, int *st, int opt) {
    long r = 0;
    for (int i = 0; i < 300 && r == 0; i++) {
        r = waitpid(c, st, opt | O_WNOHANG);
        if (r == 0) nap(10);
    }
    return r;
}

enum { W_EVENTFD, W_TIMERFD, W_MQ, W_EPOLL, W_SOCKET, W_SLEEP, W_COUNT };
static const char *names[W_COUNT] = { "eventfd read", "timerfd read", "mq_receive", "epoll_wait", "AF_UNIX recv", "nanosleep" };

/* The child blocks in the wait, reports each completion on bp, and blocks again. */
static void child(int kind, long obj, long obj2) {
    char b[16];
    for (;;) {
        long r = 0;
        switch (kind) {
        case W_EVENTFD: r = read((int)obj, b, 8); break;
        case W_TIMERFD: r = read((int)obj, b, 8); break;
        case W_MQ: r = mq_get(obj); break;
        case W_EPOLL: r = ep_wait(obj); if (r > 0) read((int)obj2, b, 1); break;
        case W_SOCKET: r = read((int)obj, b, 1); break;
        case W_SLEEP: nap(40); r = 1; break;
        }
        if (r > 0) write(bp[1], "r", 1);
    }
}
/* Make the child's wait complete once. */
static void trigger(int kind, long obj, long obj2) {
    unsigned long one = 1;
    switch (kind) {
    case W_EVENTFD: write((int)obj, &one, 8); break;
    case W_TIMERFD: tfd_arm(obj, 1000000); break;
    case W_MQ: mq_put(obj); break;
    case W_EPOLL: write((int)obj2, "e", 1); break;
    case W_SOCKET: write((int)obj2, "s", 1); break;
    case W_SLEEP: break;
    }
}
static int got_back(void) {
    for (int i = 0; i < 200; i++) {
        if (drain()) return 1;
        nap(5);
    }
    return 0;
}

static void one(int kind) {
    long obj = -1, obj2 = -1, extra = -1;
    int sv[2] = { -1, -1 };
    const char *qn = "/h300q";
    switch (kind) {
    case W_EVENTFD: obj = efd_new(); obj2 = obj; break;
    case W_TIMERFD: obj = tfd_new(); break;
    case W_MQ: mq_gone(-1, qn); obj = mq_new(qn); break;
    case W_EPOLL: sockpair(sv); extra = sv[0]; obj = ep_new(sv[0]); obj2 = sv[1]; break;
    case W_SOCKET: sockpair(sv); obj = sv[0]; obj2 = sv[1]; break;
    case W_SLEEP: break;
    }
    drain();
    int st = 0;
    long c = fork();
    if (c == 0) {
        if (kind == W_EPOLL) child(kind, obj, extra);
        child(kind, obj, obj2);
    }
    int stops = 0, quiet = 0, conts = 0, back = 0;
    /* First completion: the child is in its loop. */
    trigger(kind, obj, obj2);
    int started = got_back();
    for (int round = 0; started && round < ROUNDS; round++) {
        /* The stop lands as the child goes back into its wait. */
        kill(c, S_STOP);
        st = 0;
        if (wait_report(c, &st, O_WUNTRACED) == c && st == 0x137f) stops++;
        else break;
        drain();
        nap(kind == W_SLEEP ? 100 : 5);
        if (!drain()) quiet++;
        kill(c, S_CONT);
        st = 0;
        if (wait_report(c, &st, O_WCONTINUED) == c && st == 0xffff) conts++;
        else break;
        trigger(kind, obj, obj2);
        if (got_back()) back++;
        else break;
    }
    /* Race: the stop is sent a varying moment after the event, so some land while the child is on its way back into the wait. */
    int rstops = 0;
    for (int round = 0; started && back == ROUNDS && round < RACE_ROUNDS; round++) {
        trigger(kind, obj, obj2);
        for (volatile int k = 0; k < (round % 40) * 500; k++) {}
        kill(c, S_STOP);
        st = 0;
        if (wait_report(c, &st, O_WUNTRACED) == c && st == 0x137f) rstops++;
        else break;
        kill(c, S_CONT);
        st = 0;
        if (wait_report(c, &st, O_WCONTINUED) != c) break;
        if (kind != W_SLEEP && !got_back()) break;
        drain();
    }
    kill(c, S_KILL);
    waitpid(c, &st, 0);
    snprintf(what, sizeof what, "%s: a SIGSTOP stops the blocked child (%d/%d), nothing runs while stopped (%d), SIGCONT (%d), the wait completes again (%d)",
             names[kind], stops, ROUNDS, quiet, conts, back);
    check(started && stops == ROUNDS && quiet == ROUNDS && conts == ROUNDS && back == ROUNDS, what);
    snprintf(what, sizeof what, "%s: a SIGSTOP sent just after the event, as the child goes back into the wait, stops it (%d/%d)", names[kind], rstops, RACE_ROUNDS);
    check(rstops == RACE_ROUNDS, what);
    switch (kind) {
    case W_EVENTFD: case W_TIMERFD: close((int)obj); break;
    case W_MQ: mq_gone(obj, qn); break;
    case W_EPOLL: close((int)obj); close(sv[0]); close(sv[1]); break;
    case W_SOCKET: close(sv[0]); close(sv[1]); break;
    default: break;
    }
}

int main(void) {
    print("hello300: default stops in eventfd, timerfd, mq, epoll, socket and sleep waits\n");
    if (pipe(bp) != 0) {
        print("hello300: FAIL (pipe)\n");
        return 1;
    }
    fcntl(bp[0], F_SETFL, O_NONBLOCK);
    for (int k = 0; k < W_COUNT; k++) one(k);
    print(failures == 0 ? "hello300: PASS\n" : "hello300: FAIL\n");
    return failures;
}
