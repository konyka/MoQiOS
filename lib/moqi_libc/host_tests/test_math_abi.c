/* test_math_abi.c — include/math.h and src/math.c checked against glibc.
 *
 * test_math_rows.inc holds about 22000 calls whose results are exactly defined (sqrt, rounding, fmod, remainder, remquo,
 * fmax/fmin/fdim, nextafter, copysign, ldexp/scalbn, frexp, modf, lround/lrint and their long long forms, fabs), each with the
 * argument and result bit patterns and errno as glibc left it; they are compared bit for bit. A result that is a NaN is only
 * required to be a quiet NaN: which NaN an invalid operation produces (its sign and payload) is the hardware's choice.
 * The rest is what a table cannot say: the classification macros and the constants.
 */
#include <errno.h>
#include <float.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../include/math.h"

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static uint64_t B(double d) {
    uint64_t u;
    memcpy(&u, &d, 8);
    return u;
}
static double D(uint64_t u) {
    double d;
    memcpy(&d, &u, 8);
    return d;
}
static int is_nan_bits(uint64_t u) { return (u & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL && (u & 0x000fffffffffffffULL) != 0; }
static int is_quiet_nan_bits(uint64_t u) { return is_nan_bits(u) && (u & 0x0008000000000000ULL) != 0; }

static int bad, row_no;
static void fail(const char *what, uint64_t got, uint64_t want, int err, int want_err) {
    if (bad < 40)
        fprintf(stderr, "row %d %s: result %016llx (errno %d), glibc %016llx (errno %d)\n", row_no, what, (unsigned long long)got, err,
                (unsigned long long)want, want_err);
    bad++;
}
static int same(uint64_t got, uint64_t want) {
    if (want == 0x7ff8000000000000ULL) return is_quiet_nan_bits(got); /* glibc returned a quiet NaN: any quiet NaN */
    if (want == 0x7ff0000000000001ULL) return is_nan_bits(got);       /* a signaling NaN passed through: any NaN */
    return got == want;
}

/* The rows are data, not code: one static array and one loop. (As 22000 expanded statements this file took three minutes to
 * compile at -O1 on a cold cache.) */
enum kind { K_D1, K_D2, K_DI, K_L1, K_FREXP, K_MODF, K_REMQUO };
struct row {
    enum kind kind;
    const char *name;
    union {
        double (*d1)(double);
        double (*d2)(double, double);
        double (*di)(double, int);
        long long (*l1)(double);
    } f;
    uint64_t a, b;
    long long n;     /* the int argument (DI), the expected integer result (L1), exponent (FREXP) or quotient (REMQUO) */
    uint64_t r, r2;  /* the expected result; for MODF the integral part is r2 */
    int e;
};

static long long w_lround(double x) { return lround(x); }
static long long w_llround(double x) { return llround(x); }
static long long w_lrint(double x) { return lrint(x); }
static long long w_llrint(double x) { return llrint(x); }

#define D1(fn, a, r, e) { K_D1, #fn, { .d1 = fn }, a, 0, 0, r, 0, e },
#define D2(fn, a, b, r, e) { K_D2, #fn, { .d2 = fn }, a, b, 0, r, 0, e },
#define DI(fn, a, n, r, e) { K_DI, #fn, { .di = fn }, a, 0, n, r, 0, e },
#define L1(fn, a, r, e) { K_L1, #fn, { .l1 = w_##fn }, a, 0, r, 0, 0, e },
#define FREXP(a, mant, ex) { K_FREXP, "frexp", { .d1 = 0 }, a, 0, ex, mant, 0, 0 },
#define MODF(a, frac, ip) { K_MODF, "modf", { .d1 = 0 }, a, 0, 0, frac, ip, 0 },
#define REMQUO(a, b, r, qq, e) { K_REMQUO, "remquo", { .d1 = 0 }, a, b, qq, r, 0, e },

static const struct row table[] = {
#include "test_math_rows.inc"
};

static void run_row(const struct row *t) {
    row_no++;
    errno_slot = 0;
    switch (t->kind) {
    case K_D1: {
        double g = t->f.d1(D(t->a));
        if (!same(B(g), t->r) || errno_slot != t->e) fail(t->name, B(g), t->r, errno_slot, t->e);
        break;
    }
    case K_D2: {
        double g = t->f.d2(D(t->a), D(t->b));
        if (!same(B(g), t->r) || errno_slot != t->e) fail(t->name, B(g), t->r, errno_slot, t->e);
        break;
    }
    case K_DI: {
        double g = t->f.di(D(t->a), (int)t->n);
        if (!same(B(g), t->r) || errno_slot != t->e) fail(t->name, B(g), t->r, errno_slot, t->e);
        break;
    }
    case K_L1: {
        long long g = t->f.l1(D(t->a));
        if (g != t->n || errno_slot != t->e) fail(t->name, (uint64_t)g, (uint64_t)t->n, errno_slot, t->e);
        break;
    }
    case K_FREXP: {
        int e = 12345;
        double g = frexp(D(t->a), &e);
        int ex = (int)t->n;
        if (!same(B(g), t->r) || (e != ex && !(e == 12345 && ex == 0))) fail("frexp", B(g), t->r, e, ex);
        break;
    }
    case K_MODF: {
        double i = 99;
        double g = modf(D(t->a), &i);
        if (!same(B(g), t->r) || !same(B(i), t->r2)) fail("modf", B(g), t->r, 0, 0);
        break;
    }
    default: {
        /* remquo stores the low three bits of the quotient with its sign (glibc: exactly that, 0..7 or -7..0); when the result is
         * a NaN the quotient is not stored at all, which the table records as 0 and */
        int q = 12345;
        double g = remquo(D(t->a), D(t->b), &q);
        int qexp = (int)t->n;
        int ok_q = q == qexp; /* 12345 in the table: the quotient is not written */
        if (!same(B(g), t->r) || errno_slot != t->e || !ok_q) fail("remquo", B(g), t->r, q, qexp);
        break;
    }
    }
}

int main(void) {
    for (unsigned i = 0; i < sizeof table / sizeof table[0]; i++) run_row(&table[i]);
    int table_rows = row_no;

    /* ---- the classification macros and the constants (values measured on glibc) ---- */
    {
        volatile double sn = D(0x7ff0000000000001ULL), pn = D(0x7ff8000000000123ULL), tiny = 5e-324, mn = DBL_MIN, nz = -0.0, ninf = -INFINITY;
        if (fpclassify(1.0) != FP_NORMAL || fpclassify(0.0) != FP_ZERO || fpclassify(nz) != FP_ZERO || fpclassify(pn) != FP_NAN || fpclassify(sn) != FP_NAN ||
            fpclassify(INFINITY) != FP_INFINITE || fpclassify(tiny) != FP_SUBNORMAL || fpclassify(mn) != FP_NORMAL || fpclassify(mn / 2) != FP_SUBNORMAL) {
            fprintf(stderr, "fpclassify\n");
            bad++;
        }
        if (FP_NAN != 0 || FP_INFINITE != 1 || FP_ZERO != 2 || FP_SUBNORMAL != 3 || FP_NORMAL != 4) {
            fprintf(stderr, "FP_ constants\n");
            bad++;
        }
        if (!isnan(pn) || !isnan(sn) || isnan(1.0) || isnan(INFINITY) || isinf(1.0) || isinf(ninf) != -1 || isinf(INFINITY) != 1 || isinf(pn)) {
            fprintf(stderr, "isnan/isinf\n");
            bad++;
        }
        if (!isfinite(1.0) || isfinite(INFINITY) || isfinite(pn) || !isfinite(tiny) || !isnormal(1.0) || isnormal(tiny) || isnormal(0.0) || !isnormal(mn)) {
            fprintf(stderr, "isfinite/isnormal\n");
            bad++;
        }
        if (!signbit(nz) || signbit(0.0) || !signbit(ninf) || signbit(1.0) || !signbit(-1.0)) {
            fprintf(stderr, "signbit\n");
            bad++;
        }
        if (isgreater(1.0, (double)NAN) || !isless(1.0, 2.0) || !isunordered((double)NAN, 1.0) || !islessgreater(1.0, 2.0) || !isgreaterequal(2.0, 2.0) ||
            !islessequal(2.0, 2.0) || isunordered(1.0, 2.0) || islessgreater(1.0, 1.0)) {
            fprintf(stderr, "comparison macros\n");
            bad++;
        }
        if (B(HUGE_VAL) != 0x7ff0000000000000ULL || B(INFINITY) != 0x7ff0000000000000ULL || B(-INFINITY) != 0xfff0000000000000ULL ||
            !is_quiet_nan_bits(B(NAN)) || B(M_PI) != 0x400921fb54442d18ULL || B(M_E) != 0x4005bf0a8b145769ULL || B(M_PI_2) != 0x3ff921fb54442d18ULL ||
            B(M_PI_4) != 0x3fe921fb54442d18ULL || B(M_SQRT2) != 0x3ff6a09e667f3bcdULL || B(M_SQRT1_2) != 0x3fe6a09e667f3bcdULL ||
            B(M_LN2) != 0x3fe62e42fefa39efULL || B(M_LN10) != 0x40026bb1bbb55516ULL || B(M_LOG2E) != 0x3ff71547652b82feULL ||
            B(M_LOG10E) != 0x3fdbcb7b1526e50eULL || B(M_1_PI) != 0x3fd45f306dc9c883ULL || B(M_2_PI) != 0x3fe45f306dc9c883ULL ||
            B(M_2_SQRTPI) != 0x3ff20dd750429b6dULL) {
            fprintf(stderr, "constants\n");
            bad++;
        }
        if (math_errhandling != MATH_ERRNO || MATH_ERRNO != 1 || MATH_ERREXCEPT != 2) {
            fprintf(stderr, "math_errhandling\n");
            bad++;
        }
    }

    /* ---- errno is left alone by a call that succeeds, even when it was set before ---- */
    {
        errno_slot = 77;
        (void)sqrt(4.0);
        (void)floor(2.5);
        (void)fmod(5.5, 2.0);
        (void)ldexp(1.0, 10);
        (void)lround(2.5);
        (void)remquo(10.0, 3.0, &(int){0});
        (void)nextafter(1.0, 2.0);
        if (errno_slot != 77) {
            fprintf(stderr, "a successful call changed errno to %d\n", errno_slot);
            bad++;
        }
    }

    /* ---- exact known results ---- */
    {
        if (sqrt(2.0) != 1.4142135623730951 || sqrt(0.25) != 0.5 || sqrt(1e300) != 1e150 || sqrt(4.0) != 2.0 || sqrt(9.0) != 3.0) {
            fprintf(stderr, "sqrt known values\n");
            bad++;
        }
        int e = 0;
        double m = frexp(8.0, &e);
        if (m != 0.5 || e != 4 || ldexp(1.0, 10) != 1024.0 || ldexp(0.75, 2) != 3.0) {
            fprintf(stderr, "frexp/ldexp known values\n");
            bad++;
        }
        double ip = 0, f = modf(-3.75, &ip);
        if (f != -0.75 || ip != -3.0) {
            fprintf(stderr, "modf known values\n");
            bad++;
        }
        int q = 0;
        double r = remquo(10.0, 3.0, &q);
        if (r != 1.0 || (q & 7) != 3) {
            fprintf(stderr, "remquo known values %g %d\n", r, q);
            bad++;
        }
        if (round(2.5) != 3.0 || round(-2.5) != -3.0 || rint(2.5) != 2.0 || rint(3.5) != 4.0 || lround(2.5) != 3 || lrint(2.5) != 2 || lrint(-2.5) != -2) {
            fprintf(stderr, "rounding known values\n");
            bad++;
        }
    }

    if (bad) {
        fprintf(stderr, "test_math_abi: %d failures (%d table rows)\n", bad, table_rows);
        return 1;
    }
    printf("test_math_abi OK (%d table rows)\n", table_rows);
    return 0;
}
