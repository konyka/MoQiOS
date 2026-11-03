/* strtod.c — strtod, strtof, atof (see include/stdlib.h).
 *
 * The parse produces an exact value: either a decimal digit string with a power of ten, or a hexadecimal digit string with a
 * power of two. The rounding is done in integers (a small fixed-size big number), so the result is the correctly rounded
 * nearest-even value for any input length, with no floating-point arithmetic involved until the final bit pattern is moved
 * into a double/float. Behavior (errno, end pointer, NaN payloads, underflow rules) follows glibc as measured; the
 * expected values are in host_tests/test_strtod_rows.inc.
 */
#include "../include/errno.h"
#include "../include/stdlib.h"

typedef unsigned long long u64;
typedef unsigned int u32;

/* ---- big natural numbers: little-endian 32-bit limbs, fixed capacity ---------------------------------------------- */

/* The longest value held at once. At most MAX_DIG (800) decimal digits are kept (2659 bits, 84 limbs), and the decimal
 * exponent is clamped so that digits + exponent stays within +-400 (10^400 is 1329 bits, 42 limbs): the numerator
 * D * 10^e (e >= 0) is at most 84 + 42 limbs, the denominator 10^-e (e < 0) at most 10^1200 = 125 limbs, and rescaling
 * to the format adds at most 42 more. 192 limbs covers all of it with room; `struct big` is then 772 bytes, so the
 * dozen of them live at once in the deepest call chain take about 9 KB of stack. (A pthread has a 64 KiB stack.) */
#define BIG_LIMBS 192

struct big {
    u32 w[BIG_LIMBS];
    int n; /* limbs in use; 0 means zero */
};

static void big_zero(struct big *a) { a->n = 0; }

static void big_set_u64(struct big *a, u64 v) {
    a->n = 0;
    while (v) {
        a->w[a->n++] = (u32)v;
        v >>= 32;
    }
}

/* a = a * m + add, m < 2^32. Returns 0 on overflow of the capacity. */
static int big_muladd(struct big *a, u32 m, u32 add) {
    u64 carry = add;
    for (int i = 0; i < a->n; i++) {
        u64 t = (u64)a->w[i] * m + carry;
        a->w[i] = (u32)t;
        carry = t >> 32;
    }
    if (carry) {
        if (a->n >= BIG_LIMBS) return 0;
        a->w[a->n++] = (u32)carry;
    }
    return 1;
}

static int big_is_zero(const struct big *a) { return a->n == 0; }

static int big_cmp(const struct big *a, const struct big *b) {
    if (a->n != b->n) return a->n < b->n ? -1 : 1;
    for (int i = a->n - 1; i >= 0; i--)
        if (a->w[i] != b->w[i]) return a->w[i] < b->w[i] ? -1 : 1;
    return 0;
}

/* a <<= k */
static int big_shl(struct big *a, int k) {
    if (a->n == 0 || k == 0) return 1;
    int limbs = k / 32, bits = k % 32;
    if (a->n + limbs + 1 > BIG_LIMBS) return 0;
    if (bits) {
        u32 carry = 0;
        for (int i = 0; i < a->n; i++) {
            u32 nw = (a->w[i] << bits) | carry;
            carry = a->w[i] >> (32 - bits);
            a->w[i] = nw;
        }
        if (carry) a->w[a->n++] = carry;
    }
    if (limbs) {
        for (int i = a->n - 1; i >= 0; i--) a->w[i + limbs] = a->w[i];
        for (int i = 0; i < limbs; i++) a->w[i] = 0;
        a->n += limbs;
    }
    return 1;
}

/* a -= b, a >= b */
static void big_sub(struct big *a, const struct big *b) {
    u64 borrow = 0;
    for (int i = 0; i < a->n; i++) {
        u64 bi = i < b->n ? b->w[i] : 0;
        u64 t = (u64)a->w[i] - bi - borrow;
        a->w[i] = (u32)t;
        borrow = (t >> 63) & 1;
    }
    while (a->n > 0 && a->w[a->n - 1] == 0) a->n--;
}

static int big_bitlen(const struct big *a) {
    if (a->n == 0) return 0;
    u32 top = a->w[a->n - 1];
    int b = 0;
    while (top) {
        b++;
        top >>= 1;
    }
    return (a->n - 1) * 32 + b;
}

static int big_pow10(struct big *a, int e) {
    big_set_u64(a, 1);
    while (e >= 9) {
        if (!big_muladd(a, 1000000000u, 0)) return 0;
        e -= 9;
    }
    u32 m = 1;
    while (e-- > 0) m *= 10;
    return m == 1 ? 1 : big_muladd(a, m, 0);
}

