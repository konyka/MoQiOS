/* test_epoll_abi.c -- epoll_create1, epoll_ctl and epoll_wait (src/epoll.c) against a recording system-call stub. The layout and
 * constants are glibc's on x86-64 (measured): struct epoll_event is a PACKED 12-byte struct (events at 0, data at 4), EPOLLIN 1,
 * EPOLLPRI 2, EPOLLOUT 4, EPOLLERR 8, EPOLLHUP 0x10, EPOLLRDHUP 0x2000, EPOLLEXCLUSIVE 0x10000000, EPOLLONESHOT 0x40000000,
 * EPOLLET 0x80000000, EPOLL_CTL_ADD 1, EPOLL_CTL_DEL 2, EPOLL_CTL_MOD 3, EPOLL_CLOEXEC 0x80000. Every function returns the
 * kernel's value on success (a descriptor, 0, or an event count) and -1 with errno on failure.
 */
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"

#define epoll_event moqi_epoll_event
#define epoll_data moqi_epoll_data
#define epoll_data_t moqi_epoll_data_t
#define epoll_create1 moqi_epoll_create1_decl
#define epoll_ctl moqi_epoll_ctl_decl
#define epoll_wait moqi_epoll_wait_decl
#include "../include/epoll.h"
#undef epoll_event
#undef epoll_data
#undef epoll_data_t
#undef epoll_create1
#undef epoll_ctl
#undef epoll_wait

int moqi_epoll_create1(int flags);
int moqi_epoll_ctl(int epfd, int op, int fd, struct moqi_epoll_event *event);
int moqi_epoll_wait(int epfd, struct moqi_epoll_event *events, int maxevents, int timeout);

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

int main(void) {
    CHECK(SYS_epoll_create1 == 146 && SYS_epoll_ctl == 147 && SYS_epoll_wait == 148);
    CHECK(sizeof(struct moqi_epoll_event) == 12 && offsetof(struct moqi_epoll_event, events) == 0 && offsetof(struct moqi_epoll_event, data) == 4);
    CHECK(EPOLLIN == 1 && EPOLLOUT == 4 && EPOLLERR == 8 && EPOLLHUP == 0x10 && EPOLLRDHUP == 0x2000);
    CHECK(EPOLLEXCLUSIVE == 0x10000000u && EPOLLONESHOT == 0x40000000u && EPOLLET == 0x80000000u);
    CHECK(EPOLL_CTL_ADD == 1 && EPOLL_CTL_DEL == 2 && EPOLL_CTL_MOD == 3 && EPOLL_CLOEXEC == 0x80000);

    /* epoll_create1 passes the flags and returns the descriptor */
    reply = 7;
    CHECK(moqi_epoll_create1(EPOLL_CLOEXEC) == 7);
    CHECK(ncalls == 1 && c_nr == SYS_epoll_create1 && c_a1 == EPOLL_CLOEXEC);

    /* epoll_ctl passes epfd, op, fd and the event pointer (NULL for DEL) */
    struct moqi_epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = EPOLLIN | EPOLLET;
    ev.data.u64 = 0x1122334455667788ULL;
    reply = 0;
    CHECK(moqi_epoll_ctl(7, EPOLL_CTL_ADD, 4, &ev) == 0);
    CHECK(c_nr == SYS_epoll_ctl && c_a1 == 7 && c_a2 == EPOLL_CTL_ADD && c_a3 == 4 && c_a4 == (long)&ev);
    CHECK(moqi_epoll_ctl(7, EPOLL_CTL_DEL, 4, NULL) == 0 && c_a2 == EPOLL_CTL_DEL && c_a4 == 0);

    /* epoll_wait passes the array, the maximum and the timeout (a negative timeout reaches the kernel as the same C int) */
    struct moqi_epoll_event out[4];
    reply = 3;
    CHECK(moqi_epoll_wait(7, out, 4, 250) == 3);
    CHECK(c_nr == SYS_epoll_wait && c_a1 == 7 && c_a2 == (long)out && c_a3 == 4 && c_a4 == 250);
    reply = 0;
    CHECK(moqi_epoll_wait(7, out, 4, -1) == 0 && (int)c_a4 == -1);

    /* errors: -1 and errno carries the kernel's code */
    errno_slot = 0;
    reply = -4;
    CHECK(moqi_epoll_wait(7, out, 4, 100) == -1 && errno_slot == EINTR);
    reply = -9;
    CHECK(moqi_epoll_ctl(99, EPOLL_CTL_ADD, 4, &ev) == -1 && errno_slot == EBADF);
    reply = -22;
    CHECK(moqi_epoll_create1(0x7777) == -1 && errno_slot == EINVAL);
    reply = -17;
    CHECK(moqi_epoll_ctl(7, EPOLL_CTL_ADD, 4, &ev) == -1 && errno_slot == EEXIST);

    if (bad) { fprintf(stderr, "%d check(s) failed\n", bad); return 1; }
    printf("test_epoll_abi: ok\n");
    return 0;
}
