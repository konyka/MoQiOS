/* test_string.c — host unit tests for moqi_libc string/memory routines. */
#include <stdio.h>
#include <string.h> /* system string.h for reference comparisons */

/* Rename libc symbols under test so they don't clash with the host libc. */
#define memcpy  moqi_memcpy
#define memmove moqi_memmove
#define memset  moqi_memset
#define memcmp  moqi_memcmp
#define strlen  moqi_strlen
#define strcmp  moqi_strcmp
#define strncmp moqi_strncmp
#define strcpy  moqi_strcpy
#define strncpy moqi_strncpy
#define strcat  moqi_strcat
#define strchr  moqi_strchr
#define strrchr moqi_strrchr
#include "../src/string.c"

static int failures;
static int checks;

#define CHECK(cond) do { \
    checks++; \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    } \
} while (0)

int main(void) {
    /* memcpy / memset */
    char buf[32];
    moqi_memset(buf, 'A', 16);
    CHECK(moqi_memcmp(buf, "AAAAAAAAAAAAAAAA", 16) == 0);
    moqi_memcpy(buf, "hello", 6);
    CHECK(moqi_strcmp(buf, "hello") == 0);
    CHECK(moqi_memcpy(buf, "xy", 3) == buf);

    /* memmove: overlapping both directions */
    moqi_strcpy(buf, "abcdefgh");
    moqi_memmove(buf + 2, buf, 6);      /* dst > src */
    CHECK(moqi_strcmp(buf, "ababcdef") == 0);
    moqi_strcpy(buf, "abcdefgh");
    moqi_memmove(buf, buf + 2, 6);      /* dst < src */
    CHECK(moqi_strcmp(buf, "cdefghgh") == 0);

    /* memcmp ordering */
    CHECK(moqi_memcmp("abc", "abd", 3) < 0);
    CHECK(moqi_memcmp("abd", "abc", 3) > 0);
    CHECK(moqi_memcmp("abc", "abc", 3) == 0);
    CHECK(moqi_memcmp("abc", "abd", 2) == 0);

    /* strlen */
    CHECK(moqi_strlen("") == 0);
    CHECK(moqi_strlen("12345") == 5);

    /* strcmp / strncmp */
    CHECK(moqi_strcmp("abc", "abc") == 0);
    CHECK(moqi_strcmp("abc", "abd") < 0);
    CHECK(moqi_strcmp("abd", "abc") > 0);
    CHECK(moqi_strcmp("abc", "abcd") < 0);
    CHECK(moqi_strncmp("abcd", "abce", 3) == 0);
    CHECK(moqi_strncmp("abcd", "abce", 4) < 0);
    CHECK(moqi_strncmp("ab", "abc", 5) < 0);

    /* strcpy / strncpy / strcat */
    char d[16];
    CHECK(moqi_strcpy(d, "hi") == d);
    CHECK(moqi_strcmp(d, "hi") == 0);
    moqi_memset(d, 'X', sizeof(d));
    moqi_strncpy(d, "abc", 6);          /* pads with NULs */
    CHECK(d[0] == 'a' && d[3] == 0 && d[5] == 0);
    moqi_strncpy(d, "abcdefghij", 4);   /* no NUL when truncated */
    CHECK(d[0] == 'a' && d[3] == 'd');
    moqi_strcpy(d, "foo");
    CHECK(moqi_strcat(d, "bar") == d);
    CHECK(moqi_strcmp(d, "foobar") == 0);

    /* strchr / strrchr */
    const char *s = "abca";
    CHECK(moqi_strchr(s, 'b') == s + 1);
    CHECK(moqi_strchr(s, 'z') == 0);
    CHECK(moqi_strchr(s, '\0') == s + 4);
    CHECK(moqi_strrchr(s, 'a') == s + 3);
    CHECK(moqi_strrchr(s, 'z') == 0);

    printf("test_string: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
