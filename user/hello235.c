/* hello235: a signal handler runs BEFORE a blocking call that it interrupts returns -EINTR, for the calls that wait inside the kernel
 * and that hello229/hello234 did not cover: epoll_wait, futex(FUTEX_WAIT), SysV semop, and rt_sigtimedwait. Each case
 * blocks, a forked child sends SIGUSR1 after ~60 ms, and the parent checks that the call returned -EINTR and that the handler had
 * already run (hits == 1) when it did -- on Linux the handler runs on the way out of the call. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/time.h"

#define SYS_EPOLL_CREATE1 146
#define SYS_EPOLL_CTL 147
#define SYS_EPOLL_WAIT 148
#define SYS_FUTEX 143
#define SYS_MSGGET 156
#define SYS_MSGRCV 158
#define SYS_MSGCTL 159
#define SYS_SEMGET 153
#define SYS_SEMOP 154
#define SYS_SEMCTL 155
#define SYS_SIGTIMEDWAIT 221

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello235:   ok   " : "hello235:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile int hits;
static void on_usr1(int s) { (void)s; hits++; }

static long spawn_signaller(long parent) {
    long pid = fork();
    if (pid == 0) {
        struct timespec ts = { 0, 60000000L };
        nanosleep(&ts, 0);
        kill(parent, SIGUSR1);
        _exit(0);
    }
    return pid;
}

struct epev { unsigned int events; unsigned long long data; } __attribute__((packed));
struct sembuf_ { unsigned short sem_num; short sem_op; short sem_flg; };

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello235: handler runs before EINTR\n");
    long me = getpid();
    struct ksigaction act = { on_usr1, 0, (void *)0, 0 };
    sigaction(SIGUSR1, &act, (struct ksigaction *)0);

    /* epoll_wait on an epoll with nothing ready */
    long ep = syscall1(SYS_EPOLL_CREATE1, 0);
    int p[2];
    pipe(p);
    struct epev ev = { 1 /* EPOLLIN */, 0 };
    syscall4(SYS_EPOLL_CTL, ep, 1 /* ADD */, p[0], (long)&ev);
    struct epev out[2];
    hits = 0;
    long kid = spawn_signaller(me);
    long r = syscall4(SYS_EPOLL_WAIT, ep, (long)out, 2, 3000);
    {
        char what[120];
        snprintf(what, sizeof what, "A: epoll_wait is interrupted and the handler had run (r=%ld hits=%d)", r, (int)hits);
        check(r == -EINTR && hits == 1, what);
    }
    waitpid(kid, (int *)0, 0);

    /* futex(FUTEX_WAIT) on a word that matches */
    static volatile int word = 0;
    hits = 0;
    kid = spawn_signaller(me);
    r = syscall6(SYS_FUTEX, (long)&word, 0 /* FUTEX_WAIT */ | 128 /* PRIVATE */, 0, 0, 0, 0);
    {
        char what[120];
        snprintf(what, sizeof what, "B: futex(FUTEX_WAIT) is interrupted and the handler had run (r=%ld hits=%d)", r, (int)hits);
        check(r == -EINTR && hits == 1, what);
    }
    waitpid(kid, (int *)0, 0);

    /* SysV msgrcv does not block in this kernel (an empty queue is EAGAIN at once), so there is nothing for a signal to interrupt;
     * semop does block. The native semop takes (semid, sem_num, op) rather than a struct sembuf array. */
    long sm = syscall3(SYS_SEMGET, 0, 1, 01000 | 0600);
    if (sm >= 0) {
        hits = 0;
        kid = spawn_signaller(me);
        r = syscall3(SYS_SEMOP, sm, 0 /* sem_num */, (long)(short)-1);
        char what[120];
        snprintf(what, sizeof what, "C: semop that must wait is interrupted and the handler had run (r=%ld hits=%d)", r, (int)hits);
        check(r == -EINTR && hits == 1, what);
        waitpid(kid, (int *)0, 0);
        syscall4(SYS_SEMCTL, sm, 0, 0 /* IPC_RMID */, 0);
    } else {
        check(0, "C: semget failed");
    }

    /* rt_sigtimedwait for a signal that does not come, with a handler for SIGUSR1 delivered meanwhile: the wait set is SIGUSR2 */
    unsigned long set = 1UL << (SIGUSR2 - 1);
    struct timespec to = { 3, 0 };
    hits = 0;
    kid = spawn_signaller(me);
    r = syscall4(SYS_SIGTIMEDWAIT, (long)&set, 0, (long)&to, 8);
    {
        char what[120];
        snprintf(what, sizeof what, "D: rt_sigtimedwait is interrupted by another signal's handler and the handler had run (r=%ld hits=%d)", r, (int)hits);
        check(r == -EINTR && hits == 1, what);
    }
    waitpid(kid, (int *)0, 0);

    /* mq_timedreceive on an empty queue with no timeout */
    long mq = syscall4(186 /* mq_open */, (long)"/h235-q", 02 /* O_RDWR */ | 0x40 /* O_CREAT */, 0600, 0);
    if (mq >= 0) {
        char mbuf[8192];
        hits = 0;
        kid = spawn_signaller(me);
        r = syscall5(189 /* mq_timedreceive */, mq, (long)mbuf, sizeof mbuf, 0, 0);
        char what[140];
        snprintf(what, sizeof what, "E: mq_timedreceive on an empty queue is interrupted and the handler had run (r=%ld hits=%d)", r, (int)hits);
        check(r == -EINTR && hits == 1, what);
        waitpid(kid, (int *)0, 0);
        syscall1(187 /* mq_unlink */, (long)"/h235-q");
    } else {
        char what[100];
        snprintf(what, sizeof what, "E: mq_open failed (%ld)", mq);
        check(0, what);
    }

    /* recvmmsg on an AF_UNIX stream socketpair with nothing to read (blocking, no timeout) */
    int sv[2];
    if (syscall4(128 /* socketpair */, 1, 1, 0, (long)sv) == 0) {
        struct { void *base; unsigned long len; } iov1;
        char rb[16];
        iov1.base = rb;
        iov1.len = sizeof rb;
        struct {
            void *name; unsigned int namelen, pad0; void *iov; unsigned long iovlen; void *ctl; unsigned long ctllen;
            unsigned int flags, pad1; unsigned int len, pad;
        } mm;
        memset(&mm, 0, sizeof mm);
        mm.iov = &iov1;
        mm.iovlen = 1;
        hits = 0;
        kid = spawn_signaller(me);
        r = syscall5(134 /* recvmmsg */, sv[0], (long)&mm, 1, 0, 0);
        char what[140];
        snprintf(what, sizeof what, "F: recvmmsg with nothing to read is interrupted and the handler had run (r=%ld hits=%d)", r, (int)hits);
        check(r == -EINTR && hits == 1, what);
        waitpid(kid, (int *)0, 0);
        close(sv[0]);
        close(sv[1]);
    } else {
        check(0, "F: socketpair failed");
    }

    /* connect() to 10.0.2.2:80, the SLIRP gateway, which has no TCP service: the blocking handshake is retransmitted for about two
     * minutes (see hello27), so a handler's signal arrives while connect waits. */
    {
        long cs = syscall3(117 /* socket */, 2 /* AF_INET */, 1 /* SOCK_STREAM */, 0);
        if (cs >= 0) {
            unsigned char sa[16] = { 2, 0, 0, 80, 10, 0, 2, 2, 0 };
            hits = 0;
            kid = spawn_signaller(me);
            r = syscall3(124 /* connect */, cs, (long)sa, 16);
            char what[140];
            snprintf(what, sizeof what, "G: a blocking connect that cannot complete is interrupted and the handler had run (r=%ld hits=%d)", r, (int)hits);
            check(r == -EINTR && hits == 1, what);
            waitpid(kid, (int *)0, 0);
            close((int)cs);
        } else {
            check(0, "G: socket failed");
        }
    }

    print(failures == 0 ? "hello235: PASS\n" : "hello235: FAIL\n");
    return failures;
}
