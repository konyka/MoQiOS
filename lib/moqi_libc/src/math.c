/* math.c — the exactly specified double-precision functions of include/math.h.
 *
 * Everything is done on the bit pattern of the double with integer arithmetic, so a result never depends on the rounding mode,
 * on the x87/SSE choice or on compiler transformations, and the same code gives the same bits everywhere. The rules for
 * special values (NaN propagation, signed zeros, errno) follow glibc as measured; host_tests/test_math_abi.c compares about
 * 22000 calls with it bit for bit.
 *
 * NaN results: an operation that is invalid returns the default NaN (the sign bit set, as the hardware makes it); one that has a
 * NaN operand returns that operand made quiet. Which NaN is returned is not something a program can rely on, and the test only
 * demands a quiet NaN.
 */
#include "../include/errno.h"
#include "../include/math.h"

typedef unsigned long long u64;
typedef long long s64;
typedef unsigned __int128 u128;

#define SIGN_BIT 0x8000000000000000ULL
#define EXP_MASK 0x7ff0000000000000ULL
#define MANT_MASK 0x000fffffffffffffULL
#define QUIET_BIT 0x0008000000000000ULL
#define DEFAULT_NAN 0xfff8000000000000ULL

static u64 bits_of(double d) {
    union { double d; u64 u; } c;
    c.d = d;
    return c.u;
}
static double from_bits(u64 u) {
    union { double d; u64 u; } c;
    c.u = u;
    return c.d;
}
static int is_nan_u(u64 u) { return (u & ~SIGN_BIT) > EXP_MASK; }
static int is_inf_u(u64 u) { return (u & ~SIGN_BIT) == EXP_MASK; }
static double quiet(u64 u) { return from_bits(u | QUIET_BIT); }
static double invalid(void) {
    errno = EDOM;
    return from_bits(DEFAULT_NAN);
}

/* A finite nonzero value as m * 2^(e - 1075) with m in [2^52, 2^53): a subnormal is shifted up and its exponent lowered. */
static void unpack(u64 u, u64 *m, int *e) {
    int be = (int)((u >> 52) & 0x7ff);
    u64 mant = u & MANT_MASK;
    if (be == 0) {
        be = 1;
        while (!(mant >> 52)) {
            mant <<= 1;
            be--;
        }
    } else {
        mant |= 1ULL << 52;
    }
    *m = mant;
    *e = be;
}

/* ---- sign and copy ------------------------------------------------------------------------------------------------- */

double fabs(double x) { return from_bits(bits_of(x) & ~SIGN_BIT); }

double copysign(double x, double y) { return from_bits((bits_of(x) & ~SIGN_BIT) | (bits_of(y) & SIGN_BIT)); }

/* ---- square root: correctly rounded, from the integer square root of the significand ------------------------------------ */

double sqrt(double x) {
    u64 u = bits_of(x);
    if (is_nan_u(u)) return quiet(u);
    if ((u & ~SIGN_BIT) == 0) return x; /* +-0 */
    if (u & SIGN_BIT) return invalid(); /* includes -infinity */
    if (u == EXP_MASK) return x;        /* +infinity */
    u64 m;
    int be;
    unpack(u, &m, &be);
    /* x = m * 2^s with s = be - 1075; make s even so the exponent halves exactly */
    int s = be - 1075;
    u128 mm = m;
    if (s & 1) {
        mm <<= 1;
        s -= 1;
    }
    /* t = floor(sqrt(mm * 2^56)) has 55 bits */
    u128 n = mm << 56, res = 0, bit = (u128)1 << 110;
    while (bit > n) bit >>= 2;
    while (bit) {
        if (n >= res + bit) {
            n -= res + bit;
            res = (res >> 1) + bit;
        } else {
            res >>= 1;
        }
        bit >>= 2;
    }
    u64 t = (u64)res;
    u64 q = t >> 2, low = t & 3;
    /* Round to nearest, ties to even. The two bits below q are 00, 01, 10 or 11. The remainder n is never zero when they are 10:
     * t = 4q + 2 with n == 0 would make N = t*t = 4(2q + 1)^2, which has exactly two factors of two, while N = mm * 2^56 has at
     * least 56. So there is no exact tie, and low >= 2 always rounds up (checked against glibc over 40 million significands). */
    if (low >= 2) q++;
    /* q cannot reach 2^53: the largest mm is 2^54 - 2 (the all-ones significand, doubled for an odd exponent), whose root is
     * 2^55 - 2 - 2^-54, so t = 2^55 - 3, q = 2^53 - 1 and low = 1: no round-up, no carry. */
    int exp = s / 2 + 26; /* the exponent of bit 52 of q */
    return from_bits(((u64)(exp + 1023) << 52) | (q & MANT_MASK));
}

