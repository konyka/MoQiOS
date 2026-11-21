/* hello470: a pipe counts page-sized buffers (Linux fs/pipe.c anon_pipe_write, pipe_poll, pipe_resize_ring). A write's remainder
 * (its length modulo 4096) joins the last buffer when it fits there; the rest takes fresh pages; the pipe is full once all of its
 * buffers (16 by default) are taken, however much room they have. Measured on the host (build with -DHOST):
 *   A. 1000-byte writes into a new non-blocking pipe: 64 go in (four per page), then EAGAIN; POLLOUT 0;
 *   B. reading 1000 bytes frees no buffer: POLLOUT 0, a 1000-byte write is EAGAIN;
 *   C. reading 3000 more empties the first page: POLLOUT, a 1000-byte write and a 100-byte one go in, a 3000-byte one is EAGAIN;
 *   D. a one-page pipe (F_SETPIPE_SZ 4096): a 1000-byte write, then POLLOUT 0; a 3096-byte write still merges; one more byte EAGAIN;
 *   E. 15 whole pages, then 4000 bytes: a 200-byte write does not fit behind them (EAGAIN), a 96-byte one does;
 *   F. 15 whole pages, 100 bytes, then 8000: 3904 go in (the 8000's remainder 3904 merges; no buffer is left for the rest);
 *   G. three 2000-byte writes take two buffers: shrinking to one page is EBUSY, to two pages works. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long pipe_nb(int *p) { return rc(pipe2(p, O_NONBLOCK)); }
static long wr(int fd, const void *b, long n) { return rc(write(fd, b, n)); }
static long rd(int fd, void *b, long n) { return rc(read(fd, b, n)); }
static long fcntl_(int fd, int cmd, long arg) { return rc(fcntl(fd, cmd, arg)); }
static long pollout(int fd) { struct pollfd p = { fd, POLLOUT, 0 }; long r = poll(&p, 1, 0); return r < 0 ? -errno : p.revents; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long pipe_nb(int *p) { return syscall2(SYS_pipe2, (long)p, 0x800); }
static long wr(int fd, const void *b, long n) { return syscall3(SYS_write, fd, (long)b, n); }
static long rd(int fd, void *b, long n) { return syscall3(SYS_read, fd, (long)b, n); }
static long fcntl_(int fd, int cmd, long arg) { return syscall3(SYS_fcntl, fd, cmd, arg); }
static long pollout(int fd) { struct { int fd; short ev, rev; } p = { fd, 4, 0 }; long r = syscall3(SYS_poll, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
#endif
#define F_SETPIPE_SZ 1031
#define F_GETPIPE_SZ 1032
#ifdef HOST
static void close2(int *p) { close(p[0]); close(p[1]); }
#else
static void close2(int *p) { syscall1(SYS_close, p[0]); syscall1(SYS_close, p[1]); }
#endif
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello470:   ok   " : "hello470:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static char b[70000];
int main(void) {
    print("hello470: a pipe counts page-sized buffers\n");
    int p[2];
    long pr = pipe_nb(p);
    int n = 0;
    while (wr(p[1], b, 1000) == 1000) n++;
    long a_poll = pollout(p[1]);
    rd(p[0], b, 1000);
    long b_poll = pollout(p[1]);
    long b_w = wr(p[1], b, 1000);
    snprintf(msg, sizeof msg, "A/B: pipe2 %ld; 1000-byte writes %d, POLLOUT %ld; after reading 1000: POLLOUT %ld write %ld (0 64 0 0 -11)", pr, n, a_poll, b_poll, b_w);
    check(pr == 0 && n == 64 && a_poll == 0 && b_poll == 0 && b_w == -11, msg);
    rd(p[0], b, 3000);
    long c_poll = pollout(p[1]);
    long c1 = wr(p[1], b, 1000), c2 = wr(p[1], b, 100), c3 = wr(p[1], b, 3000);
    snprintf(msg, sizeof msg, "C: after reading 3000 more: POLLOUT %ld; 1000 %ld 100 %ld 3000 %ld (4 1000 100 -11)", c_poll, c1, c2, c3);
    check(c_poll == 4 && c1 == 1000 && c2 == 100 && c3 == -11, msg);
    close2(p);

    pipe_nb(p);
    fcntl_(p[1], F_SETPIPE_SZ, 4096);
    long d1 = wr(p[1], b, 1000);
    long d_poll = pollout(p[1]);
    long d2 = wr(p[1], b, 3096), d3 = wr(p[1], b, 1);
    snprintf(msg, sizeof msg, "D: one page: 1000 %ld POLLOUT %ld; 3096 %ld; 1 %ld (1000 0 3096 -11)", d1, d_poll, d2, d3);
    check(d1 == 1000 && d_poll == 0 && d2 == 3096 && d3 == -11, msg);
    close2(p);

    pipe_nb(p);
    for (int i = 0; i < 15; i++) wr(p[1], b, 4096);
    long e1 = wr(p[1], b, 4000), e2 = wr(p[1], b, 200), e3 = wr(p[1], b, 96);
    snprintf(msg, sizeof msg, "E: 15 pages then 4000 %ld, 200 %ld, 96 %ld (4000 -11 96)", e1, e2, e3);
    check(e1 == 4000 && e2 == -11 && e3 == 96, msg);
    close2(p);

    pipe_nb(p);
    for (int i = 0; i < 15; i++) wr(p[1], b, 4096);
    long f1 = wr(p[1], b, 100), f2 = wr(p[1], b, 8000);
    snprintf(msg, sizeof msg, "F: 15 pages then 100 %ld, 8000 %ld (100 3904)", f1, f2);
    check(f1 == 100 && f2 == 3904, msg);
    close2(p);

    pipe_nb(p);
    for (int i = 0; i < 3; i++) wr(p[1], b, 2000);
    long g1 = fcntl_(p[1], F_SETPIPE_SZ, 4096), g2 = fcntl_(p[1], F_SETPIPE_SZ, 8192);
    snprintf(msg, sizeof msg, "G: three 2000-byte writes (two pages), shrink to 4096 %ld, to 8192 %ld (-16 8192)", g1, g2);
    check(g1 == -16 && g2 == 8192, msg);

    print(failures ? "hello470: FAIL\n" : "hello470: PASS\n");
    return failures ? 1 : 0;
}
