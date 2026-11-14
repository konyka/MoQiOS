/* hello333: POSIX mq descriptors belong to the descriptor table, which CLONE_FILES threads share (Linux: an mqd_t is a file
 * descriptor in files_struct).
 * Measured on the host (build with -DHOST):
 *   A. a descriptor a thread opens is usable by the main thread, also after the thread exits;
 *   B. a descriptor the main thread opened and a thread closed is gone for the main thread (EBADF) and its number is free again;
 *   C. a thread's exit closes nothing: the main thread's descriptor still works;
 *   D. a forked child has its own table: its close leaves the parent's descriptor working, and a descriptor it opens is not the
 *      parent's. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long mq_open4(const char *n, long flags, long mode, void *attr) {
    mqd_t q = mq_open(n, (int)flags, (mode_t)mode, (struct mq_attr *)attr);
    return q < 0 ? -errno : q;
}
static long mq_send4(long q, const char *m) { return mq_send((mqd_t)q, m, 2, 0) < 0 ? -errno : 0; }
static long mq_recv4(long q) {
    char b[16];
    long r = mq_receive((mqd_t)q, b, sizeof b, (unsigned *)0);
    return r < 0 ? -errno : r;
}
static long mq_close1(long q) { return mq_close((mqd_t)q) < 0 ? -errno : 0; }
static long mq_unlink1(const char *n) { return mq_unlink(n) < 0 ? -errno : 0; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/pthread.h"
static long mq_open4(const char *n, long flags, long mode, void *attr) { return syscall4(186, (long)n, flags, mode, (long)attr); }
static long mq_send4(long q, const char *m) { return syscall5(188, q, (long)m, 2, 0, 0); }
static long mq_recv4(long q) {
    char b[16];
    return syscall5(189, q, (long)b, sizeof b, 0, 0);
}
static long mq_close1(long q) { return close((int)q); }
static long mq_unlink1(const char *n) { return syscall1(187, (long)n); }
#endif

#ifndef O_RDWR
#define O_RDWR 02
#endif
#ifndef O_CREAT
#define O_CREAT 0x40
#endif
#define O_NB 04000

struct kattr { long flags, maxmsg, msgsize, curmsgs; };

static int failures;
static char msg[240];
static void check(int ok, const char *w) {
    print(ok ? "hello333:   ok   " : "hello333:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

/* A round trip through descriptor d: send one message and take it back. */
static long round_trip(long d) {
    long s = mq_send4(d, "rt");
    if (s != 0) return s;
    return mq_recv4(d);
}

static long t_fd, t_rc;
static void *open_one(void *a) { (void)a; t_fd = mq_open4("/mq333", O_RDWR | O_NB, 0, 0); return 0; }
static void *close_one(void *a) { t_rc = mq_close1(*(long *)a); return 0; }
static void *use_one(void *a) { t_rc = round_trip(*(long *)a); return 0; }

int main(void) {
    print("hello333: POSIX mq descriptors are shared by the threads of a process\n");
    struct kattr attr = { 0, 4, 16, 0 };
    mq_unlink1("/mq333");
    long q = mq_open4("/mq333", O_RDWR | O_CREAT | O_NB, 0600, &attr);
    check(q >= 0, "mq_open succeeds");

    /* A: a thread's open is the process's. */
    pthread_t th;
    t_fd = -99;
    pthread_create(&th, 0, open_one, 0);
    pthread_join(th, 0);
    long r = round_trip(t_fd);
    snprintf(msg, sizeof msg, "A: a descriptor a thread opened works in the main thread after the thread exits (fd %ld, rt %ld)", t_fd, r);
    check(t_fd >= 0 && r == 2, msg);

    /* B: a thread's close is the process's. */
    long d = mq_open4("/mq333", O_RDWR | O_NB, 0, 0);
    t_rc = -99;
    pthread_create(&th, 0, close_one, &d);
    pthread_join(th, 0);
    r = round_trip(d);
    long again = mq_open4("/mq333", O_RDWR | O_NB, 0, 0);
    snprintf(msg, sizeof msg, "B: a descriptor a thread closed is gone for the main thread and its number is reused (close %ld, rt %ld, %ld -> %ld)",
             t_rc, r, d, again);
    check(t_rc == 0 && r == -9 && again == d, msg);
    mq_close1(again);

    /* C: a thread using a descriptor and exiting closes nothing. */
    t_rc = -99;
    pthread_create(&th, 0, use_one, &q);
    pthread_join(th, 0);
    r = round_trip(q);
    snprintf(msg, sizeof msg, "C: a thread that used a descriptor and exited leaves it open (thread rt %ld, main rt %ld)", t_rc, r);
    check(t_rc == 2 && r == 2, msg);

    /* D: a forked child has its own table. */
    long child = fork();
    if (child == 0) {
        int bad = mq_close1(q) != 0;
        long mine = mq_open4("/mq333", O_RDWR | O_NB, 0, 0);
        _exit(bad ? 1 : (mine < 0 ? 2 : 0));
    }
    int st = 0;
    waitpid(child, &st, 0);
    r = round_trip(q);
    long fresh = mq_open4("/mq333", O_RDWR | O_NB, 0, 0);
    snprintf(msg, sizeof msg, "D: a child's close leaves the parent's descriptor, and its open is not the parent's (status 0x%x, rt %ld, next %ld)",
             st, r, fresh);
    check(st == 0 && r == 2 && fresh >= 0, msg);
    mq_close1(fresh);

    mq_close1(t_fd);
    mq_close1(q);
    mq_unlink1("/mq333");
    print(failures ? "hello333: FAIL\n" : "hello333: PASS\n");
    return failures ? 1 : 0;
}
