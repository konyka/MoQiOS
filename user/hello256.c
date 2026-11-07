/* hello256: TCP connection teardown over the loopback. Measured on Linux (tcpi_state numbers: FIN_WAIT2 5, TIME_WAIT 6, CLOSE 7,
 * CLOSE_WAIT 8): after the client shuts down its write side, the client is FIN_WAIT2 and the server CLOSE_WAIT; the server's read gives 0
 * (end of file); a socket in CLOSE_WAIT still holds its port (bind is EADDRINUSE); after the server closes too, the port is free again
 * once the client's socket is gone. After both ends shut down their write side every read is 0. A write after SHUT_WR is EPIPE (and
 * SIGPIPE, which the probe ignores: left at its default it kills the process with status 141). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/signal.h"

#define SYS_getsockopt 133
#define SYS_shutdown 48
#define SOL_TCP 6
#define TCP_INFO_OPT 11

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello256:   ok   " : "hello256:   FAIL ");
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

/* tcpi_state of a socket (Linux numbering), or -1. */
static int state_of(long fd) {
    unsigned char b[104];
    unsigned int l = sizeof b;
    memset(b, 0, sizeof b);
    if (syscall5(SYS_getsockopt, fd, SOL_TCP, TCP_INFO_OPT, (long)b, (long)&l) != 0) return -1;
    return b[0];
}

/* 0 when a fresh socket can bind and listen on `port`, else -errno. */
static long port_state(int port) {
    unsigned char sa[16];
    mk_addr(sa, port);
    long s = syscall3(SYS_socket, 2, 1, 0);
    if (s < 0) return s;
    long r = syscall3(SYS_bind, s, (long)sa, 16);
    if (r == 0) r = syscall3(SYS_listen, s, 1, 0);
    close((int)s);
    return r;
}

static int make_pair(int port, long *cli, long *srv) {
    unsigned char sa[16];
    mk_addr(sa, port);
    long ls = syscall3(SYS_socket, 2, 1, 0);
    if (ls < 0 || syscall3(SYS_bind, ls, (long)sa, 16) != 0 || syscall3(SYS_listen, ls, 4, 0) != 0) return -1;
    long c = syscall3(SYS_socket, 2, 1, 0);
    long r = syscall3(SYS_connect, c, (long)sa, 16);
    for (int i = 0; i < 100 && r < 0 && r != -106; i++) {
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
    if (c < 0 || s < 0) { if (c >= 0) close((int)c); if (s >= 0) close((int)s); return -1; }
    *cli = c;
    *srv = s;
    return 0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello256: TCP teardown\n");
    char what[200];
    long c, s;

    /* A: the client closes first; the server socket is CLOSE_WAIT and keeps its port until it closes too. */
    if (make_pair(23301, &c, &s) != 0) {
        check(0, "A: a connected loopback pair could not be made");
    } else {
        close((int)c);
        pump(100);
        int st = state_of(s);
        char b[4];
        long rd = read((int)s, b, 4);
        snprintf(what, sizeof what, "A: after the peer closed the server is CLOSE_WAIT (state %d) and its read gives 0 (%ld)", st, rd);
        check(st == 8 && rd == 0, what);
        long held = port_state(23301);
        snprintf(what, sizeof what, "A: a CLOSE_WAIT socket still holds its port: bind is EADDRINUSE (%ld)", held);
        check(held == -98, what);
        close((int)s);
        pump(100);
        long freed = port_state(23301);
        snprintf(what, sizeof what, "A: once the server closed too the port is free again (%ld)", freed);
        check(freed == 0, what);
    }

    /* B: shutdown(SHUT_WR) from the client only: FIN_WAIT2 on the client, CLOSE_WAIT on the server, and the server can still send. */
    if (make_pair(23302, &c, &s) != 0) {
        check(0, "B: a connected loopback pair could not be made");
    } else {
        syscall2(SYS_shutdown, c, 1);
        pump(100);
        int cs = state_of(c), ss = state_of(s);
        snprintf(what, sizeof what, "B: after the client's SHUT_WR the client is FIN_WAIT2 (%d) and the server CLOSE_WAIT (%d)", cs, ss);
        check(cs == 5 && ss == 8, what);
        long w = write((int)s, "hi", 2);
        pump(60);
        char b[8];
        long r = read((int)c, b, 8);
        snprintf(what, sizeof what, "B: the half-closed client still receives what the server sends (wrote %ld, read %ld)", w, r);
        check(w == 2 && r == 2 && b[0] == 'h', what);
        signal(SIGPIPE, SIG_IGN); /* Linux raises SIGPIPE for a write after SHUT_WR, which would kill this probe (exit status 141) */
        long cw = write((int)c, "x", 1);
        snprintf(what, sizeof what, "B: but writing after SHUT_WR fails with EPIPE (%ld, want %d)", cw, -EPIPE);
        check(cw == -EPIPE, what);

        /* C: the server shuts down too: both ends read 0 and the server's socket is finished. */
        syscall2(SYS_shutdown, s, 1);
        pump(100);
        long r1 = read((int)s, b, 8), r2 = read((int)c, b, 8);
        snprintf(what, sizeof what, "C: after both ends shut down their write side every read is 0 (server %ld, client %ld)", r1, r2);
        check(r1 == 0 && r2 == 0, what);
        /* The server's FIN took the client out of FIN_WAIT2 (Linux: TIME_WAIT 6 or already gone, never FIN_WAIT2 5). */
        int cs2 = state_of(c), ss2 = state_of(s);
        snprintf(what, sizeof what, "C: the server's FIN moved the client out of FIN_WAIT2 and the server left CLOSE_WAIT (client %d, server %d; Linux: TIME_WAIT 6 or CLOSE 7 for the client, LAST_ACK 9 or CLOSE 7 for the server)", cs2, ss2);
        check(cs2 != 5 && ss2 != 8, what);
        close((int)c);
        close((int)s);
        pump(60);
    }

    print(failures == 0 ? "hello256: PASS\n" : "hello256: FAIL\n");
    return failures;
}
