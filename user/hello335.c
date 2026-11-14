/* hello335: an mq descriptor's read offset belongs to its open description (Linux: struct file f_pos, shared by dup and fork).
 * Measured on the host (build with -DHOST):
 *   A. after reading 10 bytes through q, a dup of q is at offset 10 and reads the remaining 50;
 *   B. lseek through the dup moves the original;
 *   C. a second mq_open of the same queue starts at offset 0 and does not move the first;
 *   D. a forked child's read moves the parent's offset;
 *   E. SEEK_END is 80 (the inode size); a seek before 0 fails and keeps the offset;
 *   F. pread through the dup does not move the shared offset. */
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

#define O_RDWR_ 02
#define O_CREAT_ 0x40
#define O_NB 04000

struct kattr { long flags, maxmsg, msgsize, curmsgs; };

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello335:   ok   " : "hello335:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

int main(void) {
    print("hello335: an mq descriptor's read offset belongs to its open description\n");
    mq_unlink1("/mq335");
    struct kattr a = { 0, 2, 16, 0 };
    long q = mq_open4("/mq335", O_RDWR_ | O_CREAT_ | O_NB, 0600, &a);
    char b[128];

    /* A: read through q, continue through a dup. */
    long d = dup((int)q);
    long n1 = rd((int)q, b, 10);
    long cur_d = lseek((int)d, 0, 1);
    long n2 = rd((int)d, b, 127);
    snprintf(msg, sizeof msg, "A: a dup continues where the original stopped (read %ld, dup SEEK_CUR %ld, dup read %ld)", n1, cur_d, n2);
    check(n1 == 10 && cur_d == 10 && n2 == 50, msg);

    /* B: lseek through the dup moves the original. */
    long ls = lseek((int)d, 5, 0);
    long cur_q = lseek((int)q, 0, 1);
    snprintf(msg, sizeof msg, "B: lseek(dup, 5) moves the original (lseek %ld, original SEEK_CUR %ld)", ls, cur_q);
    check(ls == 5 && cur_q == 5, msg);

    /* C: a second mq_open has its own offset. */
    long r = mq_open4("/mq335", O_RDWR_, 0, 0);
    long cur_r = lseek((int)r, 0, 1);
    long n3 = rd((int)r, b, 127);
    long cur_q2 = lseek((int)q, 0, 1);
    snprintf(msg, sizeof msg, "C: another mq_open starts at 0 (SEEK_CUR %ld, read %ld, original still %ld)", cur_r, n3, cur_q2);
    check(cur_r == 0 && n3 == 60 && cur_q2 == 5, msg);

    /* D: a forked child's read moves the parent's offset. */
    lseek((int)q, 0, 0);
    long child = fork();
    if (child == 0) _exit(rd((int)q, b, 20) == 20 ? 0 : 1);
    int ws = 0;
    waitpid(child, &ws, 0);
    long cur_after = lseek((int)q, 0, 1);
    snprintf(msg, sizeof msg, "D: a child's read of 20 moves the parent's offset (status 0x%x, parent SEEK_CUR %ld)", ws, cur_after);
    check(ws == 0 && cur_after == 20, msg);

    /* E: SEEK_END is relative to the 80-byte file size; a negative position is EINVAL. */
    long se = lseek((int)q, 0, 2);
    long neg = lseek((int)q, -100, 1);
    long cur_e = lseek((int)q, 0, 1);
    snprintf(msg, sizeof msg, "E: SEEK_END %ld, seek before 0 %ld, offset kept %ld", se, neg, cur_e);
    check(se == 80 && neg < 0 && cur_e == 80, msg);

    /* F: pread does not move the shared offset. */
    lseek((int)q, 7, 0);
    long pr = pread((int)d, b, 127, 0);
    long cur_f = lseek((int)q, 0, 1);
    snprintf(msg, sizeof msg, "F: pread through the dup reads %ld and leaves the offset at %ld", pr, cur_f);
    check(pr == 60 && cur_f == 7, msg);

    close((int)r);
    close((int)d);
    close((int)q);
    mq_unlink1("/mq335");
    print(failures ? "hello335: FAIL\n" : "hello335: PASS\n");
    return failures ? 1 : 0;
}
