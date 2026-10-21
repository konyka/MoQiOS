/* test_stdlib.c — host tests for stdlib.c (getenv/atoi). getenv's boundary
 * matching (prefix vs exact, missing '=') decides every environment lookup,
 * so it gets the same coverage discipline as string.c. */
#include <assert.h>
#include <string.h>

/* stdlib.c references the crt0-provided `environ`; give the host build a
 * definition and point it at the fixture in main(). */
char **environ = (char **)0;

#include "../src/stdlib.c"

static char *env_table[] = {
    "PATH=/bin",
    "PATH_EXTRA=/oops",
    "EMPTY=",
    "NOEQ",
    "K=V",
    (char *)0,
};

int main(void) {
    environ = env_table;

    /* Exact match wins even when a prefix entry appears earlier. */
    assert(strcmp(getenv("PATH"), "/bin") == 0);
    /* Prefix-only names must NOT match the longer entry. */
    assert(getenv("PATH_EX") == (char *)0);
    assert(getenv("PATH_EXTRA") == (char *)0);
    /* Empty value is still found. */
    assert(strcmp(getenv("EMPTY"), "") == 0);
    /* An entry without '=' is never a match, and does not stop the scan. */
    assert(strcmp(getenv("K"), "V") == 0);
    /* Degenerate inputs. */
    assert(getenv((const char *)0) == (char *)0);
    assert(getenv("") == (char *)0);
    assert(getenv("MISSING") == (char *)0);

    /* atoi: sign, whitespace, non-numeric tail, degenerate inputs. */
    assert(atoi("42") == 42);
    assert(atoi("  -17x") == -17);
    assert(atoi("+7") == 7);
    assert(atoi("") == 0);
    assert(atoi("abc") == 0);
    assert(atoi("2147483647") == 2147483647);

    return 0;
}