/* ---- rounding to an integral value --------------------------------------------------------------------------------------- */

enum round_mode { R_FLOOR, R_CEIL, R_TRUNC, R_ROUND, R_EVEN };

static double round_double(double x, enum round_mode mode) {
    u64 u = bits_of(x);
    int e = (int)((u >> 52) & 0x7ff) - 1023;
    u64 sign = u & SIGN_BIT;
    if (e >= 52) return is_nan_u(u) ? quiet(u) : x; /* already integral, infinity, NaN */
    if (e < 0) {
        /* |x| < 1: the result is 0 or +-1 */
        u64 mag = u & ~SIGN_BIT;
        int one;
        switch (mode) {
        case R_FLOOR: one = sign != 0 && mag != 0; break;
        case R_CEIL: one = sign == 0 && mag != 0; break;
        case R_TRUNC: one = 0; break;
        case R_ROUND: one = mag >= 0x3fe0000000000000ULL; break;    /* |x| >= 0.5 */
        default: one = mag > 0x3fe0000000000000ULL; break;           /* |x| > 0.5; exactly 0.5 ties to the even 0 */
        }
        return from_bits(sign | (one ? 0x3ff0000000000000ULL : 0));
    }
    u64 unit = 1ULL << (52 - e);   /* the weight of the lowest integer bit */
    u64 mask = unit - 1;           /* the fraction bits */
    u64 frac = u & mask;
    u64 base = u & ~mask;
    if (frac == 0) return x;
    switch (mode) {
    case R_FLOOR: return from_bits(sign ? base + unit : base);
    case R_CEIL: return from_bits(sign ? base : base + unit);
    case R_TRUNC: return from_bits(base);
    case R_ROUND: return from_bits(frac >= (unit >> 1) ? base + unit : base);
    default: {
        u64 half = unit >> 1;
        if (frac > half || (frac == half && (base & unit))) return from_bits(base + unit);
        return from_bits(base);
    }
    }
}

double floor(double x) { return round_double(x, R_FLOOR); }
double ceil(double x) { return round_double(x, R_CEIL); }
double trunc(double x) { return round_double(x, R_TRUNC); }
double round(double x) { return round_double(x, R_ROUND); }
double rint(double x) { return round_double(x, R_EVEN); }
double nearbyint(double x) { return round_double(x, R_EVEN); }

/* The nearest integer as a 64-bit value; anything that does not fit (and NaN, infinity) is LLONG_MIN, errno untouched. */
static s64 to_integer(double x, int ties_even) {
    u64 u = bits_of(x);
    int e = (int)((u >> 52) & 0x7ff) - 1023;
    int neg = (u & SIGN_BIT) != 0;
    if (e >= 63) return (-9223372036854775807LL - 1);
    if (e < 0) {
        u64 mag = u & ~SIGN_BIT;
        int one = ties_even ? mag > 0x3fe0000000000000ULL : mag >= 0x3fe0000000000000ULL;
        return one ? (neg ? -1 : 1) : 0;
    }
    u64 m = (u & MANT_MASK) | (1ULL << 52);
    u64 v;
    if (e >= 52) {
        v = m << (e - 52);
    } else {
        int sh = 52 - e;
        u64 q = m >> sh, rem = m & ((1ULL << sh) - 1), half = 1ULL << (sh - 1);
        if (ties_even ? (rem > half || (rem == half && (q & 1))) : rem >= half) q++;
        v = q;
    }
    return neg ? (s64)(0 - v) : (s64)v;
}

long lround(double x) { return (long)to_integer(x, 0); }
long long llround(double x) { return to_integer(x, 0); }
long lrint(double x) { return (long)to_integer(x, 1); }
long long llrint(double x) { return to_integer(x, 1); }

