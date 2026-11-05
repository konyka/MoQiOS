/* test_assert_abi.c — assert.h (include/assert.h, src/assert.c). The failure path is compiled with write and abort replaced
 * by recorders, and the message is compared with what glibc prints for the same source (measured on glibc 2.43):
 *   "<short program name>: <file>:<line>: <function>: Assertion `<expression text>' failed.\n"
 */
#include <setjmp.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* The host's own assert.h must not be the one included. */
#include "../include/assert.h"

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

char *program_invocation_short_name = "prog";
char *program_invocation_name = "/usr/bin/prog";

static char written[1024];
static size_t written_len;
static int write_fd = -1;
static int write_calls;
static jmp_buf out;
static int aborted;

long moqi_write(int fd, const void *buf, size_t n) {
    write_fd = fd;
    write_calls++;
    if (written_len + n < sizeof written) { memcpy(written + written_len, buf, n); written_len += n; }
    return (long)n;
}
void moqi_abort(void) {
    aborted++;
    longjmp(out, 1);
}

static void clear(void) { written_len = 0; written[0] = 0; write_fd = -1; write_calls = 0; aborted = 0; }
static const char *msg(void) { written[written_len] = 0; return written; }

static int line_failing, line_string, line_not;
static void failing(int x) {
    line_failing = __LINE__; assert(x == 1 && x != 0);
}
static void failing_string(void) {
    line_string = __LINE__; assert(0 && "message text");
}
static void failing_not(void) {
    line_not = __LINE__; assert(!"never");
}

static int evaluated;
static int side_effect(void) { evaluated++; return 1; }

int main(void) {
    clear();
    if (setjmp(out) == 0) failing(5);
    CHECK(aborted == 1);
    CHECK(write_fd == 2 && write_calls == 1);
    char want[256];
    snprintf(want, sizeof want, "prog: %s:%d: failing: Assertion `x == 1 && x != 0' failed.\n", __FILE__, line_failing);
    CHECK(strcmp(msg(), want) == 0);

    clear();
    if (setjmp(out) == 0) failing_string();
    snprintf(want, sizeof want, "prog: %s:%d: failing_string: Assertion `0 && \"message text\"' failed.\n", __FILE__, line_string);
    CHECK(strcmp(msg(), want) == 0);

    clear();
    if (setjmp(out) == 0) failing_not();
    snprintf(want, sizeof want, "prog: %s:%d: failing_not: Assertion `!\"never\"' failed.\n", __FILE__, line_not);
    CHECK(strcmp(msg(), want) == 0);

    /* A true assertion does nothing and evaluates its argument once. */
    clear();
    assert(side_effect());
    CHECK(evaluated == 1 && written_len == 0 && aborted == 0);

    /* A long expression is cut to fit, still ending in the failure text and a newline. */
    clear();
    {
        char big[1100];
        memset(big, 'x', sizeof big - 1);
        big[sizeof big - 1] = 0;
        if (setjmp(out) == 0) __assert_fail(big, "f.c", 7, "fn");
        CHECK(aborted == 1);
        CHECK(written_len <= 512 && written_len > 400);
        CHECK(written[written_len - 1] == '\n');
        CHECK(strstr(msg(), "' failed.\n") != NULL);
    }

    /* No function name: the part is left out. */
    clear();
    if (setjmp(out) == 0) __assert_fail("e", "f.c", 7, NULL);
    CHECK(strcmp(msg(), "prog: f.c:7: Assertion `e' failed.\n") == 0);

    /* Line 0 and a large line number. */
    clear();
    if (setjmp(out) == 0) __assert_fail("e", "f.c", 0, "g");
    CHECK(strcmp(msg(), "prog: f.c:0: g: Assertion `e' failed.\n") == 0);
    clear();
    if (setjmp(out) == 0) __assert_fail("e", "f.c", 4294967295u, "g");
    CHECK(strcmp(msg(), "prog: f.c:4294967295: g: Assertion `e' failed.\n") == 0);

    if (bad) { fprintf(stderr, "test_assert_abi: %d failure(s)\n", bad); return 1; }
    printf("test_assert_abi: ok\n");
    return 0;
}