/* Floor of a / b for a >= b with a/b < 2^64 (the quotient is built bit by bit from the top): used only with a quotient that
 * fits in 64 bits. Leaves the remainder in a. */
static u64 big_divrem_small_quot(struct big *a, const struct big *b) {
    int shift = big_bitlen(a) - big_bitlen(b);
    if (shift < 0) return 0;
    struct big t = *b;
    if (!big_shl(&t, shift)) return 0;
    u64 q = 0;
    for (int s = shift; s >= 0; s--) {
        q <<= 1;
        if (big_cmp(a, &t) >= 0) {
            big_sub(a, &t);
            q |= 1;
        }
        /* t >>= 1 */
        u32 carry = 0;
        for (int i = t.n - 1; i >= 0; i--) {
            u32 nc = t.w[i] & 1;
            t.w[i] = (t.w[i] >> 1) | (carry << 31);
            carry = nc;
        }
        while (t.n > 0 && t.w[t.n - 1] == 0) t.n--;
    }
    return q;
}

/* ---- rounding an exact value to a binary format -------------------------------------------------------------------- */

struct fmt {
    int mant_bits; /* significand precision including the implicit bit: 53 or 24 */
    int emin;      /* exponent of the smallest normal, as a power of two of the unit in the last place of 1.0: -1022 or -126 */
    int emax;      /* exponent of the largest finite number: 1023 or 127 */
};

static const struct fmt DOUBLE_FMT = { 53, -1022, 1023 };
static const struct fmt FLOAT_FMT = { 24, -126, 127 };

/* Result of converting: significand and binary exponent such that value = sig * 2^exp2, rounded and range-checked. */
struct rounded {
    u64 sig;    /* integer significand, < 2^mant_bits (a subnormal has fewer bits) */
    int exp2;   /* value = sig * 2^exp2 */
    int is_inf;
    int inexact;
    int underflow_range; /* subnormal and inexact, or rounded to zero: C99 ERANGE */
};

/* Round the exact rational (num / den) * 2^e2 to the format, nearest-even. num, den > 0. */
static int round_ratio(const struct big *num_in, const struct big *den_in, int e2, const struct fmt *f, struct rounded *out) {
    struct big num = *num_in, den = *den_in;

    /* Scale so that 2^(P-1) <= num/den < 2^P, P = mant_bits, tracking the exponent. value = (num/den) * 2^e2. */
    int P = f->mant_bits;
    int lg = big_bitlen(&num) - big_bitlen(&den); /* floor(log2(num/den)) is lg or lg-1 */
    int shift = (P - 1) - lg;                      /* we want num/den * 2^shift in [2^(P-1), 2^P) */
    if (shift > 0) {
        if (!big_shl(&num, shift)) return 0;
    } else if (shift < 0) {
        if (!big_shl(&den, -shift)) return 0;
    }
    e2 -= shift;
    /* Fix up the off-by-one in lg. */
    {
        struct big lim = den;
        if (!big_shl(&lim, P)) return 0;
        if (big_cmp(&num, &lim) >= 0) { /* num/den >= 2^P: shift down by one */
            if (!big_shl(&den, 1)) return 0;
            e2 += 1;
        }
        struct big lo = den;
        if (!big_shl(&lo, P - 1)) return 0;
        if (big_cmp(&num, &lo) < 0) { /* num/den < 2^(P-1): shift up by one */
            if (!big_shl(&num, 1)) return 0;
            e2 -= 1;
        }
    }

    /* The exponent of the unit in the last place is e2; a result below the normal range has fewer significant bits. */
    int min_e2 = f->emin - (P - 1); /* e2 of the smallest subnormal's unit */
    int extra = 0;
    /* Tininess is judged after rounding to full precision with an unbounded exponent (x86, and glibc as measured): the
     * value is tiny when that rounding still lands below the smallest normal number. A value just under it that rounds
     * UP to it at full precision is therefore not tiny (and not ERANGE), while one that stays below is. */
    int below_normal;
    {
        struct big n0 = num, d0 = den;
        u64 q0 = big_divrem_small_quot(&n0, &d0);
        int e0 = e2;
        if (!big_is_zero(&n0)) {
            struct big twice = n0;
            if (!big_shl(&twice, 1)) return 0;
            int c = big_cmp(&twice, &d0);
            if (c > 0 || (c == 0 && (q0 & 1))) q0++;
        }
        if (q0 >> P) e0 += 1;
        below_normal = e0 < min_e2;
    }
    if (e2 < min_e2) {
        extra = min_e2 - e2; /* bits to drop on top of the usual none */
        e2 = min_e2;
    }
    if (extra > P + 2) extra = P + 2; /* everything is below half of the smallest subnormal's unit, in the sticky bit */

    /* quotient q = floor(num / (den * 2^extra)), remainder decides the rounding. */
    if (extra) {
        if (!big_shl(&den, extra)) return 0;
    }
    u64 q = big_divrem_small_quot(&num, &den); /* num is now the remainder */
    int inexact = !big_is_zero(&num);
    int round_up = 0;
    if (inexact) {
        struct big twice = num;
        if (!big_shl(&twice, 1)) return 0;
        int c = big_cmp(&twice, &den);
        if (c > 0) round_up = 1;
        else if (c == 0) round_up = (int)(q & 1);
    }
    if (round_up) q++;
    if (q >> P) { /* carried out to P+1 bits */
        q >>= 1;
        e2 += 1;
    }

    out->inexact = inexact;
    out->is_inf = 0;
    out->underflow_range = 0;
    if (q == 0) {
        out->sig = 0;
        out->exp2 = 0;
        out->underflow_range = 1;
        return 1;
    }
    /* Overflow: the largest finite is (2^P - 1) * 2^(emax - P + 1). */
    if (e2 + P - 1 > f->emax) {
        out->is_inf = 1;
        return 1;
    }
    out->sig = q;
    out->exp2 = e2;
    /* ERANGE for an inexact result in the subnormal range, judged on the exact value before rounding (glibc, measured: a
     * value just under the smallest normal number that rounds up to it is still ERANGE, while the exact smallest normal is
     * not). `below_normal` was recorded before the division, when the exponent was still the unrounded one. */
    if (inexact && below_normal) out->underflow_range = 1;
    return 1;
}

