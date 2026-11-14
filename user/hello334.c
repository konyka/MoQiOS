/* hello334: a POSIX mq descriptor is an ordinary file descriptor (Linux: do_mq_open installs a file with get_unused_fd_flags).
 * Measured on the host (build with -DHOST):
 *   A. mq_open returns the lowest free descriptor number;
 *   B. dup shares the open description: a send through the copy works, and closing the original leaves the copy usable;
 *   C. every mq descriptor has FD_CLOEXEC (Linux do_mq_open: FD_ADD(O_CLOEXEC, ...)) whatever oflag says; F_GETFL of an
 *      O_RDWR|O_NONBLOCK open is 0x802, of an O_RDONLY|O_CLOEXEC open 0x80000;
 *   D. poll: an empty queue is POLLOUT, one with a message POLLIN|POLLOUT, a full one POLLIN;
 *   E. dup2 to a chosen number works for mq_send;
 *   F. read returns the queue's status line (60 bytes) once, then 0; write is EINVAL; lseek to 0 succeeds;
 *   G. mq_send / mq_getattr on a pipe or a closed number is EBADF;
 *   H. F_SETFL and mq_setattr change the same O_NONBLOCK;
 *   I. fstat: a regular file with the queue's mode, size 80; /proc/self/fd/N names the queue;
 *   J. a forked child sends through the inherited descriptor and the parent receives it. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long mq_open4(const char *n, long flags, long mode, void *attr) {
    mqd_t q = mq_open(n, (int)flags, (mode_t)mode, (struct mq_attr *)attr);
    return q < 0 ? -errno : q;
}
static long mq_send4(long q, const char *m, long len) { return mq_send((mqd_t)q, m, (size_t)len, 0) < 0 ? -errno : 0; }
static long mq_recv4(long q) {
    char b[16];
    long r = mq_receive((mqd_t)q, b, sizeof b, (unsigned *)0);
    return r < 0 ? -errno : r;
}
static long mq_getset(long q, void *nattr, void *oattr) {
    return syscall(SYS_mq_getsetattr, q, nattr, oattr) < 0 ? -errno : 0;
}
static long mq_unlink1(const char *n) { return mq_unlink(n) < 0 ? -errno : 0; }
static long rd(int fd, char *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wr(int fd, const char *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/poll.h"
#include "../lib/moqi_libc/include/stat.h"
static long mq_open4(const char *n, long flags, long mode, void *attr) { return syscall4(186, (long)n, flags, mode, (long)attr); }
static long mq_send4(long q, const char *m, long len) { return syscall5(188, q, (long)m, len, 0, 0); }
static long mq_recv4(long q) {
    char b[16];
    return syscall5(189, q, (long)b, sizeof b, 0, 0);
}
static long mq_getset(long q, void *nattr, void *oattr) { return syscall3(191, q, (long)nattr, (long)oattr); }
static long mq_unlink1(const char *n) { return syscall1(187, (long)n); }
static long rd(int fd, char *b, long n) { return read(fd, b, (size_t)n); }
static long wr(int fd, const char *b, long n) { return write(fd, b, (size_t)n); }
#endif

#ifndef O_RDWR
#define O_RDWR 02
#endif
#ifndef O_CREAT
#define O_CREAT 0x40
#endif
#define O_NB 04000
#define O_CLOEX 02000000

struct kattr { long flags, maxmsg, msgsize, curmsgs; };

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello334:   ok   " : "hello334:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

static int revents(long fd) {
    struct pollfd p;
    p.fd = (int)fd;
    p.events = POLLIN | POLLOUT;
    p.revents = 0;
    int n = poll(&p, 1, 0);
    return n == 1 ? p.revents : -100 - n;
}

int main(void) {
    print("hello334: a POSIX mq descriptor is an ordinary file descriptor\n");
    mq_unlink1("/mq334");
    struct kattr a = { 0, 2, 16, 0 };

    /* A: the lowest free number. */
    int probe[2];
    pipe(probe);
    close(probe[0]);
    long q = mq_open4("/mq334", O_RDWR | O_CREAT | O_NB, 0600, &a);
    snprintf(msg, sizeof msg, "A: mq_open takes the lowest free descriptor (free %d, got %ld)", probe[0], q);
    check(q == probe[0], msg);
    close(probe[1]);

    /* B: dup shares the description. */
    long d = dup((int)q);
    long s = mq_send4(d, "hi", 2);
    long rr = mq_recv4(q);
    snprintf(msg, sizeof msg, "B: a dup sends to the same queue (dup %ld, send %ld, recv %ld)", d, s, rr);
    check(d >= 0 && d != q && s == 0 && rr == 2, msg);

    /* C: descriptor and status flags. */
    long fd_flags = fcntl((int)q, F_GETFD);
    long fl = fcntl((int)q, F_GETFL);
    long r = mq_open4("/mq334", O_RDONLY | O_CLOEX, 0, 0);
    long rfd = fcntl((int)r, F_GETFD);
    long rfl = fcntl((int)r, F_GETFL);
    snprintf(msg, sizeof msg, "C: F_GETFD/F_GETFL (rdwr|nb: %ld 0x%lx; rdonly|cloexec: %ld 0x%lx)", fd_flags, fl, rfd, rfl);
    check(fd_flags == 1 && fl == 0x802 && rfd == 1 && rfl == 0x80000, msg);

    /* D: poll. */
    int e0 = revents(q);
    mq_send4(q, "m1", 2);
    int e1 = revents(q);
    mq_send4(q, "m2", 2);
    int e2 = revents(q);
    int er = revents(r);
    snprintf(msg, sizeof msg, "D: poll empty 0x%x, one message 0x%x, full 0x%x, full through O_RDONLY 0x%x", e0, e1, e2, er);
    check(e0 == POLLOUT && e1 == (POLLIN | POLLOUT) && e2 == POLLIN && er == POLLIN, msg);
    mq_recv4(q);
    mq_recv4(q);

    /* E: dup2 to a chosen number. */
    long d2 = dup2((int)q, 40);
    s = mq_send4(40, "x", 1);
    rr = mq_recv4(q);
    snprintf(msg, sizeof msg, "E: dup2 to 40 sends (dup2 %ld, send %ld, recv %ld)", d2, s, rr);
    check(d2 == 40 && s == 0 && rr == 1, msg);
    close(40);

    /* F: read/write/lseek. */
    mq_send4(q, "hey", 3);
    char b[128];
    memset(b, 0, sizeof b);
    long n1 = rd((int)q, b, 127);
    int qsize_ok = strncmp(b, "QSIZE:3          NOTIFY:0     SIGNO:0     NOTIFY_PID:0     \n", 61) == 0;
    long n2 = rd((int)q, b, 127);
    long w = wr((int)q, "zz", 2);
    long ls = lseek((int)q, 0, 0);
    long n3 = rd((int)q, b, 127);
    snprintf(msg, sizeof msg, "F: read gives the status line once (%ld, line %s, then %ld), write %ld, lseek %ld, read again %ld", n1,
             qsize_ok ? "ok" : "wrong", n2, w, ls, n3);
    check(n1 == 60 && qsize_ok && n2 == 0 && w == -22 && ls == 0 && n3 == 60, msg);
    mq_recv4(q);

    /* G: only mq descriptors are mq descriptors. */
    int pf[2];
    pipe(pf);
    struct kattr g;
    long gs = mq_send4(pf[1], "a", 1);
    long gg = mq_getset(pf[0], 0, &g);
    long gc = mq_send4(77, "a", 1);
    snprintf(msg, sizeof msg, "G: mq_send on a pipe %ld, mq_getattr on a pipe %ld, mq_send on a closed number %ld", gs, gg, gc);
    check(gs == -9 && gg == -9 && gc == -9, msg);
    close(pf[0]);
    close(pf[1]);

    /* H: one O_NONBLOCK. */
    fcntl((int)q, F_SETFL, 0);
    struct kattr h1;
    mq_getset(q, 0, &h1);
    struct kattr nb = { O_NB, 0, 0, 0 };
    mq_getset(q, &nb, 0);
    long hf = fcntl((int)q, F_GETFL);
    snprintf(msg, sizeof msg, "H: F_SETFL 0 gives mq_flags 0x%lx; mq_setattr O_NONBLOCK gives F_GETFL 0x%lx", h1.flags, hf);
    check(h1.flags == 0 && hf == 0x802, msg);

    /* I: fstat and the /proc link. */
    struct stat st;
    long fs = fstat((int)q, &st);
    char path[40], link[64];
    memset(link, 0, sizeof link);
    snprintf(path, sizeof path, "/proc/self/fd/%ld", q);
    long ln = readlink(path, link, 63);
    snprintf(msg, sizeof msg, "I: fstat %ld mode 0%o size %ld; link %ld [%s]", fs, (unsigned)st.st_mode, (long)st.st_size, ln, link);
    check(fs == 0 && st.st_mode == 0100600 && st.st_size == 80 && ln == 6 && strcmp(link, "/mq334") == 0, msg);

    /* J: a forked child's inherited descriptor. */
    long child = fork();
    if (child == 0) _exit(mq_send4(q, "ch", 2) == 0 ? 0 : 1);
    int ws = 0;
    waitpid(child, &ws, 0);
    rr = mq_recv4(q);
    snprintf(msg, sizeof msg, "J: a child sends through the inherited descriptor (status 0x%x, parent recv %ld)", ws, rr);
    check(ws == 0 && rr == 2, msg);

    close((int)r);
    close((int)d);
    close((int)q);
    mq_unlink1("/mq334");
    print(failures ? "hello334: FAIL\n" : "hello334: PASS\n");
    return failures ? 1 : 0;
}
