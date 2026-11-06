/* test_fdops_abi.c -- dup, dup3, fcntl, pread, pwrite, truncate, ftruncate, fsync, fdatasync, access, umask, pipe2 and fchdir
 * (src/fdops.c) against a recording system-call stub. The convention is glibc's (measured on glibc 2.43): success returns the
 * kernel's value, failure returns -1 and sets errno; fcntl takes an optional third argument (the stub shows what the kernel is
 * given); pread/pwrite take the offset as the fourth system-call argument; umask cannot fail and returns the old mask.
 */
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"

int moqi_dup(int);
int moqi_dup3(int, int, int);
int moqi_fcntl(int, int, ...);
long moqi_pread(int, void *, size_t, long);
long moqi_pwrite(int, const void *, size_t, long);
int moqi_truncate(const char *, long);
int moqi_ftruncate(int, long);
int moqi_fsync(int);
int moqi_fdatasync(int);
int moqi_access(const char *, int);
unsigned int moqi_umask(unsigned int);
int moqi_pipe2(int[2], int);
int moqi_fchdir(int);

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static int ncalls;
static long c_nr, c_a1, c_a2, c_a3, c_a4;
static long reply;

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a5; (void)a6;
    ncalls++;
    c_nr = nr; c_a1 = a1; c_a2 = a2; c_a3 = a3; c_a4 = a4;
    return reply;
}

static void arm(long r) { ncalls = 0; reply = r; errno_slot = 0; c_nr = c_a1 = c_a2 = c_a3 = c_a4 = -777; }

int main(void) {
    CHECK(SYS_pread64 == 136 && SYS_pwrite64 == 137 && SYS_dup == 160 && SYS_dup3 == 161 && SYS_fcntl == 142);
    CHECK(SYS_access == 198 && SYS_truncate == 210 && SYS_ftruncate == 211 && SYS_fchdir == 234 && SYS_umask == 239);
    CHECK(SYS_fsync == 244 && SYS_fdatasync == 245 && SYS_pipe2 == 250);

    /* dup / dup3 */
    arm(7);
    CHECK(moqi_dup(3) == 7 && ncalls == 1 && c_nr == SYS_dup && c_a1 == 3);
    arm(-9);
    CHECK(moqi_dup(999) == -1 && errno_slot == EBADF);
    arm(50);
    CHECK(moqi_dup3(3, 50, 0x80000) == 50 && c_nr == SYS_dup3 && c_a1 == 3 && c_a2 == 50 && c_a3 == 0x80000);
    arm(-22);
    CHECK(moqi_dup3(3, 3, 0) == -1 && errno_slot == EINVAL);

    /* fcntl: the third argument is passed on; when the caller gave none the kernel is handed whatever the register held, which the
     * commands without an argument ignore, so only the command and descriptor are checked then */
    arm(2);
    CHECK(moqi_fcntl(3, 3 /* F_GETFL */) == 2 && c_nr == SYS_fcntl && c_a1 == 3 && c_a2 == 3);
    arm(0);
    CHECK(moqi_fcntl(3, 4 /* F_SETFL */, 0x800) == 0 && c_a2 == 4 && c_a3 == 0x800);
    arm(70);
    CHECK(moqi_fcntl(3, 0 /* F_DUPFD */, 70) == 70 && c_a3 == 70);
    arm(-9);
    CHECK(moqi_fcntl(999, 3) == -1 && errno_slot == EBADF);
    arm(-22);
    CHECK(moqi_fcntl(3, 9999) == -1 && errno_slot == EINVAL);

    /* pread / pwrite: the offset is the fourth system-call argument and the descriptor's own offset is not involved */
    char buf[8];
    arm(4);
    CHECK(moqi_pread(3, buf, 4, 2) == 4 && c_nr == SYS_pread64 && c_a1 == 3 && c_a2 == (long)buf && c_a3 == 4 && c_a4 == 2);
    arm(2);
    CHECK(moqi_pwrite(3, "AB", 2, 8) == 2 && c_nr == SYS_pwrite64 && c_a3 == 2 && c_a4 == 8);
    arm(-22);
    CHECK(moqi_pread(3, buf, 4, -1) == -1 && errno_slot == EINVAL);
    arm(-9);
    CHECK(moqi_pwrite(999, "A", 1, 0) == -1 && errno_slot == EBADF);

    /* truncate / ftruncate / fsync / fdatasync */
    arm(0);
    const char *tpath = "/tmp/x";
    CHECK(moqi_truncate(tpath, 2) == 0 && c_nr == SYS_truncate && c_a1 == (long)tpath && c_a2 == 2);
    arm(-2);
    CHECK(moqi_truncate("/tmp/nope", 1) == -1 && errno_slot == ENOENT);
    arm(0);
    CHECK(moqi_ftruncate(3, 4) == 0 && c_nr == SYS_ftruncate && c_a1 == 3 && c_a2 == 4);
    arm(-22);
    CHECK(moqi_ftruncate(3, -1) == -1 && errno_slot == EINVAL);
    arm(0);
    CHECK(moqi_fsync(3) == 0 && c_nr == SYS_fsync && c_a1 == 3);
    CHECK(moqi_fdatasync(3) == 0 && c_nr == SYS_fdatasync);
    arm(-9);
    CHECK(moqi_fsync(999) == -1 && errno_slot == EBADF);

    /* access */
    arm(0);
    CHECK(moqi_access("/tmp/x", 6) == 0 && c_nr == SYS_access && c_a2 == 6);
    arm(-2);
    CHECK(moqi_access("/tmp/nope", 0) == -1 && errno_slot == ENOENT);
    arm(-22);
    CHECK(moqi_access("/tmp/x", 8) == -1 && errno_slot == EINVAL);

    /* umask returns the old mask and cannot fail */
    arm(022);
    CHECK(moqi_umask(077) == 022 && c_nr == SYS_umask && c_a1 == 077);

    /* pipe2 and fchdir */
    int p[2];
    arm(0);
    CHECK(moqi_pipe2(p, 0x800) == 0 && c_nr == SYS_pipe2 && c_a1 == (long)p && c_a2 == 0x800);
    arm(-22);
    CHECK(moqi_pipe2(p, 0x1234) == -1 && errno_slot == EINVAL);
    arm(0);
    CHECK(moqi_fchdir(5) == 0 && c_nr == SYS_fchdir && c_a1 == 5);
    arm(-20);
    CHECK(moqi_fchdir(5) == -1 && errno_slot == ENOTDIR);

    if (bad) { fprintf(stderr, "%d check(s) failed\n", bad); return 1; }
    printf("test_fdops_abi: ok\n");
    return 0;
}
