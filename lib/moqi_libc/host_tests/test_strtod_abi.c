/* test_strtod_abi.c — strtod, strtof and atof checked against glibc. test_strtod_rows.inc holds ~970 rows measured on
 * glibc: the input text, then for strtod the exact result bits, errno and number of characters used, and the same three
 * for strtof. Everything is compared bit for bit (NaN payloads and the sign of zero included). The rest are the checks a
 * table cannot hold: errno left alone on success, a NULL end pointer, atof. */
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../include/errno.h"
#include "../include/stdlib.h"

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static int bad;
static int row_no;

static void check_row(const char *in, uint64_t dbits, int derr, long dused, uint32_t fbits, int ferr, long fused) {
    row_no++;
    char *e;
    errno_slot = 0;
    double d = strtod(in, &e);
    uint64_t got;
    memcpy(&got, &d, 8);
    if (got != dbits || errno_slot != derr || (e - in) != dused) {
        fprintf(stderr, "row %d strtod(\"%s\"): bits want %016llx got %016llx, errno want %d got %d, used want %ld got %ld\n", row_no, in,
                (unsigned long long)dbits, (unsigned long long)got, derr, errno_slot, dused, (long)(e - in));
        bad++;
    }
    errno_slot = 0;
    float f = strtof(in, &e);
    uint32_t gf;
    memcpy(&gf, &f, 4);
    if (gf != fbits || errno_slot != ferr || (e - in) != fused) {
        fprintf(stderr, "row %d strtof(\"%s\"): bits want %08x got %08x, errno want %d got %d, used want %ld got %ld\n", row_no, in, fbits, gf, ferr,
                errno_slot, fused, (long)(e - in));
        bad++;
    }
}
#define ROW(in, db, de, du, fb, fe, fu) check_row(in, db, de, du, fb, fe, fu)

int main(void) {
#include "test_strtod_rows.inc"
    /* Cases aimed at the digits past the 800 kept, tie-breaking tails, NaN payload bits and "nothing converted". */
#include "test_strtod_extra.inc"
    /* Every mantissa shape just under a power of two at the exponents around the normal/subnormal edge of both formats. */
#include "test_strtod_bound.inc"
    /* Inputs with 750-1500 significant digits, around the exact halfway point below the smallest subnormal. */
#include "test_strtod_long.inc"
    /* The first nonzero digit after an exact halfway case lands at significant digit 790..805, around the 800 kept. */
#include "test_strtod_cap.inc"

    /* errno is left alone when nothing goes wrong, and when nothing was converted. */
    errno_slot = 77;
    (void)strtod("5", (char **)0);
    assert(errno_slot == 77);
    (void)strtod("abc", (char **)0);
    assert(errno_slot == 77);
    (void)strtof("  ", (char **)0);
    assert(errno_slot == 77);
    (void)strtod("1e999", (char **)0);
    assert(errno_slot == ERANGE);

    /* A NULL end pointer is fine; the end pointer of "nothing converted" is the start of the string, spaces included. */
    {
        char *e = (char *)1;
        const char *s = "   x";
        (void)strtod(s, &e);
        assert(e == s);
        e = (char *)1;
        (void)strtof("-", &e);
        assert(e != (char *)1);
    }

    /* atof is strtod without the end pointer: the same value and the same errno. */
    {
        uint64_t b;
        errno_slot = 0;
        double d = atof("  -2.5e1z");
        memcpy(&b, &d, 8);
        assert(b == 0xc039000000000000ULL && errno_slot == 0);
        errno_slot = 0;
        d = atof("1e999");
        memcpy(&b, &d, 8);
        assert(b == 0x7ff0000000000000ULL && errno_slot == ERANGE);
        errno_slot = 0;
        d = atof("nan(7)");
        memcpy(&b, &d, 8);
        assert(b == 0x7ff8000000000007ULL);
        d = atof("-0");
        memcpy(&b, &d, 8);
        assert(b == 0x8000000000000000ULL); /* the sign of a negative zero survives atof */
        d = atof("-0.0e5");
        memcpy(&b, &d, 8);
        assert(b == 0x8000000000000000ULL);
        d = atof("");
        memcpy(&b, &d, 8);
        assert(b == 0);
    }

    if (bad) {
        fprintf(stderr, "test_strtod_abi: %d failures\n", bad);
        return 1;
    }
    printf("test_strtod_abi: %d rows OK\n", row_no);
    return 0;
}
