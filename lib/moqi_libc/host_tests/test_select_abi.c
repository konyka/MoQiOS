/* test_select_abi.c -- select() (src/select.c) and the fd_set macros of include/select.h against a recording system-call stub.
 * The layout is glibc's on x86-64 (measured): sizeof(fd_set) is 128 bytes, FD_SETSIZE is 1024, descriptor n is bit n % 64 of the
 * 64-bit word n / 64 (FD_SET(3) makes word 0 equal to 0x8, FD_SET(65) makes word 1 equal to 0x2). select returns the number of
 * ready descriptors, 0 on timeout and -1 with errno on failure.
 */
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"

/* The host's names are not wanted: the library's are compiled as moqi_select and the header's macros are used under moqi_ names. */
#define fd_set moqi_fd_set
#define timeval moqi_timeval
#define select moqi_select_decl
#include "../include/select.h"
#undef select
#undef fd_set
#undef timeval

int moqi_select(int nfds, void *r, void *w, void *x, void *tv);

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
    CHECK(SYS_select == 163);
    CHECK(sizeof(moqi_fd_set) == 128 && FD_SETSIZE == 1024);

    moqi_fd_set s;
    FD_ZERO(&s);
    unsigned long *w = (unsigned long *)&s;
    CHECK(w[0] == 0 && w[1] == 0 && w[15] == 0);
    FD_SET(3, &s);
    FD_SET(65, &s);
    FD_SET(1023, &s);
    CHECK(w[0] == 0x8UL && w[1] == 0x2UL && w[15] == (1UL << 63));
    CHECK(FD_ISSET(3, &s) && FD_ISSET(65, &s) && FD_ISSET(1023, &s));
    CHECK(!FD_ISSET(4, &s) && !FD_ISSET(64, &s) && !FD_ISSET(0, &s));
    FD_CLR(3, &s);
    CHECK(w[0] == 0 && !FD_ISSET(3, &s) && FD_ISSET(65, &s));
    FD_CLR(3, &s);
    CHECK(w[0] == 0);
    FD_ZERO(&s);
    CHECK(w[1] == 0 && w[15] == 0);

    /* select passes the five arguments through and returns the kernel's count */
    moqi_fd_set rs, ws, xs;
    FD_ZERO(&rs);
    FD_ZERO(&ws);
    FD_ZERO(&xs);
    long tv[2] = { 1, 500 };
    reply = 2;
    CHECK(moqi_select(9, &rs, &ws, &xs, tv) == 2);
    CHECK(ncalls == 1 && c_nr == SYS_select && c_a1 == 9 && c_a2 == (long)&rs && c_a3 == (long)&ws && c_a4 == (long)&xs && c_a5 == (long)tv);

    /* NULL sets and a NULL timeout (wait forever) are passed as NULLs */
    reply = 0;
    CHECK(moqi_select(0, NULL, NULL, NULL, NULL) == 0);
    CHECK(c_a1 == 0 && c_a2 == 0 && c_a3 == 0 && c_a4 == 0 && c_a5 == 0);

    /* errors: -1 and errno carries the kernel's code */
    reply = -4;
    errno_slot = 0;
    CHECK(moqi_select(5, &rs, NULL, NULL, tv) == -1 && errno_slot == EINTR);
    reply = -22;
    CHECK(moqi_select(5, &rs, NULL, NULL, tv) == -1 && errno_slot == EINVAL);
    reply = -9;
    CHECK(moqi_select(5, &rs, NULL, NULL, tv) == -1 && errno_slot == EBADF);

    if (bad) { fprintf(stderr, "%d check(s) failed\n", bad); return 1; }
    printf("test_select_abi: ok\n");
    return 0;
}
