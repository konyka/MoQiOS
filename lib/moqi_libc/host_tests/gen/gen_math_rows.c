/* gen_math_rows.c — writes test_math_rows.inc from the host's glibc.
 *
 *   gcc -O1 -o gen gen/gen_math_rows.c -lm && ./gen > test_math_rows.inc
 *
 * Every row is one call: the function, the argument bit patterns, the result bit pattern, and errno (which starts at 0). The
 * functions here have exactly defined results, so the comparison is bit for bit; for a NaN result only "it is a quiet NaN" is
 * recorded (the sign and payload of a NaN made by an invalid operation are the hardware's choice, and propagating one is
 * implementation behavior that no program can rely on). Forms:
 *   D1(fn, a, r, e)         double fn(double)
 *   D2(fn, a, b, r, e)      double fn(double, double)
 *   DI(fn, a, n, r, e)      double fn(double, int)
 *   L1(fn, a, r, e)         long fn(double)
 *   FREXP(a, mant, exp)     frexp
 *   MODF(a, frac, ipart)    modf
 *   REMQUO(a, b, r, q, e)   remquo (q: the quotient bits as glibc stores them, -8..8; 12345 means *quo was not written)
 */
#include <errno.h>
#include <float.h>
#include <gnu/libc-version.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint64_t rng = 0x9e3779b97f4a7c15ULL;
static uint64_t next(void) {
    uint64_t z = (rng += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}
static unsigned rnd(unsigned n) { return (unsigned)(next() % n); }
static uint64_t bits(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static double dbl(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }
static int isnan_bits(uint64_t u) { return (u & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL && (u & 0x000fffffffffffffULL) != 0; }
/* A NaN result is recorded as 0x7ff8000000000000 when it is quiet (the test then accepts any quiet NaN) and as
 * 0x7ff0000000000001 when it is signaling, which only the operations that copy their argument produce (the test then accepts any NaN). */
static uint64_t canon(double d) {
    uint64_t u = bits(d);
    if (!isnan_bits(u)) return u;
    return (u & 0x0008000000000000ULL) ? 0x7ff8000000000000ULL : 0x7ff0000000000001ULL;
}

#define MANT_MASK_ 0x000fffffffffffffULL
static long rows;
static void hx(uint64_t u) { printf("0x%llxULL", (unsigned long long)u); }

#define CALL1(fn, a) do { errno = 0; volatile double _a = dbl(a); volatile double _r = fn(_a); int _e = errno; \
    printf("D1(" #fn ", "); hx(a); printf(", "); hx(canon(_r)); printf(", %d)\n", _e); rows++; } while (0)
#define CALL2(fn, a, b) do { errno = 0; volatile double _a = dbl(a), _b = dbl(b); volatile double _r = fn(_a, _b); int _e = errno; \
    printf("D2(" #fn ", "); hx(a); printf(", "); hx(b); printf(", "); hx(canon(_r)); printf(", %d)\n", _e); rows++; } while (0)
#define CALLI(fn, a, n) do { errno = 0; volatile double _a = dbl(a); volatile double _r = fn(_a, (n)); int _e = errno; \
    printf("DI(" #fn ", "); hx(a); printf(", %d, ", (int)(n)); hx(canon(_r)); printf(", %d)\n", _e); rows++; } while (0)
#define CALLL(fn, a) do { errno = 0; volatile double _a = dbl(a); long long _r = (long long)fn(_a); int _e = errno; \
    printf("L1(" #fn ", "); hx(a); if (_r == (-9223372036854775807LL - 1)) printf(", (-9223372036854775807LL - 1), %d)\n", _e); else printf(", %lldLL, %d)\n", _r, _e); rows++; } while (0)

static const double specials_src[] = {
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 3.5, 0.49999999999999994, -0.49999999999999994, 0.5000000000000001,
    4503599627370496.0, 4503599627370497.0, 4503599627370497.5, 4503599627370495.5, -4503599627370497.5, 9007199254740992.0,
    9007199254740993.0, 9223372036854775807.0, -9223372036854775808.0, 9223372036854777856.0, 1e18, -1e18, 1e19, 1e30, -1e30,
    3.14159265358979, -2.718281828459045, 123456789.125, -0.1, 0.1, 1e-10, 2.0, 3.0, 4.0, 7.0, 10.0, -10.0, 1e22, 1e100, 1e300,
    DBL_MAX, -DBL_MAX, DBL_MIN, -DBL_MIN, DBL_MIN / 2, 5e-324, -5e-324, 1e-310, 2.2250738585072009e-308, DBL_EPSILON, 1.0 - DBL_EPSILON / 2,
    INFINITY, -INFINITY,
};
#define NSPEC ((int)(sizeof specials_src / sizeof specials_src[0]))
static const uint64_t nans[] = {
    0x7ff8000000000000ULL, 0xfff8000000000000ULL, 0x7ff8000000000aaaULL, 0x7ff0000000000001ULL, 0xfff0000000000bbbULL, 0x7fffffffffffffffULL,
};
#define NNAN ((int)(sizeof nans / sizeof nans[0]))

static uint64_t spec(int i) { return i < NSPEC ? bits(specials_src[i]) : nans[i - NSPEC]; }
#define NALL (NSPEC + NNAN)

/* A random double: a pattern from one of several distributions, so the interesting regions get real coverage. */
static uint64_t rand_bits(void) {
    switch (rnd(8)) {
    case 0: return next();                                                   /* any pattern, NaNs and infinities included */
    case 1: return bits((double)(int)(next() % 2001) - 1000.0) + (rnd(2) ? 0 : 0); /* small integers */
    case 2: return bits(((double)(int64_t)next()) / 1099511627776.0);       /* wide range, many fractional bits */
    case 3: return bits((double)(int)(next() % 4001 - 2000) / 4.0);         /* quarters, half-way cases */
    case 4: return (next() & 0x800fffffffffffffULL);                        /* subnormals and zero */
    case 5: return (next() & 0x800fffffffffffffULL) | ((uint64_t)(1 + rnd(2046)) << 52); /* uniform exponent */
    case 6: return bits(4503599627370496.0 + (double)(next() % 8)) | (next() & 0x8000000000000000ULL); /* around 2^52 */
    default: return bits(1.0) + (uint64_t)(next() % 64) - 32;                /* around 1 */
    }
}

int main(void) {
    printf("/* Generated from glibc %s by gen/gen_math_rows.c. See that file for the row forms. */\n", gnu_get_libc_version());
    /* unary, double -> double */
    for (int k = 0; k < 8; k++) {
        for (int i = 0; i < NALL; i++) {
            uint64_t a = spec(i);
            switch (k) {
            case 0: CALL1(sqrt, a); break;
            case 1: CALL1(floor, a); break;
            case 2: CALL1(ceil, a); break;
            case 3: CALL1(trunc, a); break;
            case 4: CALL1(round, a); break;
            case 5: CALL1(rint, a); break;
            case 6: CALL1(nearbyint, a); break;
            default: CALL1(fabs, a); break;
            }
        }
        for (int i = 0; i < 90; i++) {
            uint64_t a = rand_bits();
            switch (k) {
            case 0: CALL1(sqrt, a); break;
            case 1: CALL1(floor, a); break;
            case 2: CALL1(ceil, a); break;
            case 3: CALL1(trunc, a); break;
            case 4: CALL1(round, a); break;
            case 5: CALL1(rint, a); break;
            case 6: CALL1(nearbyint, a); break;
            default: CALL1(fabs, a); break;
            }
        }
    }
    /* sqrt: exact squares and their neighbors */
    for (int i = 0; i < 50; i++) {
        double r = (double)(1 + rnd(1u << 26)) + (rnd(2) ? 0.0 : 0.5);
        CALL1(sqrt, bits(r * r));
        CALL1(sqrt, bits(r * r) + 1);
        CALL1(sqrt, bits(r * r) - 1);
    }
    /* unary, double -> long */
    for (int k = 0; k < 4; k++) {
        for (int i = 0; i < NALL; i++) {
            uint64_t a = spec(i);
            switch (k) {
            case 0: CALLL(lround, a); break;
            case 1: CALLL(llround, a); break;
            case 2: CALLL(lrint, a); break;
            default: CALLL(llrint, a); break;
            }
        }
        for (int i = 0; i < 70; i++) {
            uint64_t a = rand_bits();
            if (rnd(3) == 0) a = bits((double)(int64_t)next() * (rnd(2) ? 1.0 : 0.5)); /* near the 64-bit limits */
            switch (k) {
            case 0: CALLL(lround, a); break;
            case 1: CALLL(llround, a); break;
            case 2: CALLL(lrint, a); break;
            default: CALLL(llrint, a); break;
            }
        }
    }
    /* binary */
    for (int k = 0; k < 7; k++) {
        for (int i = 0; i < NALL; i++)
            for (int j = 0; j < NALL; j++) {
                if (k >= 2 && (j % 4) != 0 && (i % 4) != 0) continue; /* all but fmod and remainder get a sampled grid */
                uint64_t a = spec(i), b = spec(j);
                switch (k) {
                case 0: CALL2(fmod, a, b); break;
                case 1: CALL2(remainder, a, b); break;
                case 2: CALL2(fmax, a, b); break;
                case 3: CALL2(fmin, a, b); break;
                case 4: CALL2(fdim, a, b); break;
                case 5: CALL2(nextafter, a, b); break;
                case 6: CALL2(copysign, a, b); break;
                default: break;
                }
            }
        for (int i = 0; i < 110; i++) {
            uint64_t a = rand_bits(), b = rand_bits();
            if (k <= 1 && rnd(2)) { /* an exponent gap that is small or huge: the long-division loop's interesting cases */
                a = bits(1.0 + (double)rnd(1000) / 7.0) + ((uint64_t)rnd(2000) << 52) * (rnd(2) ? 1 : 0);
                b = bits(1.0 + (double)rnd(1000) / 11.0) + ((uint64_t)rnd(60) << 52) * (rnd(2) ? 1 : 0);
                if (rnd(2)) a = (a & 0x800fffffffffffffULL) | ((uint64_t)(1 + rnd(2046)) << 52);
            }
            switch (k) {
            case 0: CALL2(fmod, a, b); break;
            case 1: CALL2(remainder, a, b); break;
            case 2: CALL2(fmax, a, b); break;
            case 3: CALL2(fmin, a, b); break;
            case 4: CALL2(fdim, a, b); break;
            case 5: {
                uint64_t tgt = rnd(2) ? b : a + (rnd(2) ? 1 : -1); /* evaluated once: the macro uses its argument twice */
                CALL2(nextafter, a, tgt);
                break;
            }
            case 6: CALL2(copysign, a, b); break;
            default: break;
            }
        }
    }
    /* ldexp and scalbn */
    static const int exps[] = { 0, 1, -1, 2, -2, 52, -52, 53, 1023, -1023, 1024, -1024, 1074, -1074, 1075, -1075, 1076, 2046, -2046, 2100, -2100, 5000, -5000, 2147483647, -2147483647 - 1, 100000, -100000 };
    for (int i = 0; i < NALL; i++)
        for (unsigned k = 0; k < sizeof exps / sizeof exps[0]; k++) {
            if ((i + (int)k) % 4 != 0) continue;
            CALLI(ldexp, spec(i), exps[k]);
            CALLI(scalbn, spec(i), exps[k]);
        }
    for (int i = 0; i < 260; i++) {
        uint64_t a = rand_bits();
        int n = (int)(rnd(4400)) - 2200;
        CALLI(ldexp, a, n);
        CALLI(scalbn, a, n);
    }
    /* ldexp and scalbn with exponents near the int limits and the over/underflow thresholds, for every kind of value: always emitted */
    {
        static const uint64_t xs[] = { 0x3ff0000000000000ULL, 0xbff0000000000000ULL, 0x4008000000000000ULL, 0x1ULL, 0x8000000000000001ULL, 0x7fefffffffffffffULL,
                                       0x0010000000000000ULL, 0x0ULL, 0x8000000000000000ULL, 0x7ff0000000000000ULL, 0xfff0000000000000ULL, 0x7ff8000000000000ULL,
                                       0x000fffffffffffffULL, 0x4330000000000001ULL };
        static const int ns[] = { 2147483647, 2147483646, 2147483647 - 1000, -2147483647 - 1, -2147483647, -2147483647 + 1000, 1000000, -1000000, 4001, 4000, 3999,
                                  -4001, -4000, -3999, 2200, -2200, 2150, -2150, 2100, -2100, 2099, -2099, 2098, -2098, 2097, -2097, 2050, -2050, 1100, -1100, 1076, -1076, 1075, -1075, 1074, -1074 };
        for (unsigned i = 0; i < sizeof xs / sizeof xs[0]; i++)
            for (unsigned k = 0; k < sizeof ns / sizeof ns[0]; k++) {
                CALLI(ldexp, xs[i], ns[k]);
                CALLI(scalbn, xs[i], ns[k]);
            }
    }
    /* fmod, remainder and remquo with operands in the lowest binades (biased exponent 0..6): results that are subnormal, the
     * smallest normal numbers, and exactly the boundary between them */
    for (int i = 0; i < 700; i++) {
        uint64_t a = ((uint64_t)rnd(7) << 52) | (next() & MANT_MASK_) | (rnd(2) ? 0x8000000000000000ULL : 0);
        uint64_t b = ((uint64_t)rnd(7) << 52) | (next() & MANT_MASK_) | (rnd(2) ? 0x8000000000000000ULL : 0);
        if (rnd(4) == 0) b = ((uint64_t)rnd(7) << 52) | 1;
        if ((b & 0x7fffffffffffffffULL) == 0) b |= 1;
        CALL2(fmod, a, b);
        CALL2(remainder, a, b);
        int q = 12345;
        errno = 0;
        volatile double r = remquo(dbl(a), dbl(b), &q);
        int e = errno;
        printf("REMQUO(");
        hx(a);
        printf(", ");
        hx(b);
        printf(", ");
        hx(canon(r));
        printf(", %d, %d)\n", q, e);
        rows++;
    }
    /* frexp and modf */
    for (int i = 0; i < NALL + 90; i++) {
        uint64_t a = i < NALL ? spec(i) : rand_bits();
        int e = 12345;
        volatile double m = frexp(dbl(a), &e);
        printf("FREXP(");
        hx(a);
        printf(", ");
        hx(canon(m));
        printf(", %d)\n", isnan_bits(a) || isinf(dbl(a)) ? 0 : e);
        rows++;
        double ip = 0;
        volatile double f = modf(dbl(a), &ip);
        printf("MODF(");
        hx(a);
        printf(", ");
        hx(canon(f));
        printf(", ");
        hx(canon(ip));
        printf(")\n");
        rows++;
    }
    /* remquo */
    for (int i = 0; i < NALL; i++)
        for (int j = 0; j < NALL; j++) {
            if ((i + j) % 3 != 0) continue;
            int q = 12345;
            errno = 0;
            volatile double r = remquo(dbl(spec(i)), dbl(spec(j)), &q);
            int e = errno;
            int finite = !isnan(dbl(spec(i))) && !isnan(dbl(spec(j))) && !isinf(dbl(spec(i))) && dbl(spec(j)) != 0.0;
            printf("REMQUO(");
            hx(spec(i));
            printf(", ");
            hx(spec(j));
            printf(", ");
            hx(canon(r));
            printf(", %d, %d)\n", finite ? q : 12345, e); /* 12345: *quo was not written */
            rows++;
        }
    for (int i = 0; i < 160; i++) {
        uint64_t a = rand_bits(), b = rand_bits();
        if (rnd(2)) {
            a = bits(1.0 + (double)rnd(100000) / 13.0) + ((uint64_t)rnd(40) << 52);
            b = bits(1.0 + (double)rnd(1000) / 7.0) + ((uint64_t)rnd(30) << 52);
        }
        int q = 12345;
        errno = 0;
        volatile double r = remquo(dbl(a), dbl(b), &q);
        int e = errno;
        int finite = !isnan(dbl(a)) && !isnan(dbl(b)) && !isinf(dbl(a)) && dbl(b) != 0.0;
        printf("REMQUO(");
        hx(a);
        printf(", ");
        hx(b);
        printf(", ");
        hx(canon(r));
        printf(", %d, %d)\n", finite ? q : 12345, e);
        rows++;
    }
    fprintf(stderr, "%ld rows\n", rows);
    return 0;
}