/* ---- remainders ---------------------------------------------------------------------------------------------------------- */

/* Shared by fmod, remainder and remquo. With `nearest` it reduces |x| modulo |y| to the nearest multiple (remainder, remquo);
 * otherwise it truncates (fmod). *quo gets the low bits of the integer quotient (sign applied by the caller). */
static double reduce(double xd, double yd, int nearest, unsigned *quo) {
    u64 ux = bits_of(xd), uy = bits_of(yd);
    u64 sx = ux & SIGN_BIT;
    if (is_nan_u(ux) || is_nan_u(uy)) return quiet(is_nan_u(ux) ? ux : uy);
    if ((uy & ~SIGN_BIT) == 0 || is_inf_u(ux)) return invalid();
    if ((ux & ~SIGN_BIT) == 0) return xd;
    if (is_inf_u(uy)) return xd;
    u64 mx, my;
    int ex, ey;
    unpack(ux, &mx, &ex);
    unpack(uy, &my, &ey);
    unsigned q = 0;
    u64 r, ry;
    int ez;
    if (ex < ey) {
        /* |x| < |y|: fmod is x itself; for the nearest multiple only |x| > |y|/2 matters, which needs ex + 1 == ey */
        if (!nearest || ex + 1 < ey) return xd;
        r = mx;
        ry = my << 1;
        ez = ex;
    } else {
        r = mx;
        ry = my;
        ez = ey;
        for (int e = ex; e > ey; e--) {
            if (r >= my) {
                r -= my;
                q |= 1;
            }
            r <<= 1;
            q <<= 1;
        }
        if (r >= my) {
            r -= my;
            q |= 1;
        }
    }
    int flip = 0;
    q &= 7;   /* glibc keeps only the low three bits of the truncated quotient, and adds the rounding carry after that: 0..8 */
    if (nearest && (r > ry - r || (r == ry - r && (q & 1)))) {
        /* more than half of y, or exactly half with an odd quotient: the multiple above is nearer */
        r = ry - r;
        q++;
        flip = 1;
    }
    if (quo) *quo = q;
    u64 rsign = flip ? (sx ^ SIGN_BIT) : sx;
    if (r == 0) return from_bits(sx); /* a zero result keeps the sign of x */
    while (!(r >> 52)) {
        r <<= 1;
        ez--;
    }
    if (ez > 0) return from_bits(rsign | ((u64)ez << 52) | (r & MANT_MASK));
    return from_bits(rsign | (r >> (1 - ez)));
}

double fmod(double x, double y) { return reduce(x, y, 0, (unsigned *)0); }

double remainder(double x, double y) { return reduce(x, y, 1, (unsigned *)0); }

double remquo(double x, double y, int *quo) {
    unsigned q = 0;
    int saved = errno;
    double r = reduce(x, y, 1, &q);
    errno = saved; /* unlike fmod and remainder, glibc's remquo reports a domain error through the result only */
    u64 ux = bits_of(x), uy = bits_of(y);
    /* A NaN operand or a domain error (zero divisor, infinite dividend) leaves *quo alone: glibc stores nothing. */
    if (is_nan_u(ux) || is_nan_u(uy) || is_inf_u(ux) || (uy & ~SIGN_BIT) == 0) return r;
    if (quo) {
        int n = (int)(q & 15U); /* see reduce(): the low three bits of the truncated quotient, plus one when rounded up, so 0..8 */
        *quo = ((ux ^ uy) & SIGN_BIT) ? -n : n;
    }
    return r;
}

/* ---- comparisons --------------------------------------------------------------------------------------------------------- */

static int is_snan_u(u64 u) { return is_nan_u(u) && !(u & QUIET_BIT); }

double fmax(double x, double y) {
    u64 ux = bits_of(x), uy = bits_of(y);
    if (is_snan_u(ux)) return quiet(ux);
    if (is_snan_u(uy)) return quiet(uy);
    if (is_nan_u(uy)) return is_nan_u(ux) ? y : x;
    if (is_nan_u(ux)) return y;
    return x >= y ? x : y;
}

