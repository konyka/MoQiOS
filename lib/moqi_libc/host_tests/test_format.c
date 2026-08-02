/* test_format.c — host unit tests for the moqi_libc printf formatting core.
 *
 * The core (src/format.c) is syscall-free, so it links and runs on the host.
 */
#include <stdio.h>
#include <string.h>

/* Rename under test so it doesn't clash with the host libc snprintf. */
#define snprintf  moqi_snprintf
#define vsnprintf moqi_vsnprintf
#define print     moqi_print_fn
#define putchar   moqi_putchar_fn
#define puts      moqi_puts_fn
#define printf    moqi_printf_fn
#include "../src/format.c"
#undef printf
#undef puts
#undef putchar
#undef print

static int failures;
static int checks;

/* Format with moqi snprintf, compare against expected string and length. */
#define FMT(expected, ...) do { \
    char b[128]; \
    int n = moqi_snprintf(b, sizeof(b), __VA_ARGS__); \
    checks++; \
    if (strcmp(b, expected) != 0) { \
        failures++; \
        printf("FAIL %d: got [%s], want [%s]\n", __LINE__, b, expected); \
    } \
    checks++; \
    if (n != (int)strlen(expected)) { \
        failures++; \
        printf("FAIL %d: len %d, want %d\n", __LINE__, n, (int)strlen(expected)); \
    } \
} while (0)

int main(void) {
    FMT("hello", "hello");
    FMT("100%", "100%%");
    FMT("x=42", "x=%d", 42);
    FMT("x=-42", "x=%d", -42);
    FMT("0", "%d", 0);
    FMT("-2147483648", "%d", (-2147483647 - 1));
    FMT("7", "%i", 7);
    FMT("4000000000", "%u", 4000000000u);
    FMT("ff", "%x", 255);
    FMT("FF", "%X", 255);
    FMT("0", "%x", 0);
    FMT("c=A", "c=%c", 'A');
    FMT("s=(null)", "s=%s", (char *)0);
    FMT("s=abc", "s=%s", "abc");
    FMT("1234567890123", "%ld", 1234567890123L);
    FMT("-1234567890123", "%ld", -1234567890123L);
    FMT("18446744073709551615", "%lu", 18446744073709551615UL);
    FMT("deadbeefcafe", "%lx", 0xdeadbeefcafeUL);
    FMT("-1", "%lld", -1LL);
    FMT("mix 1 -2 ff z 9", "mix %d %d %x %c %d", 1, -2, 255, 'z', 9);

    /* %p: kernel-style programs only print it; require 0x prefix + hex */
    {
        char b[64];
        int n = moqi_snprintf(b, sizeof(b), "%p", (void *)0x1234abcdUL);
        checks++;
        if (strcmp(b, "0x1234abcd") != 0) {
            failures++;
            printf("FAIL %%p: got [%s]\n", b);
        }
        checks++;
        if (n != (int)strlen(b)) { failures++; printf("FAIL %%p len\n"); }
    }
    {
        char b[64];
        moqi_snprintf(b, sizeof(b), "%p", (void *)0);
        checks++;
        if (strcmp(b, "(nil)") != 0) { failures++; printf("FAIL %%p nil: [%s]\n", b); }
    }

    /* Truncation: returns would-be length, output always NUL-terminated */
    {
        char b[8];
        int n = moqi_snprintf(b, sizeof(b), "abcdefghij");
        checks++;
        if (n != 10) { failures++; printf("FAIL trunc len %d\n", n); }
        checks++;
        if (strcmp(b, "abcdefg") != 0) { failures++; printf("FAIL trunc buf [%s]\n", b); }
    }
    {
        char b[4] = {'x','x','x','x'};
        int n = moqi_snprintf(b, 0, "abc");  /* size 0: no write */
        checks++;
        if (n != 3 || b[0] != 'x') { failures++; printf("FAIL size0\n"); }
    }

    printf("test_format: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