/* ---- parsing -------------------------------------------------------------------------------------------------------- */

static int is_space_c(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'; }
static int lower_c(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    c = lower_c(c);
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static int match_word(const char *s, const char *w) {
    int i = 0;
    while (w[i]) {
        if (lower_c((unsigned char)s[i]) != w[i]) return 0;
        i++;
    }
    return i;
}

/* The parse result for the finite-number case. */
struct parsed {
    int kind;      /* 0 = nothing, 1 = zero, 2 = finite nonzero, 3 = infinity, 4 = nan */
    int neg;
    int hex;
    /* kind 2, decimal: the digits (first MAX_DIG significant ones) and a decimal exponent, value = 0.d1d2d3... wait: we keep
     * an integer: digits as an integer D with the exponent such that value = D * 10^exp10; sticky says nonzero digits were
     * dropped after the kept ones. */
    char *digits_buf;
    int ndigits;
    long exp10;
    /* kind 2, hex: significand in a u64 (up to 16 hex digits, 64 bits) with a sticky bit for further digits, value =
     * sig * 2^exp2 (+ sticky). */
    u64 hsig;
    long exp2;
    int sticky;
    u64 nan_payload;
    const char *end;
};

#define MAX_DIG 800 /* significant decimal digits kept; more than any double/float input can distinguish */

static long add_exp(long a, long b) {
    long r = a + b;
    if (b > 0 && r < a) return 0x7fffffffffffL;
    if (b < 0 && r > a) return -0x7fffffffffffL;
    return r;
}

static void parse(const char *s, struct parsed *pr, char *dig) {
    pr->kind = 0;
    pr->neg = 0;
    pr->hex = 0;
    pr->digits_buf = dig;
    pr->ndigits = 0;
    pr->exp10 = 0;
    pr->hsig = 0;
    pr->exp2 = 0;
    pr->sticky = 0;
    pr->nan_payload = 0;
    pr->end = s;

    const char *p = s;
    while (is_space_c((unsigned char)*p)) p++;
    if (*p == '-' || *p == '+') {
        pr->neg = *p == '-';
        p++;
    }

    /* inf / infinity / nan */
    {
        int n;
        if ((n = match_word(p, "infinity")) != 0) {
            pr->kind = 3;
            pr->end = p + n;
            return;
        }
        if ((n = match_word(p, "inf")) != 0) {
            pr->kind = 3;
            pr->end = p + n;
            return;
        }
        if ((n = match_word(p, "nan")) != 0) {
            pr->kind = 4;
            const char *q = p + n;
            pr->end = q;
            if (*q == '(') {
                /* nan(n-char-sequence): letters, digits and underscore, closed by ')'. Only a closed sequence is part of the
                 * number; its payload is the digits when the whole sequence is a number (C syntax: 0x.., 0.., decimal). */
                const char *r = q + 1;
                while ((*r >= '0' && *r <= '9') || (*r >= 'a' && *r <= 'z') || (*r >= 'A' && *r <= 'Z') || *r == '_') r++;
                if (*r == ')') {
                    pr->end = r + 1;
                    const char *d = q + 1;
                    u64 v = 0;
                    int ok = 1, base = 10;
                    if (d[0] == '0' && (d[1] == 'x' || d[1] == 'X')) {
                        base = 16;
                        d += 2;
                    } else if (d[0] == '0') {
                        base = 8;
                    }
                    for (; d < r; d++) {
                        int dv = hexval((unsigned char)*d);
                        if (dv < 0 || dv >= base) {
                            ok = 0;
                            break;
                        }
                        if (v > (~(u64)0 - (u64)dv) / (u64)base) v = ~(u64)0;
                        else v = v * (u64)base + (u64)dv;
                    }
                    if (ok) pr->nan_payload = v; /* no digits at all leaves v == 0 */
                }
            }
            return;
        }
    }

    /* hexadecimal */
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        const char *q = p + 2;
        int have = 0, seen_dot = 0;
        long exp2 = 0;
        u64 sig = 0;
        int sticky = 0, nz_seen = 0;
        const char *last_good = 0;
        int lead_zero_only = 1;
        (void)lead_zero_only;
        for (;; q++) {
            int hv = hexval((unsigned char)*q);
            if (hv >= 0) {
                have = 1;
                if (!nz_seen && hv == 0) {
                    if (seen_dot) exp2 = add_exp(exp2, -4);
                    continue;
                }
                if (hv != 0) nz_seen = 1;
                if (sig >> 60 == 0) {
                    sig = (sig << 4) | (u64)hv;
                    if (seen_dot) exp2 = add_exp(exp2, -4);
                } else {
                    if (hv) sticky = 1;
                    if (!seen_dot) exp2 = add_exp(exp2, 4);
                }
            } else if (*q == '.' && !seen_dot) {
                seen_dot = 1;
            } else {
                break;
            }
        }
        if (have) {
            last_good = q;
            long pe = 0;
            if ((*q == 'p' || *q == 'P')) {
                const char *r = q + 1;
                int eneg = 0;
                if (*r == '+' || *r == '-') {
                    eneg = *r == '-';
                    r++;
                }
                if (*r >= '0' && *r <= '9') {
                    long ev = 0;
                    while (*r >= '0' && *r <= '9') {
                        if (ev < 100000000L) ev = ev * 10 + (*r - '0');
                        r++;
                    }
                    pe = eneg ? -ev : ev;
                    last_good = r;
                }
            }
            pr->hex = 1;
            pr->end = last_good;
            if (!nz_seen) {
                pr->kind = 1;
                return;
            }
            pr->kind = 2;
            pr->hsig = sig;
            pr->exp2 = add_exp(exp2, pe);
            pr->sticky = sticky;
            return;
        }
        /* "0x" with no hex digit after it: the number is the "0" alone. */
        pr->kind = 1;
        pr->end = p + 1;
        return;
    }

    /* decimal */
    {
        const char *q = p;
        int seen_dot = 0, have = 0, nz_seen = 0;
        long exp10 = 0;
        int nd = 0;
        int dropped_nonzero = 0;
        for (;; q++) {
            if (*q >= '0' && *q <= '9') {
                have = 1;
                int dv = *q - '0';
                if (!nz_seen && dv == 0) {
                    if (seen_dot) exp10 = add_exp(exp10, -1);
                    continue;
                }
                nz_seen = 1;
                if (nd < MAX_DIG) {
                    dig[nd++] = (char)dv;
                    if (seen_dot) exp10 = add_exp(exp10, -1);
                } else {
                    if (dv) dropped_nonzero = 1;
                    if (!seen_dot) exp10 = add_exp(exp10, 1);
                }
            } else if (*q == '.' && !seen_dot) {
                seen_dot = 1;
            } else {
                break;
            }
        }
        if (!have) return;
        const char *end = q;
        if (*q == 'e' || *q == 'E') {
            const char *r = q + 1;
            int eneg = 0;
            if (*r == '+' || *r == '-') {
                eneg = *r == '-';
                r++;
            }
            if (*r >= '0' && *r <= '9') {
                long ev = 0;
                while (*r >= '0' && *r <= '9') {
                    if (ev < 100000000L) ev = ev * 10 + (*r - '0');
                    r++;
                }
                exp10 = add_exp(exp10, eneg ? -ev : ev);
                end = r;
            }
        }
        pr->end = end;
        if (!nz_seen) {
            pr->kind = 1;
            return;
        }
        /* Trailing zeros of the kept digits are part of the integer; a dropped nonzero digit is a sticky tail we represent
         * by appending a single 1 beyond the last kept digit (it only matters for ties). */
        pr->kind = 2;
        pr->ndigits = nd;
        pr->exp10 = exp10;
        pr->sticky = dropped_nonzero;
    }
}

/* ---- from a parse to bits ------------------------------------------------------------------------------------------ */

/* Returns 0 on internal capacity overflow (cannot happen for exponents within the clamped range). */
static int convert(const struct parsed *pr, const struct fmt *f, struct rounded *out, int *saturate_inf, int *saturate_zero) {
    *saturate_inf = 0;
    *saturate_zero = 0;
    struct big num, den;
    int e2 = 0;
    if (pr->hex) {
        /* value = hsig * 2^exp2, plus a sticky tail below the last kept bit. */
        u64 sig = pr->hsig;
        long ex = pr->exp2;
        /* Bring the significand to the format's bit budget so the sticky tail is below the rounding position. */
        if (pr->sticky) {
            /* sig has the tail strictly below its lowest bit: model it as sig*2 + 1 at exponent ex-1 (a 1 below half
             * of the last kept bit can never flip a tie because the kept digits are at least 60 bits long). */
            if (sig >> 62) {
                /* keep headroom */
            }
        }
        big_set_u64(&num, sig);
        big_set_u64(&den, 1);
        if (pr->sticky) {
            if (!big_shl(&num, 1)) return 0;
            if (!big_muladd(&num, 1, 1)) return 0;
            ex -= 1;
        }
        if (ex > 100000) {
            *saturate_inf = 1;
            return 1;
        }
        if (ex < -100000) {
            *saturate_zero = 1;
            return 1;
        }
        e2 = (int)ex;
    } else {
        /* value = D * 10^exp10 where D is the kept digits; a dropped nonzero tail makes it D*10 + 1 at one lower power. */
        big_zero(&num);
        for (int i = 0; i < pr->ndigits; i++)
            if (!big_muladd(&num, 10, (u32)(unsigned char)pr->digits_buf[i])) return 0;
        long e10 = pr->exp10;
        if (pr->sticky) {
            if (!big_muladd(&num, 10, 1)) return 0;
            e10 -= 1;
        }
        /* Quick range cuts: more than 10^~310 or less than 10^~-400 cannot be a finite number or a nonzero one, but the
         * digit count shifts the boundary; use the digit count to decide. */
        long mag = (long)pr->ndigits + e10; /* value is in [10^(mag-1), 10^mag) */
        if (mag > 400) {
            *saturate_inf = 1;
            return 1;
        }
        if (mag < -400) {
            *saturate_zero = 1;
            return 1;
        }
        big_set_u64(&den, 1);
        if (e10 >= 0) {
            struct big p10;
            if (!big_pow10(&p10, (int)e10)) return 0;
            /* num *= p10 */
            struct big prod;
            big_zero(&prod);
            for (int i = 0; i < num.n; i++) {
                u64 carry = 0;
                for (int j = 0; j < p10.n; j++) {
                    if (i + j >= BIG_LIMBS) return 0;
                    while (prod.n <= i + j) prod.w[prod.n++] = 0;
                    u64 t = (u64)num.w[i] * p10.w[j] + prod.w[i + j] + carry;
                    prod.w[i + j] = (u32)t;
                    carry = t >> 32;
                }
                int k = i + p10.n;
                while (carry) {
                    if (k >= BIG_LIMBS) return 0;
                    while (prod.n <= k) prod.w[prod.n++] = 0;
                    u64 t = (u64)prod.w[k] + carry;
                    prod.w[k] = (u32)t;
                    carry = t >> 32;
                    k++;
                }
            }
            num = prod;
        } else {
            if (!big_pow10(&den, (int)-e10)) return 0;
        }
        e2 = 0;
    }
    return round_ratio(&num, &den, e2, f, out);
}

static u64 assemble_double(const struct rounded *r, int neg, u64 nan_payload, int kind) {
    u64 sign = neg ? (1ULL << 63) : 0;
    if (kind == 3) return sign | 0x7ff0000000000000ULL;
    if (kind == 4) {
        u64 pay = nan_payload & 0x000fffffffffffffULL;
        return sign | 0x7ff8000000000000ULL | pay;
    }
    if (r->is_inf) return sign | 0x7ff0000000000000ULL;
    if (r->sig == 0) return sign;
    /* sig has up to 53 bits; exp2 is the unit exponent. Normal when sig >= 2^52. */
    u64 sig = r->sig;
    int e = r->exp2;
    if (sig >> 52) {
        u64 biased = (u64)(e + 52 + 1023);
        return sign | (biased << 52) | (sig & 0x000fffffffffffffULL);
    }
    /* subnormal: e must be -1074 */
    return sign | sig;
}

static u32 assemble_float(const struct rounded *r, int neg, u64 nan_payload, int kind) {
    u32 sign = neg ? 0x80000000u : 0;
    if (kind == 3) return sign | 0x7f800000u;
    if (kind == 4) {
        /* glibc: the payload keeps its low 22 bits (the quiet bit is set), as converting the double payload does. */
        u32 pay = (u32)(nan_payload & 0x003fffffu);
        return sign | 0x7fc00000u | pay;
    }
    if (r->is_inf) return sign | 0x7f800000u;
    if (r->sig == 0) return sign;
    u32 sig = (u32)r->sig;
    int e = r->exp2;
    if (sig >> 23) {
        u32 biased = (u32)(e + 23 + 127);
        return sign | (biased << 23) | (sig & 0x007fffffu);
    }
    return sign | sig;
}

static double bits_to_double(u64 b) {
    union { u64 u; double d; } c;
    c.u = b;
    return c.d;
}

static float bits_to_float(u32 b) {
    union { u32 u; float f; } c;
    c.u = b;
    return c.f;
}

double strtod(const char *s, char **end) {
    char dig[MAX_DIG];
    struct parsed pr;
    parse(s, &pr, dig);
    if (end) *end = (char *)(pr.kind == 0 ? s : pr.end);
    if (pr.kind == 0) return 0.0;
    struct rounded r;
    r.sig = 0;
    r.exp2 = 0;
    r.is_inf = 0;
    r.inexact = 0;
    r.underflow_range = 0;
    if (pr.kind == 1) return bits_to_double(assemble_double(&r, pr.neg, 0, 1));
    if (pr.kind == 3 || pr.kind == 4) return bits_to_double(assemble_double(&r, pr.neg, pr.nan_payload, pr.kind));
    int sat_inf, sat_zero;
    if (!convert(&pr, &DOUBLE_FMT, &r, &sat_inf, &sat_zero)) {
        errno = ERANGE;
        return bits_to_double(assemble_double(&r, pr.neg, 0, 1));
    }
    if (sat_inf) {
        errno = ERANGE;
        r.is_inf = 1;
    } else if (sat_zero) {
        errno = ERANGE;
        r.sig = 0;
    } else {
        if (r.is_inf || r.underflow_range) errno = ERANGE;
    }
    return bits_to_double(assemble_double(&r, pr.neg, 0, 2));
}

float strtof(const char *s, char **end) {
    char dig[MAX_DIG];
    struct parsed pr;
    parse(s, &pr, dig);
    if (end) *end = (char *)(pr.kind == 0 ? s : pr.end);
    if (pr.kind == 0) return 0.0f;
    struct rounded r;
    r.sig = 0;
    r.exp2 = 0;
    r.is_inf = 0;
    r.inexact = 0;
    r.underflow_range = 0;
    if (pr.kind == 1) return bits_to_float(assemble_float(&r, pr.neg, 0, 1));
    if (pr.kind == 3 || pr.kind == 4) return bits_to_float(assemble_float(&r, pr.neg, pr.nan_payload, pr.kind));
    int sat_inf, sat_zero;
    if (!convert(&pr, &FLOAT_FMT, &r, &sat_inf, &sat_zero)) {
        errno = ERANGE;
        return bits_to_float(assemble_float(&r, pr.neg, 0, 1));
    }
    if (sat_inf) {
        errno = ERANGE;
        r.is_inf = 1;
    } else if (sat_zero) {
        errno = ERANGE;
        r.sig = 0;
    } else {
        if (r.is_inf || r.underflow_range) errno = ERANGE;
    }
    return bits_to_float(assemble_float(&r, pr.neg, 0, 2));
}

double atof(const char *s) { return strtod(s, (char **)0); }
