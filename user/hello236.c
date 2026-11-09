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

    /* a pipe's write end whose last reader has gone: EPOLLERR together with EPOLLOUT (measured on Linux: events 0xc) */
    {
        int q[2];
        pipe(q);
        signal(SIGPIPE, SIG_IGN);
        int ep3 = epoll_create1(0);
        struct epoll_event e3;
        memset(&e3, 0, sizeof e3);
        e3.events = EPOLLOUT;
        e3.data.u32 = 3;
        epoll_ctl(ep3, EPOLL_CTL_ADD, q[1], &e3);
        close(q[0]);
        struct epoll_event o3[2];
        memset(o3, 0, sizeof o3);
        int n3 = epoll_wait(ep3, o3, 2, 500);
        char what[140];
        snprintf(what, sizeof what, "G: a write end with no reader reports EPOLLERR|EPOLLOUT (n=%d events=0x%x)", n3, n3 > 0 ? o3[0].events : 0u);
        check(n3 == 1 && o3[0].events == (EPOLLOUT | EPOLLERR), what);
        close(q[1]);
        close(ep3);
    }

    /* EPOLLONESHOT: reported once, then disarmed until EPOLL_CTL_MOD rearms it. The sequence and the counts (1, 0, 0, 1) were measured
     * on Linux. */
    {
        int q[2];
        pipe(q);
        int ep4 = epoll_create1(0);
        struct epoll_event e4;
        memset(&e4, 0, sizeof e4);
        e4.events = EPOLLIN | EPOLLONESHOT;
        e4.data.u32 = 1;
        epoll_ctl(ep4, EPOLL_CTL_ADD, q[0], &e4);
        write(q[1], "a", 1);
        struct epoll_event o4[2];
        int n1 = epoll_wait(ep4, o4, 2, 200);
        int n2 = epoll_wait(ep4, o4, 2, 50);
        write(q[1], "b", 1);
        int n3 = epoll_wait(ep4, o4, 2, 50);
        e4.events = EPOLLIN | EPOLLONESHOT;
        e4.data.u32 = 2;
        epoll_ctl(ep4, EPOLL_CTL_MOD, q[0], &e4);
        memset(o4, 0, sizeof o4);
        int n4 = epoll_wait(ep4, o4, 2, 200);
        char what[160];
        snprintf(what, sizeof what, "H: EPOLLONESHOT is reported once, stays disarmed, and MOD rearms it (counts %d,%d,%d,%d; data %u)", n1, n2, n3, n4, n4 > 0 ? o4[0].data.u32 : 0u);
        check(n1 == 1 && n2 == 0 && n3 == 0 && n4 == 1 && o4[0].data.u32 == 2, what);
        close(q[0]);
        close(q[1]);
        close(ep4);
    }

    /* EPOLLET: a registration is reported on a new edge only. The sequence and the counts (1, 0, 0, 1, then 1 with EPOLLHUP) were measured
     * on Linux: one report for the first data, none while it stays unread, none after a partial read, one for new data, one for the
     * hang-up. */
    {
        int q[2];
        pipe(q);
        int ep5 = epoll_create1(0);
        struct epoll_event e5;
        memset(&e5, 0, sizeof e5);
        e5.events = EPOLLIN | EPOLLET;
        e5.data.u32 = 1;
        epoll_ctl(ep5, EPOLL_CTL_ADD, q[0], &e5);
        write(q[1], "ab", 2);
        struct epoll_event o5[2];
        int e1 = epoll_wait(ep5, o5, 2, 200);
        int e2 = epoll_wait(ep5, o5, 2, 50);
        char rc;
        read(q[0], &rc, 1);
        int e3 = epoll_wait(ep5, o5, 2, 50);
        write(q[1], "c", 1);
        int e4 = epoll_wait(ep5, o5, 2, 200);
        read(q[0], &rc, 1);
        read(q[0], &rc, 1);
        close(q[1]);
        memset(o5, 0, sizeof o5);
        int e5n = epoll_wait(ep5, o5, 2, 200);
        char what[180];
        snprintf(what, sizeof what, "I: EPOLLET reports new edges only (counts %d,%d,%d,%d,%d; last events 0x%x)", e1, e2, e3, e4, e5n, e5n > 0 ? o5[0].events : 0u);
        check(e1 == 1 && e2 == 0 && e3 == 0 && e4 == 1 && e5n == 1 && (o5[0].events & EPOLLHUP), what);
        close(q[0]);
        close(ep5);
    }

    /* The same ET and ONESHOT sequences on an AF_UNIX stream socket pair, and a peer close with EPOLLRDHUP asked for. Counts and the
     * final event word (0x2011 = EPOLLIN|EPOLLHUP|EPOLLRDHUP) were measured on Linux. */
    {
        int sv[2];
        syscall4(128 /* socketpair */, 1 /* AF_UNIX */, 1 /* SOCK_STREAM */, 0, (long)sv);
        int ep6 = epoll_create1(0);
        struct epoll_event e6;
        memset(&e6, 0, sizeof e6);
        e6.events = EPOLLIN | EPOLLET;
        e6.data.u32 = 1;
        epoll_ctl(ep6, EPOLL_CTL_ADD, sv[0], &e6);
        write(sv[1], "ab", 2);
        struct epoll_event o6[2];
        int a1 = epoll_wait(ep6, o6, 2, 200);
        int a2 = epoll_wait(ep6, o6, 2, 50);
        char rc;
        read(sv[0], &rc, 1);
        int a3 = epoll_wait(ep6, o6, 2, 50);
        write(sv[1], "c", 1);
        int a4 = epoll_wait(ep6, o6, 2, 200);
        char what[160];
        snprintf(what, sizeof what, "J: EPOLLET on a socket reports new edges only (counts %d,%d,%d,%d)", a1, a2, a3, a4);
        check(a1 == 1 && a2 == 0 && a3 == 0 && a4 == 1, what);
        close(sv[0]);
        close(sv[1]);
        close(ep6);

        int sw[2];
        syscall4(128, 1, 1, 0, (long)sw);
        int ep7 = epoll_create1(0);
        memset(&e6, 0, sizeof e6);
        e6.events = EPOLLIN | EPOLLONESHOT;
        e6.data.u32 = 1;
        epoll_ctl(ep7, EPOLL_CTL_ADD, sw[0], &e6);
        write(sw[1], "a", 1);
        int b1 = epoll_wait(ep7, o6, 2, 200);
        int b2 = epoll_wait(ep7, o6, 2, 50);
        write(sw[1], "b", 1);
        int b3 = epoll_wait(ep7, o6, 2, 50);
        e6.events = EPOLLIN | EPOLLONESHOT;
        e6.data.u32 = 2;
        epoll_ctl(ep7, EPOLL_CTL_MOD, sw[0], &e6);
        int b4 = epoll_wait(ep7, o6, 2, 200);
        snprintf(what, sizeof what, "K: EPOLLONESHOT on a socket is reported once and MOD rearms it (counts %d,%d,%d,%d)", b1, b2, b3, b4);
        check(b1 == 1 && b2 == 0 && b3 == 0 && b4 == 1, what);
        close(sw[0]);
        close(sw[1]);
        close(ep7);

        int sx[2];
        syscall4(128, 1, 1, 0, (long)sx);
        int ep8 = epoll_create1(0);
        memset(&e6, 0, sizeof e6);
        e6.events = EPOLLIN | EPOLLRDHUP;
        epoll_ctl(ep8, EPOLL_CTL_ADD, sx[0], &e6);
        close(sx[1]);
        memset(o6, 0, sizeof o6);
        int c1 = epoll_wait(ep8, o6, 2, 200);
        snprintf(what, sizeof what, "L: a closed peer reports EPOLLIN|EPOLLHUP|EPOLLRDHUP, 0x2011 (n=%d events=0x%x)", c1, c1 > 0 ? o6[0].events : 0u);
        check(c1 == 1 && o6[0].events == 0x2011, what);
        close(sx[0]);
        close(ep8);
    }

    errno = 0;
    check(epoll_wait(999, out, 4, 0) == -1 && errno == EBADF, "F: epoll_wait on a descriptor that is not open is -1 / EBADF");
    errno = 0;
    check(epoll_wait(ep, out, 0, 0) == -1 && errno == EINVAL, "F: maxevents 0 is -1 / EINVAL");
    errno = 0;
    check(epoll_create1(0x7777) == -1 && errno == EINVAL, "F: unknown epoll_create1 flags are -1 / EINVAL");

    /* G: epoll nesting depth. Linux allows a chain of at most EP_MAX_NESTS = 4 epoll-in-epoll edges (measured on the host): a registration that would make the
     * chain longer, counting the levels already below the added epoll and above the receiving one, is ELOOP. */
    {
        int c[5], q[5];
        for (int i = 0; i < 5; i++) { c[i] = epoll_create1(0); q[i] = epoll_create1(0); }
        struct epoll_event e2; e2.events = EPOLLIN; e2.data.u64 = 0;
        int ok = 1;
        for (int i = 0; i < 4; i++) ok = ok && epoll_ctl(c[i + 1], EPOLL_CTL_ADD, c[i], &e2) == 0; /* c4 > c3 > c2 > c1 > c0: four edges */
        check(ok, "G: a chain of four epoll-in-epoll registrations is allowed");
        errno = 0;
        check(epoll_ctl(q[0], EPOLL_CTL_ADD, c[4], &e2) == -1 && errno == ELOOP, "G: adding a four-deep tree under another epoll makes five levels: -1 / ELOOP");
        errno = 0;
        check(epoll_ctl(c[0], EPOLL_CTL_ADD, q[1], &e2) == -1 && errno == ELOOP, "G: adding a plain epoll at the bottom of a four-deep chain (c0) is ELOOP too");
        check(epoll_ctl(c[2], EPOLL_CTL_ADD, q[2], &e2) == 0, "G: adding a plain epoll in the middle of the chain is fine (two levels above)");
        check(epoll_ctl(q[4], EPOLL_CTL_ADD, c[3], &e2) == 0, "G: a three-deep tree under a plain epoll is exactly four edges: allowed");
        int c2[3], p2[3];
        for (int i = 0; i < 3; i++) { c2[i] = epoll_create1(0); p2[i] = epoll_create1(0); }
        epoll_ctl(c2[1], EPOLL_CTL_ADD, c2[0], &e2); epoll_ctl(c2[2], EPOLL_CTL_ADD, c2[1], &e2);
        epoll_ctl(p2[1], EPOLL_CTL_ADD, p2[0], &e2); epoll_ctl(p2[2], EPOLL_CTL_ADD, p2[1], &e2);
        errno = 0;
        check(epoll_ctl(p2[0], EPOLL_CTL_ADD, c2[2], &e2) == -1 && errno == ELOOP, "G: two levels below plus two above is five: ELOOP");
        int p3[2];
        p3[0] = epoll_create1(0); p3[1] = epoll_create1(0);
        epoll_ctl(p3[1], EPOLL_CTL_ADD, p3[0], &e2);
        check(epoll_ctl(p3[0], EPOLL_CTL_ADD, c2[2], &e2) == 0, "G: two below plus one above is four: allowed");
        /* deleting an edge frees the depth again */
        check(epoll_ctl(c[1], EPOLL_CTL_DEL, c[0], (struct epoll_event *)0) == 0, "G: deleting one edge works");
        int fresh = epoll_create1(0);
        check(epoll_ctl(fresh, EPOLL_CTL_ADD, c[4], &e2) == 0, "G: and the tree is now short enough to nest again");
    }

    close(p[0]);
    close(ep);
    print(failures == 0 ? "hello236: PASS\n" : "hello236: FAIL\n");
    return failures;
}
