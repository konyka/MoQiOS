/* hello353: io_submit IOCB_CMD_PREAD / IOCB_CMD_PWRITE use the iocb's offset and leave the description's shared offset alone
 * (Linux aio_prep_rw sets kiocb->ki_pos from aio_offset; f_pos is never touched). Measured on the host (build with -DHOST):
 *   A. while a parent submits 300 aio reads and writes at offsets of its own through one shared description, a forked child
 *      reading the same description 4 bytes at a time sees all 4096 records once, in order;
 *   B. every aio read returns the data at its own offset;
 *   C. afterwards the shared offset is where the child left it (16384, the file size). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rd(int fd, void *b, long n) { long r = read(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long wr(int fd, const void *b, long n) { long r = write(fd, b, (size_t)n); return r < 0 ? -errno : r; }
static long opn(const char *p, long fl) { long r = open(p, (int)fl, 0644); return r < 0 ? -errno : r; }
static long sc(long n, long a, long b, long c, long d, long e) { long r = syscall(n, a, b, c, d, e); return r < 0 ? -errno : r; }
#define IO_SETUP SYS_io_setup
#define IO_DESTROY SYS_io_destroy
#define IO_SUBMIT SYS_io_submit
#define IO_GETEVENTS SYS_io_getevents
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rd(int fd, void *b, long n) { return read(fd, b, (size_t)n); }
static long wr(int fd, const void *b, long n) { return write(fd, b, (size_t)n); }
static long opn(const char *p, long fl) { return open(p, fl, 0644); }
static long sc(long n, long a, long b, long c, long d, long e) { return syscall5(n, a, b, c, d, e); }
#define IO_SETUP 213
#define IO_DESTROY 214
#define IO_SUBMIT 215
#define IO_GETEVENTS 216
#endif
#define PATH "/tmp/hello353.dat"
#define NREC 4096
#define OPS 300
struct kiocb { unsigned long long data; unsigned key; unsigned rw_flags; unsigned short opcode; short prio; unsigned fd; unsigned long long buf, nbytes; long long offset; unsigned long long res2; unsigned flags, resfd; };
struct kioev { unsigned long long data, obj; long long res, res2; };

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello353:   ok   " : "hello353:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned long ctx;
/* One aio request (opcode 0 PREAD, 1 PWRITE); returns the completion's res, or -1000 when submit or getevents failed. */
static long aio1(int op, int fd, void *buf, unsigned long n, long long off) {
    struct kiocb cb;
    memset(&cb, 0, sizeof cb);
    cb.opcode = (unsigned short)op;
    cb.fd = (unsigned)fd;
    cb.buf = (unsigned long long)(unsigned long)buf;
    cb.nbytes = n;
    cb.offset = off;
    struct kiocb *list[1] = { &cb };
    if (sc(IO_SUBMIT, (long)ctx, 1, (long)list, 0, 0) != 1) return -1000;
    struct kioev ev;
    memset(&ev, 0, sizeof ev);
    if (sc(IO_GETEVENTS, (long)ctx, 1, 1, (long)&ev, 0) != 1) return -1000;
    return (long)ev.res;
}
static int full(int fd, void *b, long n, int w) {
    char *p = b;
    while (n > 0) {
        long r = w ? wr(fd, p, n) : rd(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= r;
    }
    return 0;
}
static long fork_together(void) {
    int ready[2], go[2];
    if (pipe(ready) != 0) return -1;
    if (pipe(go) != 0) return -1;
    long child = fork();
    char c = 0;
    if (child == 0) {
        wr(ready[1], &c, 1);
        rd(go[0], &c, 1);
    } else {
        rd(ready[0], &c, 1);
        wr(go[1], &c, 1);
    }
    close(ready[0]); close(ready[1]); close(go[0]); close(go[1]);
    return child;
}

int main(void) {
    print("hello353: aio reads and writes leave the shared file offset alone\n");
    long fd = opn(PATH, 2 | 0x40 | 0x200);
    static unsigned int recs[NREC];
    for (unsigned int i = 0; i < NREC; i++) recs[i] = i;
    int prep = fd < 0 || full((int)fd, recs, sizeof recs, 1) != 0;
    long setup = sc(IO_SETUP, 8, (long)&ctx, 0, 0, 0);
    snprintf(msg, sizeof msg, "open %s, write 4096 records, io_setup (rc %ld)", PATH, setup);
    check(!prep && setup == 0, msg);
    if (prep || setup != 0) { print("hello353: FAIL\n"); return 1; }
    lseek((int)fd, 0, 0);

    int p[2];
    if (pipe(p) != 0) { print("hello353: FAIL\n"); return 1; }
    long child = fork_together();
    if (child == 0) {
        close(p[0]);
        int count = 0, ordered = 1;
        unsigned int v, want = 0;
        while (rd((int)fd, &v, 4) == 4) {
            if (v != want) ordered = 0;
            want = v + 1;
            count++;
        }
        full(p[1], &count, sizeof count, 1);
        full(p[1], &ordered, sizeof ordered, 1);
        _exit(0);
    }
    close(p[1]);
    int wrong = 0, errs = 0;
    for (int k = 0; k < OPS; k++) {
        unsigned int at = (unsigned int)((k * 37) % (NREC - 16));
        unsigned int buf[16];
        if (k % 3 == 2) {
            for (int i = 0; i < 16; i++) buf[i] = at + (unsigned int)i;
            if (aio1(1, (int)fd, buf, sizeof buf, (long long)at * 4) != (long)sizeof buf) errs++;
        } else {
            memset(buf, 0xff, sizeof buf);
            if (aio1(0, (int)fd, buf, sizeof buf, (long long)at * 4) != (long)sizeof buf) errs++;
            for (int i = 0; i < 16; i++) if (buf[i] != at + (unsigned int)i) { wrong++; break; }
        }
    }
    int count = -1, ordered = 0;
    if (full(p[0], &count, sizeof count, 0) != 0 || full(p[0], &ordered, sizeof ordered, 0) != 0) count = -1;
    close(p[0]);
    int ws = 0;
    waitpid(child, &ws, 0);
    long end = lseek((int)fd, 0, 1);
    sc(IO_DESTROY, (long)ctx, 0, 0, 0, 0);

    snprintf(msg, sizeof msg, "A: the child reads all 4096 records once, in order, while aio runs (read %d, in order %d)", count, ordered);
    check(count == NREC && ordered, msg);
    snprintf(msg, sizeof msg, "B: every aio read returns the data at its own offset (%d of %d wrong, %d failed)", wrong, OPS, errs);
    check(wrong == 0 && errs == 0, msg);
    snprintf(msg, sizeof msg, "C: the shared offset is where the child left it (%ld, want %d)", end, NREC * 4);
    check(end == NREC * 4, msg);
    close((int)fd);
    unlink(PATH);
    print(failures ? "hello353: FAIL\n" : "hello353: PASS\n");
    return failures ? 1 : 0;
}