double fmin(double x, double y) {
    u64 ux = bits_of(x), uy = bits_of(y);
    if (is_snan_u(ux)) return quiet(ux);
    if (is_snan_u(uy)) return quiet(uy);
    if (is_nan_u(uy)) return is_nan_u(ux) ? y : x;
    if (is_nan_u(ux)) return y;
    return x <= y ? x : y;
}

double fdim(double x, double y) {
    u64 ux = bits_of(x), uy = bits_of(y);
    if (is_nan_u(ux)) return quiet(ux);
    if (is_nan_u(uy)) return quiet(uy);
    if (x <= y) return 0.0;
    double r = x - y;
    if (is_inf_u(bits_of(r)) && !is_inf_u(ux) && !is_inf_u(uy)) errno = ERANGE;
    return r;
}

double nextafter(double x, double y) {
    u64 ux = bits_of(x), uy = bits_of(y);
    if (is_nan_u(ux)) return quiet(ux);
    if (is_nan_u(uy)) return quiet(uy);
    if (x == y) return y;
    u64 r;
    if ((ux & ~SIGN_BIT) == 0) {
        r = 1 | (uy & SIGN_BIT); /* the smallest subnormal, toward y */
        return from_bits(r);
    }
    int up = x < y;                   /* toward larger values */
    int away = (up != ((ux & SIGN_BIT) != 0)); /* moving away from zero: x positive and up, or x negative and down */
    r = away ? ux + 1 : ux - 1;
    /* ERANGE for overflow to infinity, and for any step whose result is subnormal or zero (below the smallest normal number,
     * 0x0010000000000000) other than the step off zero itself, which is handled above */
    if (is_inf_u(r) || (r & ~SIGN_BIT) < 0x0010000000000000ULL) errno = ERANGE;
    return from_bits(r);
}

/* ---- scaling ------------------------------------------------------------------------------------------------------------- */

double scalbn(double x, int n) {
    u64 u = bits_of(x);
    if (is_nan_u(u)) return quiet(u);
    if (is_inf_u(u) || (u & ~SIGN_BIT) == 0) return x;
    u64 sign = u & SIGN_BIT;
    u64 m;
    int be;
    unpack(u, &m, &be);
    /* x = m * 2^(be - 1075); the result is m * 2^(be + n - 1075). A shift beyond +-4000 is out of range whatever the value, and
     * is handled first so that be + n below cannot overflow an int (n comes from the caller: INT_MAX is a legal argument). */
    if (n > 4000) {
        errno = ERANGE;
        return from_bits(sign | EXP_MASK);
    }
    if (n < -4000) {
        errno = ERANGE;
        return from_bits(sign);
    }
    int nb = be + n; /* the biased exponent of the result if it stays normal */
    if (nb >= 0x7ff) {
        errno = ERANGE;
        return from_bits(sign | EXP_MASK);
    }
    if (nb >= 1) return from_bits(sign | ((u64)nb << 52) | (m & MANT_MASK));
    int sh = 1 - nb; /* subnormal result: m / 2^sh, rounded to nearest even */
    u64 q;
    if (sh >= 64) {
        q = 0;
    } else {
        q = m >> sh;
        u64 rem = m & ((1ULL << sh) - 1), half = 1ULL << (sh - 1);
        if (rem > half || (rem == half && (q & 1))) q++;
    }
    if (q == 0) errno = ERANGE;
    return from_bits(sign | q);
}

double ldexp(double x, int n) { return scalbn(x, n); }

double frexp(double x, int *exp) {
    u64 u = bits_of(x);
    *exp = 0;
    if (is_nan_u(u)) return quiet(u);
    if (is_inf_u(u) || (u & ~SIGN_BIT) == 0) return x;
    u64 m;
    int be;
    unpack(u, &m, &be);
    *exp = be - 1022;
    return from_bits((u & SIGN_BIT) | (1022ULL << 52) | (m & MANT_MASK));
}

double modf(double x, double *iptr) {
    u64 u = bits_of(x);
    if (is_nan_u(u)) {
        *iptr = quiet(u);
        return quiet(u);
    }
    if (is_inf_u(u)) {
        *iptr = x;
        return from_bits(u & SIGN_BIT);
    }
    double ip = round_double(x, R_TRUNC);
    *iptr = ip;
    return copysign(x - ip, x);
}
