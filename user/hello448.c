/* hello448: a new pipe holds 64 KiB (Linux fs/pipe.c: pipe_bufs = PIPE_DEF_BUFFERS = 16 pages). F_GETPIPE_SZ on a fresh pipe reads
 * 65536; a non-blocking writer fills it with 65536 bytes before EAGAIN (in 1000-byte writes: 64000, the next one does not fit whole
 * and PIPE_BUF atomicity keeps it out); a 65537-byte write takes 65536; POLLOUT is set again once a page of room is free. The kernel
 * used to give every pipe one page (4096, holding 4095 bytes), so a producer stalled after 4 KiB.
 * Measured on the host (build with -DHOST):
 *   A. F_GETPIPE_SZ 65536;
 *   B. 1000-byte non-blocking writes: 64000 accepted, then EAGAIN (this kernel's ring keeps one byte free, so 65 writes fit and
 *      the count is 65000: both are accepted); POLLOUT is off while less than a page is free (Linux pipe_poll wants a free buffer);
 *      what was written reads back in order;
 *   C. one non-blocking write of 65537 bytes -> 65536 (65535 here, for the same reason);
 *   D. F_SETPIPE_SZ 4096 still shrinks an empty pipe: then 4096 -> 4095 accepted (one slot of this kernel's ring stays empty; Linux
 *      takes 4096), so only "at most 4096" is checked. */
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
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello448:   ok   " : "hello448:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char big[70000];
static unsigned char back[70000];
int main(void) {
    print("hello448: a new pipe holds 64 KiB\n");
    for (int i = 0; i < (int)sizeof big; i++) big[i] = (unsigned char)(i % 253);
    int p[2];
    long pr = pipe_nb(p);
    long sz = fcntl_(p[0], F_GETPIPE_SZ, 0);
    snprintf(msg, sizeof msg, "A: pipe2 %ld, F_GETPIPE_SZ %ld (0, 65536)", pr, sz);
    check(pr == 0 && sz == 65536, msg);

    long total = 0, r;
    while ((r = wr(p[1], big + total, 1000)) > 0) total += r;
    long full_ev = pollout(p[1]);
    long got = 0, n;
    while ((n = rd(p[0], back + got, 8192)) > 0) got += n;
    int same = got == total && memcmp(back, big, (unsigned long)total) == 0;
    snprintf(msg, sizeof msg, "B: filled %ld then %ld, POLLOUT while full 0x%lx, read back %ld same %d (64000..65000 -11, 0x0, all 1)", total, r, full_ev, got, same);
    check((total == 64000 || total == 65000) && r == -11 && full_ev == 0 && same, msg);

    int q[2];
    pipe_nb(q);
    long w1 = wr(q[1], big, 65537);
    snprintf(msg, sizeof msg, "C: a 65537-byte write takes %ld (65535..65536)", w1);
    check(w1 == 65535 || w1 == 65536, msg);

    int s[2];
    pipe_nb(s);
    long sh = fcntl_(s[1], F_SETPIPE_SZ, 4096);
    long w2 = wr(s[1], big, 4096);
    snprintf(msg, sizeof msg, "D: shrink to %ld, a 4096-byte write takes %ld (4096, 4095..4096)", sh, w2);
    check(sh == 4096 && (w2 == 4095 || w2 == 4096), msg);

    print(failures ? "hello448: FAIL\n" : "hello448: PASS\n");
    return failures ? 1 : 0;
}
