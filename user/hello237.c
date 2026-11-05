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

/* A connected loopback pair: *cli is the client end, *srv the accepted end. */
static int make_pair(int *cli, int *srv) {
    unsigned char sa[16];
    int port = port_next++;
    mk_addr(sa, port);
    long ls = syscall3(SYS_socket, 2, 1, 0);
    if (ls < 0 || syscall3(SYS_bind, ls, (long)sa, 16) != 0 || syscall3(SYS_listen, ls, 4, 0) != 0) return -1;
    long c = syscall3(SYS_socket, 2, 1, 0);
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
    if (c < 0 || s < 0) return -1;
    *cli = (int)c;
    *srv = (int)s;
    return 0;
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
        check(0, "A: a connected loopback pair could not be made");
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
        check(0, "C: a connected loopback pair could not be made");
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
        check(0, "D: a connected loopback pair could not be made");
    }

    print(failures == 0 ? "hello237: PASS\n" : "hello237: FAIL\n");
    return failures;
}
