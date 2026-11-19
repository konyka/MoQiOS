/* hello441: F_SETPIPE_SZ / F_GETPIPE_SZ resize a pipe (Linux fs/pipe.c pipe_set_size, round_pipe_size: the size is rounded up to
 * a power-of-two number of pages, at least one; above /proc/sys/fs/pipe-max-size (1 MiB) it needs CAP_SYS_RESOURCE (EPERM);
 * a size that cannot hold the bytes already in the pipe is EBUSY; the call returns the new size). The kernel's pipes had one fixed
 * page, so anything above 4096 failed with ENOMEM.
 * Measured on the host (build with -DHOST; the default size differs: Linux 65536, this kernel 4096, so it is only read back):
 *   A. F_SETPIPE_SZ 1 -> 4096, 5000 -> 8192, 100000 -> 131072, and F_GETPIPE_SZ reads 131072;
 *   B. with 131072, a non-blocking write of 100000 bytes writes all of them and a read gets them back in order;
 *   C. with 60000 bytes queued, F_SETPIPE_SZ 4096 -> -16 (EBUSY) and the size stays 131072; 65536 -> 65536;
 *   D. F_SETPIPE_SZ 2 MiB without CAP_SYS_RESOURCE -> -1 (EPERM); 0x80000000 -> -1 or -22.
 * The test runs as an unprivileged user (the init profile drops CAP_SYS_RESOURCE for it). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long fcntl_(long fd, int cmd, long arg) { return rc(fcntl((int)fd, cmd, arg)); }
static long pipe2_(int *p, int fl) { return rc(pipe2(p, fl)); }
static long wr(long fd, const void *b, long n) { return rc(write((int)fd, b, n)); }
static long rd(long fd, void *b, long n) { return rc(read((int)fd, b, n)); }
static void close_(long fd) { close((int)fd); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long fcntl_(long fd, int cmd, long arg) { return syscall3(72, fd, cmd, arg); }
static long pipe2_(int *p, int fl) { return pipe2(p, fl); }
static long wr(long fd, const void *b, long n) { return write((int)fd, b, n); }
static long rd(long fd, void *b, long n) { return read((int)fd, b, n); }
static void close_(long fd) { syscall1(11, fd); }
#endif
#define F_SETPIPE_SZ 1031
#define F_GETPIPE_SZ 1032
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello441:   ok   " : "hello441:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char out[100000], in[100000];
int main(void) {
    print("hello441: F_SETPIPE_SZ / F_GETPIPE_SZ\n");
    int p[2] = { -1, -1 };
    long pr = pipe2_(p, 0x800);
    long def = fcntl_(p[0], F_GETPIPE_SZ, 0);
    long a1 = fcntl_(p[1], F_SETPIPE_SZ, 1), a2 = fcntl_(p[1], F_SETPIPE_SZ, 5000), a3 = fcntl_(p[0], F_SETPIPE_SZ, 100000);
    long ag = fcntl_(p[1], F_GETPIPE_SZ, 0);
    snprintf(msg, sizeof msg, "A: pipe2 %ld, default size %ld; set 1 -> %ld, 5000 -> %ld, 100000 -> %ld; get %ld (0, >=4096; 4096 8192 131072; 131072)", pr, def, a1, a2,
             a3, ag);
    check(pr == 0 && def >= 4096 && a1 == 4096 && a2 == 8192 && a3 == 131072 && ag == 131072, msg);

    for (int i = 0; i < 100000; i++) out[i] = (unsigned char)(i * 7 + 3);
    long w = wr(p[1], out, 100000);
    long got = 0;
    while (got < 100000) {
        long r = rd(p[0], in + got, 100000 - got);
        if (r <= 0) break;
        got += r;
    }
    snprintf(msg, sizeof msg, "B: write 100000 -> %ld; read back %ld bytes, same %d (100000; 100000 1)", w, got, memcmp(out, in, 100000) == 0);
    check(w == 100000 && got == 100000 && memcmp(out, in, 100000) == 0, msg);

    long w2 = wr(p[1], out, 60000);
    long c0 = fcntl_(p[1], F_SETPIPE_SZ, 4096), cg = fcntl_(p[1], F_GETPIPE_SZ, 0), c1 = fcntl_(p[1], F_SETPIPE_SZ, 65536);
    got = 0;
    while (got < 60000) {
        long r = rd(p[0], in + got, 60000 - got);
        if (r <= 0) break;
        got += r;
    }
    snprintf(msg, sizeof msg, "C: 60000 queued (%ld); shrink to 4096 %ld, size %ld; 65536 -> %ld; read back %ld same %d (60000; -16 131072; 65536; 60000 1)", w2, c0,
             cg, c1, got, memcmp(out, in, 60000) == 0);
    check(w2 == 60000 && c0 == -16 && cg == 131072 && c1 == 65536 && got == 60000 && memcmp(out, in, 60000) == 0, msg);

    long d0 = fcntl_(p[1], F_SETPIPE_SZ, 2 * 1024 * 1024), d1 = fcntl_(p[1], F_SETPIPE_SZ, 0x80000000L);
    snprintf(msg, sizeof msg, "D: 2 MiB unprivileged %ld; 0x80000000 %ld (-1; -1 or -22)", d0, d1);
    check(d0 == -1 && (d1 == -1 || d1 == -22), msg);
    close_(p[0]);
    close_(p[1]);
    print(failures == 0 ? "hello441: PASS\n" : "hello441: FAIL\n");
    return failures == 0 ? 0 : 1;
}
