/* hello336: edge-triggered epoll on a POSIX mq descriptor reports again after every send and receive (Linux mqueue: each
 * mq_timedsend / mq_timedreceive wakes info->wait_q, so EPOLLET re-arms even when readiness did not change).
 * Measured on the host (build with -DHOST):
 *   A. EPOLLIN|EPOLLOUT|EPOLLET on an empty queue: EPOLLOUT once on add, then nothing;
 *   B. send 1 -> IN|OUT, send 2 (full) -> IN, receive -> IN|OUT, receive (empty) -> OUT (reported again though OUT was ready);
 *   C. EPOLLIN|EPOLLET only: nothing on add (empty), IN after a send, nothing after the receive that empties it;
 *   D. EPOLLOUT|EPOLLET only on a full queue: nothing on add, OUT after a receive, OUT again after the next receive. */
#ifdef HOST
#define _GNU_SOURCE
#include <fcntl.h>
#include <mqueue.h>
#include <stdio.h>
#include <sys/epoll.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/epoll.h"
typedef int mqd_t;
struct mq_attr { long mq_flags, mq_maxmsg, mq_msgsize, mq_curmsgs; };
static mqd_t mq_open(const char *n, int flags, int mode, struct mq_attr *a) { return (mqd_t)syscall4(186, (long)n, flags, mode, (long)a); }
static int mq_send(mqd_t q, const char *m, long len, unsigned p) { return (int)syscall5(188, q, (long)m, len, p, 0); }
static long mq_receive(mqd_t q, char *b, long len, unsigned *p) { return syscall5(189, q, (long)b, len, (long)p, 0); }
static int mq_unlink(const char *n) { return (int)syscall1(187, (long)n); }
#ifndef O_CREAT
#define O_CREAT 0x40
#endif
#ifndef O_RDWR
#define O_RDWR 02
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 04000
#endif
#endif

#define IN 0x1
#define OUT 0x4
#define ET (1u << 31)

static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello336:   ok   " : "hello336:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}

/* The events of the one ready item, 0 when none, -1000 on error. */
static int ev(int ep) {
    struct epoll_event e[2];
    int n = epoll_wait(ep, e, 2, 0);
    if (n < 0) return -1000;
    return n == 0 ? 0 : (int)e[0].events;
}

static int watch(mqd_t q, unsigned events) {
    int ep = epoll_create1(0);
    struct epoll_event e;
    e.events = events;
    e.data.u64 = 0;
    epoll_ctl(ep, EPOLL_CTL_ADD, (int)q, &e);
    return ep;
}

int main(void) {
    print("hello336: edge-triggered epoll on an mq descriptor reports after every send and receive\n");
    mq_unlink("/mq336");
    struct mq_attr a = { 0, 2, 16, 0 };
    mqd_t q = mq_open("/mq336", O_RDWR | O_CREAT | O_NONBLOCK, 0600, &a);
    char b[16];

    int ep = watch(q, IN | OUT | ET);
    int a1 = ev(ep), a2 = ev(ep);
    snprintf(msg, sizeof msg, "A: IN|OUT|ET on an empty queue: add 0x%x, then %d", a1, a2);
    check(a1 == OUT && a2 == 0, msg);

    mq_send(q, "a", 1, 0);
    int b1 = ev(ep);
    mq_send(q, "b", 1, 0);
    int b2 = ev(ep);
    mq_receive(q, b, 16, 0);
    int b3 = ev(ep);
    mq_receive(q, b, 16, 0);
    int b4 = ev(ep);
    snprintf(msg, sizeof msg, "B: send 0x%x, send (full) 0x%x, receive 0x%x, receive (empty) 0x%x", b1, b2, b3, b4);
    check(b1 == (IN | OUT) && b2 == IN && b3 == (IN | OUT) && b4 == OUT, msg);

    int ep2 = watch(q, IN | ET);
    int c1 = ev(ep2);
    mq_send(q, "a", 1, 0);
    int c2 = ev(ep2);
    mq_receive(q, b, 16, 0);
    int c3 = ev(ep2);
    snprintf(msg, sizeof msg, "C: IN|ET: add %d, send 0x%x, receive (empty) %d", c1, c2, c3);
    check(c1 == 0 && c2 == IN && c3 == 0, msg);

    mq_send(q, "a", 1, 0);
    mq_send(q, "b", 1, 0);
    int ep3 = watch(q, OUT | ET);
    int d1 = ev(ep3);
    mq_receive(q, b, 16, 0);
    int d2 = ev(ep3);
    mq_receive(q, b, 16, 0);
    int d3 = ev(ep3);
    snprintf(msg, sizeof msg, "D: OUT|ET on a full queue: add %d, receive 0x%x, receive again 0x%x", d1, d2, d3);
    check(d1 == 0 && d2 == OUT && d3 == OUT, msg);

    close(ep3);
    close(ep2);
    close(ep);
    close((int)q);
    mq_unlink("/mq336");
    print(failures ? "hello336: FAIL\n" : "hello336: PASS\n");
    return failures ? 1 : 0;
}
