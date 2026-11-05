/* hello236: epoll_create1, epoll_ctl and epoll_wait of moqi_libc on the real kernel. A pipe's read end is not ready until data is
 * written, the stored data word comes back unchanged, EPOLLHUP shows when the writer closes, EPOLL_CTL_MOD and EPOLL_CTL_DEL change
 * the registration, duplicate and missing registrations are EEXIST / ENOENT, a timeout runs out with 0, and the layout of
 * struct epoll_event is the packed 12 bytes. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/epoll.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello236:   ok   " : "hello236:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello236: epoll\n");

    check(sizeof(struct epoll_event) == 12 && EPOLLIN == 1 && EPOLLET == 0x80000000u, "A: struct epoll_event is the packed 12 bytes and the bits are glibc's");

    int ep = epoll_create1(0);
    check(ep >= 0, "B: epoll_create1 returns a descriptor");
    int p[2];
    pipe(p);

    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = EPOLLIN;
    ev.data.u64 = 0x1122334455667788ULL;
    check(epoll_ctl(ep, EPOLL_CTL_ADD, p[0], &ev) == 0, "B: EPOLL_CTL_ADD of the pipe's read end");
    errno = 0;
    check(epoll_ctl(ep, EPOLL_CTL_ADD, p[0], &ev) == -1 && errno == EEXIST, "B: adding it again is -1 / EEXIST");
    errno = 0;
    check(epoll_ctl(ep, EPOLL_CTL_DEL, p[1], (struct epoll_event *)0) == -1 && errno == ENOENT, "B: deleting a descriptor that was never added is -1 / ENOENT");

    struct epoll_event out[4];
    long t0 = now_ms();
    int n = epoll_wait(ep, out, 4, 100);
    long dt = now_ms() - t0;
    check(n == 0 && dt >= 80 && dt < 1500, "C: an empty pipe times out with 0 after about 100 ms");

    write(p[1], "x", 1);
    memset(out, 0, sizeof out);
    n = epoll_wait(ep, out, 4, 1000);
    check(n == 1 && (out[0].events & EPOLLIN) && out[0].data.u64 == 0x1122334455667788ULL, "C: after a write the read end is ready, with the stored data word unchanged");

    char c;
    read(p[0], &c, 1);
    n = epoll_wait(ep, out, 4, 0);
    check(n == 0, "C: level-triggered: once the byte is read the descriptor is no longer reported");

    ev.events = EPOLLOUT;
    ev.data.fd = p[0];
    check(epoll_ctl(ep, EPOLL_CTL_MOD, p[0], &ev) == 0, "D: EPOLL_CTL_MOD changes the interest to EPOLLOUT");
    n = epoll_wait(ep, out, 4, 0);
    check(n == 0, "D: a read end is not writable, so nothing is reported");

    ev.events = EPOLLOUT;
    ev.data.u32 = 77;
    epoll_ctl(ep, EPOLL_CTL_ADD, p[1], &ev);
    memset(out, 0, sizeof out);
    n = epoll_wait(ep, out, 4, 0);
    check(n == 1 && (out[0].events & EPOLLOUT) && out[0].data.u32 == 77, "D: the write end is writable (1 ready, data 77)");

    check(epoll_ctl(ep, EPOLL_CTL_DEL, p[1], (struct epoll_event *)0) == 0, "D: EPOLL_CTL_DEL removes it");
    n = epoll_wait(ep, out, 4, 0);
    check(n == 0, "D: and it is not reported any more");

    ev.events = EPOLLIN;
    ev.data.u64 = 5;
    epoll_ctl(ep, EPOLL_CTL_MOD, p[0], &ev);
    close(p[1]);
    memset(out, 0, sizeof out);
    n = epoll_wait(ep, out, 4, 500);
    {
        char what[160];
        int n_again = epoll_wait(ep, out, 4, 0);
        snprintf(what, sizeof what, "E: when the last writer closes, the read end reports EPOLLHUP (first wait n=%d events=0x%x, a second wait n=%d)", n, n > 0 ? out[0].events : 0u, n_again);
        check(n == 1 && (out[0].events & EPOLLHUP), what);
    }

    /* the same hang-up on a fresh epoll instance and a fresh pipe, added once with EPOLLIN, with no MOD or DEL before it */
    {
        int ep2 = epoll_create1(0);
        int q[2];
        pipe(q);
        struct epoll_event e2;
        memset(&e2, 0, sizeof e2);
        e2.events = EPOLLIN;
        e2.data.u64 = 9;
        epoll_ctl(ep2, EPOLL_CTL_ADD, q[0], &e2);
        close(q[1]);
        struct epoll_event o2[2];
        memset(o2, 0, sizeof o2);
        int n2 = epoll_wait(ep2, o2, 2, 500);
        char what[140];
        snprintf(what, sizeof what, "E2: a fresh registration also reports EPOLLHUP after the writer closed (n=%d events=0x%x)", n2, n2 > 0 ? o2[0].events : 0u);
        check(n2 == 1 && (o2[0].events & EPOLLHUP), what);
        close(q[0]);
        close(ep2);
    }

    errno = 0;
    check(epoll_wait(999, out, 4, 0) == -1 && errno == EBADF, "F: epoll_wait on a descriptor that is not open is -1 / EBADF");
    errno = 0;
    check(epoll_wait(ep, out, 0, 0) == -1 && errno == EINVAL, "F: maxevents 0 is -1 / EINVAL");
    errno = 0;
    check(epoll_create1(0x7777) == -1 && errno == EINVAL, "F: unknown epoll_create1 flags are -1 / EINVAL");

    close(p[0]);
    close(ep);
    print(failures == 0 ? "hello236: PASS\n" : "hello236: FAIL\n");
    return failures;
}
