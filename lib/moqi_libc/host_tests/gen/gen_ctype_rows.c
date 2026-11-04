/* gen_ctype_rows.c — writes test_ctype_rows.inc from the host's glibc in the C locale.
 *
 *   gcc -O1 -o gen gen/gen_ctype_rows.c && ./gen > test_ctype_rows.inc
 *
 * One row per argument value glibc defines: EOF and -128..255 (negative values are signed chars, which glibc treats as the
 * unsigned value 256 + c). For each: a bit mask of the classification functions, then toupper and tolower. Arguments outside
 * that range make glibc read past its tables, so they are not measured. */
#include <ctype.h>
#include <gnu/libc-version.h>
#include <stdio.h>

int main(void) {
    int (*f[])(int) = { isalnum, isalpha, isblank, iscntrl, isdigit, isgraph, islower, isprint, ispunct, isspace, isupper, isxdigit, isascii };
    printf("/* Generated from glibc %s by gen/gen_ctype_rows.c: argument, a bit mask of isalnum isalpha isblank iscntrl isdigit\n"
           " * isgraph islower isprint ispunct isspace isupper isxdigit isascii (bit 0 first), toupper, tolower. */\n",
           gnu_get_libc_version());
    for (int c = -128; c <= 255; c++) {
        unsigned mask = 0;
        for (int k = 0; k < 13; k++) mask |= (f[k](c) != 0) << k;
        printf("ROW(%d, 0x%04x, %d, %d);\n", c, mask, toupper(c), tolower(c));
    }
    return 0;
}
