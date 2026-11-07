/* hello237: epoll on TCP sockets over the loopback, on the real kernel. TCP readiness comes from a different path than pipes and
 * AF_UNIX sockets (tcpReadiness), and the loopback needs netpoll to move segments, so these cases are separate from hello236.
 * Expected values were measured on Linux with an equivalent program: EPOLLET reports 1,0,0,1; a clean peer close (FIN) gives
 * EPOLLIN|EPOLLRDHUP (0x2001); a peer that closes while holding unread data sends an RST and gives
 * EPOLLIN|EPOLLERR|EPOLLHUP|EPOLLRDHUP (0x2019). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/epoll.h"

#define SYS_getsockopt 133
#define SYS_sendto   121
#define SYS_recvfrom 122

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello237:   ok   " : "hello237:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void pump(int ms) {
    for (int i = 0; i < ms; i += 10) {
        syscall1(SYS_netpoll, 0);
        struct timespec ts = { 0, 10000000L };
        nanosleep(&ts, 0);
    }
}

static void mk_addr(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}

static int port_next = 18237;

/* Why the last make_pair failed: the step that failed and the value it returned (printed by the caller, so a CI log shows which call it was). */
static int mp_step;
static long mp_value;

/* A connected loopback pair: *cli is the client end, *srv the accepted end. On failure the step is in mp_step (1 socket, 2 bind, 3 listen,
 * 4 client socket, 5 connect, 6 accept) and the failing call's result in mp_value. */
static int make_pair(int *cli, int *srv) {
    unsigned char sa[16];
    int port = port_next++;
    mk_addr(sa, port);
    mp_step = 0;
    mp_value = 0;
    long ls = syscall3(SYS_socket, 2, 1, 0);
    if (ls < 0) { mp_step = 1; mp_value = ls; return -1; }
    long br = syscall3(SYS_bind, ls, (long)sa, 16);
    if (br != 0) { mp_step = 2; mp_value = br; close((int)ls); return -1; }
    long lr = syscall3(SYS_listen, ls, 4, 0);
    if (lr != 0) { mp_step = 3; mp_value = lr; close((int)ls); return -1; }
    long c = syscall3(SYS_socket, 2, 1, 0);
    if (c < 0) { mp_step = 4; mp_value = c; close((int)ls); return -1; }
    long r = syscall3(SYS_connect, c, (long)sa, 16);
    for (int i = 0; i < 100 && r < 0 && r != -106 /* EISCONN */; i++) {
        pump(20);
        r = syscall3(SYS_connect, c, (long)sa, 16);
    }
    long s = -1;
    for (int i = 0; i < 100 && s < 0; i++) {
        syscall1(SYS_netpoll, 0);
        s = syscall4(SYS_accept4, ls, 0, 0, 0);
        if (s < 0) pump(20);
    }
    close((int)ls);
    if (r < 0 && r != -106) { mp_step = 5; mp_value = r; close((int)c); if (s >= 0) close((int)s); return -1; }
    if (s < 0) { mp_step = 6; mp_value = s; close((int)c); return -1; }
    *cli = (int)c;
    *srv = (int)s;
    return 0;
}

static void report_pair_failure(const char *what) {
    char line[120];
    snprintf(line, sizeof line, "%s: make_pair failed at step %d (1 socket, 2 bind, 3 listen, 4 socket, 5 connect, 6 accept), result %ld", what, mp_step, mp_value);
    check(0, line);
}

