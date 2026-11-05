/* test_poll_abi.c — poll() and ppoll() (src/poll.c) against a recording system-call stub. The layout and constants are glibc's on
 * x86-64 (measured: sizeof(struct pollfd) 8, fd at 0, events at 4, revents at 6; POLLIN 1, POLLPRI 2, POLLOUT 4, POLLERR 8,
 * POLLHUP 0x10, POLLNVAL 0x20, POLLRDNORM 0x40, POLLRDBAND 0x80, POLLWRNORM 0x100, POLLWRBAND 0x200, POLLRDHUP 0x2000). poll
 * returns the number of descriptors with a non-zero revents, 0 on timeout, and -1 with errno on failure.
 */
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"

struct moqi_pollfd { int fd; short events; short revents; };
int moqi_poll(struct moqi_pollfd *fds, unsigned long nfds, int timeout);
int moqi_ppoll(struct moqi_pollfd *fds, unsigned long nfds, const void *timeout, const void *sigmask);

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static int ncalls;
static long c_nr, c_a1, c_a2, c_a3, c_a4, c_a5;
static long reply;

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a6;
    ncalls++;
    c_nr = nr; c_a1 = a1; c_a2 = a2; c_a3 = a3; c_a4 = a4; c_a5 = a5;
    return reply;
}

int main(void) {
    CHECK(SYS_poll == 162 && SYS_ppoll == 493);
    CHECK(sizeof(struct moqi_pollfd) == 8 && offsetof(struct moqi_pollfd, events) == 4 && offsetof(struct moqi_pollfd, revents) == 6);

    struct moqi_pollfd fds[2] = { { 3, 1, 0 }, { 4, 4, 0 } };

    /* poll passes the array, the count and the timeout through, and returns the kernel's count */
    reply = 1;
    CHECK(moqi_poll(fds, 2, 250) == 1);
    CHECK(ncalls == 1 && c_nr == SYS_poll && c_a1 == (long)fds && c_a2 == 2 && c_a3 == 250);

    /* a negative timeout (wait forever) reaches the kernel as the same C int */
    reply = 0;
    CHECK(moqi_poll(fds, 2, -1) == 0);
    CHECK((int)c_a3 == -1);

    /* nfds 0 is a plain sleep and is passed on */
    CHECK(moqi_poll(NULL, 0, 10) == 0 && c_a2 == 0 && c_a1 == 0);

    /* errors: -1 and errno carries the kernel's code */
    reply = -4; /* EINTR */
    errno_slot = 0;
    CHECK(moqi_poll(fds, 2, 100) == -1 && errno_slot == EINTR);
    reply = -22; /* EINVAL */
    CHECK(moqi_poll(fds, 2, 100) == -1 && errno_slot == EINVAL);
    reply = -14; /* EFAULT */
    CHECK(moqi_poll(fds, 2, 100) == -1 && errno_slot == EFAULT);

    /* ppoll: array, count, timespec, sigmask and the 8-byte mask size */
    long ts[2] = { 1, 500 };
    unsigned long mask = 0;
    reply = 2;
    ncalls = 0;
    CHECK(moqi_ppoll(fds, 2, ts, &mask) == 2);
    CHECK(ncalls == 1 && c_nr == SYS_ppoll && c_a1 == (long)fds && c_a2 == 2 && c_a3 == (long)ts && c_a4 == (long)&mask && c_a5 == 8);

    /* ppoll without a timeout or mask passes NULLs (the kernel ignores the size when there is no mask) */
    c_a5 = 99;
    CHECK(moqi_ppoll(fds, 2, NULL, NULL) == 2 && c_a3 == 0 && c_a4 == 0 && c_a5 == 0);

    reply = -4;
    CHECK(moqi_ppoll(fds, 2, ts, &mask) == -1 && errno_slot == EINTR);

    if (bad) { fprintf(stderr, "%d check(s) failed\n", bad); return 1; }
    printf("test_poll_abi: ok\n");
    return 0;
}
