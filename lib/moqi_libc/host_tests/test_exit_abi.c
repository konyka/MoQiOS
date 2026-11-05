/* test_exit_abi.c — atexit, exit and _Exit (include/stdlib.h, src/stdlib.c).
 *
 * stdlib.c is compiled under other names (-Dexit=moqi_exit -Datexit=moqi_atexit -D_exit=moqi__exit -D_Exit=moqi__Exit, see
 * run_tests.sh) so it cannot collide with the host's. The process exit is a stub that records the status and jumps back here.
 * The expectations are what glibc does for the same sequences (measured): handlers run last-registered first, an exit() called
 * from a handler carries on with the handlers that are left and its status wins, a handler may register another handler (it
 * runs next), a function registered twice runs twice, a hundred registrations succeed, and the stdio buffers are flushed after
 * the last handler, never before. _Exit runs neither handlers nor the flush.
 */
#include <errno.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/stdlib.h"

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }
long yield(void) { return 0; }

/* The allocator behind the handler list beyond its first block: the host's, with a switch that makes it fail. */
static int malloc_fails;
void *test_malloc(size_t n) {
    if (malloc_fails) { errno_slot = ENOMEM; return NULL; }
    return calloc(1, n);
}
void test_free(void *p) { free(p); }

/* ---- the process exit and the stdio flush are recorded --------------------------------------------------------------- */

static jmp_buf out;
static int exit_status = -1;
static int exit_calls;
void moqi__exit(int code) {
    exit_calls++;
    exit_status = code;
    longjmp(out, 1);
}

static char trace[512];
static void mark(const char *s) { strcat(trace, s); }
int fflush_all(void) { mark("F"); return 0; }

/* Run f() until the process "exits"; returns with trace and exit_status filled in. */
static void run(void (*f)(void)) {
    trace[0] = 0;
    exit_status = -1;
    exit_calls = 0;
    if (setjmp(out) == 0) f();
}

static void ha(void) { mark("a"); }
static void hb(void) { mark("b"); }
static void hc(void) { mark("c"); }

static void t_plain(void) { exit(3); }
static void t_order(void) {
    CHECK(atexit(ha) == 0 && atexit(hb) == 0 && atexit(hc) == 0);
    exit(4);
}
static void t_twice(void) { atexit(ha); atexit(ha); exit(0); }

static void h_exit_again(void) { mark("X"); exit(77); }
static void t_exit_in_handler(void) {
    atexit(ha);
    atexit(h_exit_again);
    atexit(hb);
    exit(5);
}

static void h_register(void) { mark("R"); atexit(ha); }
static void t_register_in_handler(void) {
    atexit(hb);
    atexit(h_register);
    exit(0);
}

static int ran100;
static void h100(void) { ran100++; }
static void t_many(void) {
    int ok = 1;
    for (int i = 0; i < 100; i++) ok &= (atexit(h100) == 0);
    CHECK(ok);
    exit(0);
}

static void t_null(void) {
    errno_slot = 0;
    int r = atexit((void (*)(void))0);
    CHECK(r != 0);
    CHECK(errno_slot == EINVAL);
    exit(1);
}

static void t__Exit(void) { atexit(ha); _Exit(9); }

static void t_alloc_fail(void) {
    int ok = 0;
    for (int i = 0; i < 32; i++) ok += (atexit(ha) == 0);
    CHECK(ok == 32);
    malloc_fails = 1;
    errno_slot = 0;
    int r = atexit(hb);
    CHECK(r != 0);
    CHECK(errno_slot == ENOMEM);
    malloc_fails = 0;
    CHECK(atexit(hc) == 0);
    exit(0);
}

static void t_empty_after(void) { exit(11); }

int main(void) {
    run(t_plain);
    CHECK(exit_status == 3 && exit_calls == 1);
    CHECK(strcmp(trace, "F") == 0);

    run(t_order);
    CHECK(exit_status == 4);
    CHECK(strcmp(trace, "cbaF") == 0);

    run(t_twice);
    CHECK(strcmp(trace, "aaF") == 0);

    run(t_exit_in_handler);
    CHECK(exit_status == 77);
    CHECK(strcmp(trace, "bXaF") == 0);
    CHECK(exit_calls == 1);

    run(t_register_in_handler);
    CHECK(exit_status == 0);
    CHECK(strcmp(trace, "RabF") == 0);

    ran100 = 0;
    run(t_many);
    CHECK(ran100 == 100);
    CHECK(exit_status == 0);

    run(t_null);
    CHECK(exit_status == 1);
    CHECK(strcmp(trace, "F") == 0);

    run(t_alloc_fail);
    CHECK(exit_status == 0);
    {
        char want[64] = "c";
        for (int i = 0; i < 32; i++) strcat(want, "a");
        strcat(want, "F");
        CHECK(strcmp(trace, want) == 0);
    }

    run(t_empty_after);
    CHECK(exit_status == 11);
    CHECK(strcmp(trace, "F") == 0);

    /* _Exit last: it leaves the function it was given registered and unrun. */
    run(t__Exit);
    CHECK(exit_status == 9);
    CHECK(trace[0] == 0);

    if (bad) { fprintf(stderr, "test_exit_abi: %d failure(s)\n", bad); return 1; }
    printf("test_exit_abi: ok\n");
    return 0;
}