static int wait_ev(int ep, struct epoll_event *o, int ms) {
    int n = 0;
    for (int i = 0; i < ms; i += 10) {
        syscall1(SYS_netpoll, 0);
        n = epoll_wait(ep, o, 2, 0);
        if (n != 0) return n;
        struct timespec ts = { 0, 10000000L };
        nanosleep(&ts, 0);
    }
    return n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello237: epoll on TCP\n");

    int c, s;
    if (make_pair(&c, &s) != 0) {
        report_pair_failure("A");
        print("hello237: FAIL\n");
        return 1;
    }
    check(1, "A: a connected loopback pair");

    /* EPOLLET on the accepted end */
    int ep = epoll_create1(0);
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = EPOLLIN | EPOLLET;
    ev.data.u32 = 1;
    epoll_ctl(ep, EPOLL_CTL_ADD, s, &ev);
    write(c, "ab", 2);
    struct epoll_event o[2];
    int e1 = wait_ev(ep, o, 500);
    pump(60);
    int e2 = epoll_wait(ep, o, 2, 0);
    char ch;
    read(s, &ch, 1);
    pump(60);
    int e3 = epoll_wait(ep, o, 2, 0);
    write(c, "c", 1);
    int e4 = wait_ev(ep, o, 500);
    {
        char what[120];
        snprintf(what, sizeof what, "B: EPOLLET on a TCP socket reports new edges only (counts %d,%d,%d,%d)", e1, e2, e3, e4);
        check(e1 == 1 && e2 == 0 && e3 == 0 && e4 == 1, what);
    }
    close(c);
    close(s);
    close(ep);

    /* a clean close: FIN */
    if (make_pair(&c, &s) == 0) {
        ep = epoll_create1(0);
        memset(&ev, 0, sizeof ev);
        ev.events = EPOLLIN | EPOLLRDHUP;
        epoll_ctl(ep, EPOLL_CTL_ADD, c, &ev);
        close(s);
        memset(o, 0, sizeof o);
        int n = wait_ev(ep, o, 1000);
        char what[140];
        snprintf(what, sizeof what, "C: a peer that closes cleanly gives EPOLLIN|EPOLLRDHUP, 0x2001 (n=%d events=0x%x)", n, n > 0 ? o[0].events : 0u);
        check(n == 1 && o[0].events == 0x2001, what);
        close(c);
        close(ep);
    } else {
        report_pair_failure("C");
    }

    /* a close that leaves unread data behind: RST */
    if (make_pair(&c, &s) == 0) {
        ep = epoll_create1(0);
        memset(&ev, 0, sizeof ev);
        ev.events = EPOLLIN | EPOLLRDHUP;
        epoll_ctl(ep, EPOLL_CTL_ADD, c, &ev);
        write(c, "zz", 2);
        pump(100);
        close(s);
        memset(o, 0, sizeof o);
        int n = wait_ev(ep, o, 1000);
        char what[160];
        snprintf(what, sizeof what, "D: a peer that closes with unread data (RST) gives 0x2019 (n=%d events=0x%x)", n, n > 0 ? o[0].events : 0u);
        check(n == 1 && o[0].events == 0x2019, what);
        close(c);
        close(ep);
    } else {
        report_pair_failure("D");
    }

    /* What the reset does to recv and send on the side that received it. Measured on Linux (two orders): the reset is reported ONCE,
     * to whichever of recv and send comes first, as -ECONNRESET; after that recv returns 0 (end of file) and send is -EPIPE. */
    if (make_pair(&c, &s) == 0) {
        char rb[16];
        write(c, "zz", 2);
        pump(100);
        close(s);
        pump(100);
        long r1 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        long r2 = syscall6(SYS_sendto, c, (long)"q", 1, 0x4000 /* MSG_NOSIGNAL */, 0, 0);
        long r3 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        char what[160];
        snprintf(what, sizeof what, "E: recv first: -ECONNRESET once, then send is -EPIPE and the next recv is 0 (%ld, %ld, %ld)", r1, r2, r3);
        check(r1 == -104 && r2 == -32 && r3 == 0, what);
        close(c);
    } else {
        report_pair_failure("E");
    }

    if (make_pair(&c, &s) == 0) {
        char rb[16];
        write(c, "zz", 2);
        pump(100);
        close(s);
        pump(100);
        long r1 = syscall6(SYS_sendto, c, (long)"q", 1, 0x4000, 0, 0);
        long r2 = syscall6(SYS_sendto, c, (long)"q", 1, 0x4000, 0, 0);
        long r3 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        char what[160];
        snprintf(what, sizeof what, "E2: send first: -ECONNRESET once, then -EPIPE, and the next recv is 0 (%ld, %ld, %ld)", r1, r2, r3);
        check(r1 == -104 && r2 == -32 && r3 == 0, what);
        close(c);
    } else {
        report_pair_failure("E2");
    }

    if (make_pair(&c, &s) == 0) {
        char rb[16];
        write(s, "hello", 5);
        write(c, "zz", 2);
        pump(100);
        close(s);
        pump(100);
        long r1 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        long r2 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        char what[160];
        long r3 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        snprintf(what, sizeof what, "F: data queued before the reset is delivered first (5 bytes), then -ECONNRESET once, then 0 (%ld, %ld, %ld)", r1, r2, r3);
        check(r1 == 5 && r2 == -104 && r3 == 0, what);
        close(c);
    } else {
        report_pair_failure("F");
    }

    /* POLLERR is the pending error: it is there until the ECONNRESET has been read, then it goes (Linux: revents 0x19 before, 0x11 after:
     * POLLIN|POLLERR|POLLHUP, then POLLIN|POLLHUP). */
    if (make_pair(&c, &s) == 0) {
        char rb[16];
        write(c, "zz", 2);
        pump(100);
        close(s);
        pump(100);
        struct { int fd; short events; short revents; } pf = { c, 1 /* POLLIN */, 0 };
        syscall3(162 /* poll */, (long)&pf, 1, 0);
        int before = pf.revents;
        syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        pf.revents = 0;
        syscall3(162, (long)&pf, 1, 0);
        int after = pf.revents;
        char what[160];
        snprintf(what, sizeof what, "G: POLLERR is reported until the ECONNRESET is read, then gone (before 0x%x, after 0x%x)", before, after);
        check(before == 0x19 && after == 0x11, what);
        close(c);
    } else {
        report_pair_failure("G");
    }

    /* A recv that is already asleep when the reset arrives: it wakes with -ECONNRESET (about 120 ms in), and the next recv is 0. The
     * peer's last copy is closed by a child so the parent can be blocked in recv at that moment. Measured on Linux. */
    if (make_pair(&c, &s) == 0) {
        char rb[16];
        write(c, "zz", 2);
        pump(100);
        long kid = fork();
        if (kid == 0) {
            close(c);
            struct timespec ts = { 0, 120000000L };
            nanosleep(&ts, 0);
            close(s);
            for (int i = 0; i < 20; i++) pump(10);
            _exit(0);
        }
        close(s);
        long t0 = 0;
        {
            struct timespec t;
            clock_gettime(CLOCK_MONOTONIC, &t);
            t0 = t.tv_sec * 1000L + t.tv_nsec / 1000000L;
        }
        long r1 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        long dt;
        {
            struct timespec t;
            clock_gettime(CLOCK_MONOTONIC, &t);
            dt = t.tv_sec * 1000L + t.tv_nsec / 1000000L - t0;
        }
        long r2 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0, 0, 0);
        char what[160];
        snprintf(what, sizeof what, "H: a recv asleep when the reset arrives wakes with -ECONNRESET, then 0 (%ld, %ld after %ld ms)", r1, r2, dt);
        check(r1 == -104 && r2 == 0 && dt >= 80, what);
        waitpid(kid, (int *)0, 0);
        close(c);
    } else {
        report_pair_failure("H");
    }

    /* I: a connection that completed the handshake but was never accepted is reset when the listener closes (Linux tcp_close on a
     * listening socket sends RST to every queued child): the client sees EPOLLIN|EPOLLERR|EPOLLHUP|EPOLLRDHUP (0x2019) and recv
     * gives -ECONNRESET, then 0. Measured on Linux: poll revents 0x201d with POLLOUT, recv -104, then 0. */
    {
        unsigned char sa[16];
        int port = port_next++;
        mk_addr(sa, port);
        long ls = syscall3(SYS_socket, 2, 1, 0);
        int ok = ls >= 0 && syscall3(SYS_bind, ls, (long)sa, 16) == 0 && syscall3(SYS_listen, ls, 4, 0) == 0;
        long c = syscall3(SYS_socket, 2, 1, 0);
        long r = ok ? syscall3(SYS_connect, c, (long)sa, 16) : -1;
        for (int i = 0; ok && i < 100 && r < 0 && r != -106; i++) {
            pump(20);
            r = syscall3(SYS_connect, c, (long)sa, 16);
        }
        pump(100);
        close((int)ls);
        pump(100);
        int ep9 = epoll_create1(0);
        struct epoll_event ev9, o9[2];
        memset(&ev9, 0, sizeof ev9);
        ev9.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP;
        ev9.data.fd = (int)c;
        epoll_ctl(ep9, EPOLL_CTL_ADD, (int)c, &ev9);
        memset(o9, 0, sizeof o9);
        int n9 = wait_ev(ep9, o9, 500);
        char what[160];
        snprintf(what, sizeof what, "I: a never-accepted connection is reported reset when the listener closes, 0x201d (n=%d events=0x%x)", n9, n9 > 0 ? o9[0].events : 0u);
        check(ok && r == 0 && n9 == 1 && o9[0].events == 0x201d, what);
        char rb[8];
        long r1 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0x40 /* MSG_DONTWAIT */, 0, 0);
        long r2 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0x40, 0, 0);
        snprintf(what, sizeof what, "I: recv gives -ECONNRESET once, then 0 (%ld, %ld)", r1, r2);
        check(r1 == -104 && r2 == 0, what);
        close(ep9);
        close((int)c);
    }

    /* J: shutdown() on a listener, measured on Linux. SHUT_RD and SHUT_RDWR stop the listener like close does: the queued child is
     * reset (client poll 0x201d), a new connect is ECONNREFUSED and accept is EINVAL. SHUT_WR changes nothing: the client stays
     * quiet (poll 0x4), a new connect succeeds and accept returns the queued child. */
    for (int how = 0; how < 3; how++) {
        unsigned char sa[16];
        int port = port_next++;
        mk_addr(sa, port);
        long ls = syscall3(SYS_socket, 2, 1, 0);
        int ok = ls >= 0 && syscall3(SYS_bind, ls, (long)sa, 16) == 0 && syscall3(SYS_listen, ls, 4, 0) == 0;
        long c = syscall3(SYS_socket, 2, 1, 0);
        long r = ok ? syscall3(SYS_connect, c, (long)sa, 16) : -1;
        for (int i = 0; ok && i < 100 && r < 0 && r != -106; i++) {
            pump(20);
            r = syscall3(SYS_connect, c, (long)sa, 16);
        }
        pump(100);
        long sr = syscall2(48 /* SYS_shutdown */, ls, how);
        pump(100);
        int epj = epoll_create1(0);
        struct epoll_event evj, oj[2];
        memset(&evj, 0, sizeof evj);
        evj.events = EPOLLIN | EPOLLOUT | EPOLLRDHUP;
        evj.data.fd = (int)c;
        epoll_ctl(epj, EPOLL_CTL_ADD, (int)c, &evj);
        memset(oj, 0, sizeof oj);
        int nj = wait_ev(epj, oj, 300);
        unsigned want = how == 1 ? 0x4u : 0x201du;
        long c2 = syscall3(SYS_socket, 2, 1, 0);
        long r2 = syscall3(SYS_connect, c2, (long)sa, 16);
        for (int i = 0; i < 100 && r2 < 0 && r2 != -106 && r2 != -111; i++) {
            pump(20);
            r2 = syscall3(SYS_connect, c2, (long)sa, 16);
        }
        pump(60);
        long ac = syscall4(SYS_accept4, ls, 0, 0, 0x800 /* SOCK_NONBLOCK */);
        char what[200];
        snprintf(what, sizeof what, "J: shutdown(listener, %d): client events 0x%x, second connect %ld, accept %ld (shutdown=%ld n=%d events=0x%x)", how, want, how == 1 ? 0L : -111L, how == 1 ? 1L : -22L, sr, nj, nj > 0 ? oj[0].events : 0u);
        int events_ok = how == 1 ? (nj == 1 && oj[0].events == 0x4u) : (nj == 1 && oj[0].events == 0x201du);
        int connect_ok = how == 1 ? r2 == 0 : r2 == -111;
        int accept_ok = how == 1 ? ac >= 0 : ac == -22;
        check(ok && r == 0 && sr == 0 && events_ok && connect_ok && accept_ok, what);
        if (ac >= 0) close((int)ac);
        close(epj);
        close((int)c);
        close((int)c2);
        close((int)ls);
    }

    /* K: SO_ERROR after a reset. Measured on Linux: getsockopt(SO_ERROR) returns ECONNRESET (104) once and clears it (the next
     * read is 0), recv then gives 0 and recv gives 0. If send reported the
     * reset first, SO_ERROR reads 0 (the error was already consumed). */
    for (int order = 0; order < 2; order++) {
        if (make_pair(&c, &s) != 0) {
            report_pair_failure("K");
            continue;
        }
        char rb[16];
        write(c, "zz", 2);
        pump(100);
        close(s);
        pump(100);
        int e1 = -1, e2 = -1;
        unsigned int l1 = 4, l2 = 4;
        long r1 = 0, r2 = 0;
        char what[200];
        if (order == 0) {
            syscall5(SYS_getsockopt, c, 1 /* SOL_SOCKET */, 4 /* SO_ERROR */, (long)&e1, (long)&l1);
            syscall5(SYS_getsockopt, c, 1, 4, (long)&e2, (long)&l2);
            r1 = syscall6(SYS_recvfrom, c, (long)rb, sizeof rb, 0x40, 0, 0);
            snprintf(what, sizeof what, "K: SO_ERROR reads ECONNRESET once, then 0, and recv is then 0 (%d, %d, recv %ld)", e1, e2, r1);
            check(e1 == 104 && e2 == 0 && r1 == 0, what);
        } else {
            r1 = syscall6(SYS_sendto, c, (long)"q", 1, 0x4000, 0, 0);
            syscall5(SYS_getsockopt, c, 1, 4, (long)&e1, (long)&l1);
            snprintf(what, sizeof what, "K2: send reports the reset first, so SO_ERROR is 0 (send %ld, SO_ERROR %d)", r1, e1);
            check(r1 == -104 && e1 == 0, what);
        }
        close(c);
    }

    print(failures == 0 ? "hello237: PASS\n" : "hello237: FAIL\n");
    return failures;
}
