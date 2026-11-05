/* With NDEBUG defined assert expands to nothing and does not evaluate its argument; including the header again without NDEBUG
 * turns it back on (the C standard says each inclusion takes effect). */
#include <stdio.h>

#include "../include/assert.h"

static int evaluated;
static int aborted;
void __assert_fail(const char *expr, const char *file, unsigned int line, const char *function) {
    (void)expr; (void)file; (void)line; (void)function;
    aborted++;
    for (;;) { }
}
static int touch(void) { evaluated++; return 1; }

int main(void) {
    assert(touch());                      /* NDEBUG is not defined here: evaluated once */
    if (evaluated != 1) { fprintf(stderr, "assert did not evaluate its argument\n"); return 1; }
#define NDEBUG
#include "../include/assert.h"
    assert(touch());                      /* NDEBUG: nothing */
    assert(0);
    if (evaluated != 1) { fprintf(stderr, "NDEBUG assert evaluated its argument\n"); return 1; }
#undef NDEBUG
#include "../include/assert.h"
    assert(touch());                      /* and on again */
    if (evaluated != 2) { fprintf(stderr, "assert after #undef NDEBUG did not evaluate\n"); return 1; }
    static_assert(sizeof(int) == 4, "int is 4");
    (void)aborted;
    printf("test_assert_ndebug: ok\n");
    return 0;
}
