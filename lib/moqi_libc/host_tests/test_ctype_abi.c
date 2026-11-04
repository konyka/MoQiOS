/* test_ctype_abi.c — include/ctype.h checked against glibc over every defined argument. test_ctype_rows.inc has one row for
 * EOF and each of -128..255 (the whole domain, so this is a proof, not a sample): the classification functions as a bit mask,
 * then toupper and tolower. The functions are header-only, so the test includes the library's header and not the host's. */
#include <stdio.h>
#include <string.h>

#include "../include/ctype.h"

static int bad;
static int rows;

static void check_row(int c, unsigned mask, int up, int low) {
    rows++;
    int got[13] = { isalnum(c) != 0, isalpha(c) != 0, isblank(c) != 0, iscntrl(c) != 0, isdigit(c) != 0, isgraph(c) != 0, islower(c) != 0,
                    isprint(c) != 0, ispunct(c) != 0, isspace(c) != 0, isupper(c) != 0, isxdigit(c) != 0, isascii(c) != 0 };
    static const char *const names[13] = { "isalnum", "isalpha", "isblank", "iscntrl", "isdigit", "isgraph", "islower",
                                           "isprint", "ispunct", "isspace", "isupper", "isxdigit", "isascii" };
    for (int k = 0; k < 13; k++) {
        if (got[k] != (int)((mask >> k) & 1)) {
            fprintf(stderr, "%s(%d) = %d, glibc says %d\n", names[k], c, got[k], (int)((mask >> k) & 1));
            bad++;
        }
    }
    if (toupper(c) != up) {
        fprintf(stderr, "toupper(%d) = %d, glibc says %d\n", c, toupper(c), up);
        bad++;
    }
    if (tolower(c) != low) {
        fprintf(stderr, "tolower(%d) = %d, glibc says %d\n", c, tolower(c), low);
        bad++;
    }
}
#define ROW(c, mask, up, low) check_row(c, mask, up, low)

int main(void) {
#include "test_ctype_rows.inc"
    /* EOF is -1, which is one of the rows above (glibc: nothing is true, both mappings return EOF). */
    if (rows != 384) {
        fprintf(stderr, "expected 384 rows, ran %d\n", rows);
        bad++;
    }
    /* Arguments outside EOF and 0..255 (and the signed-char range) are undefined for glibc, which reads past its tables. Here
     * they must be safe: nothing is a character, and case mapping leaves them alone. */
    static const int outside[] = { -129, -200, -1000, 256, 257, 300, 1000, 65535, 0x10ffff, 0x7fffffff, (int)0x80000000, -0x7fffffff };
    for (unsigned i = 0; i < sizeof outside / sizeof outside[0]; i++) {
        int c = outside[i];
        if (isalnum(c) || isalpha(c) || isblank(c) || iscntrl(c) || isdigit(c) || isgraph(c) || islower(c) || isprint(c) || ispunct(c) ||
            isspace(c) || isupper(c) || isxdigit(c) || isascii(c)) {
            fprintf(stderr, "a classification of %d is true\n", c);
            bad++;
        }
        if (toupper(c) != c || tolower(c) != c) {
            fprintf(stderr, "case mapping of %d changed it\n", c);
            bad++;
        }
    }
    /* toascii masks to seven bits. */
    if (toascii(0x141) != 0x41 || toascii(-1) != 0x7f || toascii(200) != 72 || toascii(65) != 65) {
        fprintf(stderr, "toascii\n");
        bad++;
    }
    /* They are real functions: usable through a pointer, and callable with the parentheses form that bypasses a macro. */
    int (*pf)(int) = isalpha;
    if (!pf('q') || pf('1') || !(isdigit)('7') || (toupper)('b') != 'B') {
        fprintf(stderr, "function pointer / parenthesised calls\n");
        bad++;
    }
    if (bad) {
        fprintf(stderr, "test_ctype_abi: %d failures\n", bad);
        return 1;
    }
    printf("test_ctype_abi OK (%d rows, every defined argument)\n", rows);
    return 0;
}
