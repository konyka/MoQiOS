/* fpfmt.h — exact binary64 -> decimal conversion for the printf engine (included by format.c, not a public header).
 *
 * A double is m * 2^e2 with m < 2^53, so its decimal expansion is finite and at most 767 significant digits. It is produced
 * exactly with integer arithmetic (a small fixed-size big number for the part that does not fit 64 bits), and rounding to
 * any number of digits is then done on the digits, nearest-even on the exact value. That makes %f/%e/%g agree with glibc
 * for every input and precision, ties included, with no floating-point arithmetic.
 */
#ifndef MOQI_FPFMT_H
#define MOQI_FPFMT_H

typedef unsigned long long fp_u64;
typedef unsigned int fp_u32;

/* 767 significant digits is the most any double has (the smallest subnormal has 751); one more for a rounding carry. */
#define FP_MAXDIG 800

struct fp_dec {
    unsigned char d[FP_MAXDIG]; /* digits 0..9, d[0] != 0, d[n-1] != 0 */
    int n;                      /* number of digits; 0 for the value zero */
    int x;                      /* decimal exponent of d[0]: value = d[0].d[1]d[2]... * 10^x */
};

/* 1074 fraction bits, plus room for the carry of a multiply by 10. */
#define FP_LIMBS 36

/* value = m * 2^e2, m > 0 */
static void fp_exact(fp_u64 m, int e2, struct fp_dec *o) {
    o->n = 0;
    o->x = 0;
    if (m == 0) return;

    if (e2 >= 0) {
        fp_u32 w[FP_LIMBS];
        int nw = 0;
        for (int i = 0; i < FP_LIMBS; i++) w[i] = 0;
        /* N = m << e2 */
        int ls = e2 / 32, bs = e2 % 32;
        fp_u64 lo = m << bs;
        fp_u64 hi = bs ? (m >> (64 - bs)) : 0;
        w[ls] = (fp_u32)lo;
        w[ls + 1] = (fp_u32)(lo >> 32);
        w[ls + 2] = (fp_u32)hi;
        nw = ls + 3;
        while (nw > 0 && w[nw - 1] == 0) nw--;

        /* Decimal digits by repeated division by 10^9; chunks come out least significant first. */
        fp_u32 chunk[40];
        int nc = 0;
        while (nw > 0) {
            fp_u64 rem = 0;
            for (int i = nw - 1; i >= 0; i--) {
                fp_u64 cur = (rem << 32) | w[i];
                w[i] = (fp_u32)(cur / 1000000000u);
                rem = cur % 1000000000u;
            }
            chunk[nc++] = (fp_u32)rem;
            while (nw > 0 && w[nw - 1] == 0) nw--;
        }
        unsigned char tmp[360];
        int len = 0;
        for (int c = nc - 1; c >= 0; c--) {
            char buf[9];
            fp_u32 v = chunk[c];
            for (int i = 8; i >= 0; i--) {
                buf[i] = (char)(v % 10);
                v /= 10;
            }
            int start = 0;
            if (c == nc - 1) {
                while (start < 8 && buf[start] == 0) start++;
            }
            for (int i = start; i < 9; i++) tmp[len++] = (unsigned char)buf[i];
        }
        o->x = len - 1;
        while (len > 0 && tmp[len - 1] == 0) len--;
        for (int i = 0; i < len; i++) o->d[i] = tmp[i];
        o->n = len;
        return;
    }

    /* e2 < 0: value = m / 2^k */
    int k = -e2;
    fp_u64 ip, frac;
    if (k >= 64) {
        ip = 0;
        frac = m;
    } else {
        ip = m >> k;
        frac = m & ((((fp_u64)1) << k) - 1);
    }

    int n = 0;
    int zeros = 0; /* leading fraction zeros, when the integer part is zero */
    int had_int = ip != 0;
    if (ip) {
        unsigned char t[24];
        int tl = 0;
        while (ip) {
            t[tl++] = (unsigned char)(ip % 10);
            ip /= 10;
        }
        o->x = tl - 1;
        for (int i = tl - 1; i >= 0; i--) o->d[n++] = t[i];
    }

    fp_u32 fl[FP_LIMBS];
    for (int i = 0; i < FP_LIMBS; i++) fl[i] = 0;
    fl[0] = (fp_u32)frac;
    fl[1] = (fp_u32)(frac >> 32);
    int nl = k / 32 + 2;
    int li = k >> 5, sh = k & 31;
    for (;;) {
        int nonzero = 0;
        for (int i = 0; i < nl; i++)
            if (fl[i]) {
                nonzero = 1;
                break;
            }
        if (!nonzero) break;
        fp_u64 carry = 0;
        for (int i = 0; i < nl; i++) {
            fp_u64 t = (fp_u64)fl[i] * 10u + carry;
            fl[i] = (fp_u32)t;
            carry = t >> 32;
        }
        fp_u32 v = fl[li] >> sh;
        if (sh) v |= fl[li + 1] << (32 - sh);
        unsigned digit = v & 0xFu;
        fl[li] &= sh ? ((1u << sh) - 1u) : 0u;
        fl[li + 1] = 0;
        if (n == 0 && digit == 0) {
            zeros++;
            continue;
        }
        if (n < FP_MAXDIG) o->d[n++] = (unsigned char)digit;
    }
    if (!had_int) o->x = -1 - zeros;
    while (n > 0 && o->d[n - 1] == 0) n--;
    o->n = n;
}

struct fp_round {
    unsigned char r[FP_MAXDIG + 2];
    int rn; /* digits in r; r[i] for i >= rn is zero */
    int x;  /* decimal exponent of r[0] (valid only when rn > 0) */
};

/* Keep the first k digits of o, rounding nearest-even on the exact value. k may be <= 0 (everything is below the rounding
 * position) or larger than o->n (nothing to round). The kept digits are zero past rn. If the rounding carries out of the
 * first digit, r becomes "1" followed by zeros and x grows by one. */
static void fp_round_digits(const struct fp_dec *o, long long k, struct fp_round *rr) {
    rr->x = o->x;
    rr->rn = 0;
    if (k < 0) return;
    int keep = (k < o->n) ? (int)k : o->n;
    for (int i = 0; i < keep; i++) rr->r[i] = o->d[i];
    rr->rn = keep;
    if (k >= o->n) return; /* exact */

    int up = 0;
    int digit = o->d[k];
    if (digit > 5) {
        up = 1;
    } else if (digit == 5) {
        int sticky = (k + 1 < o->n); /* d[n-1] != 0, so anything after the 5 is nonzero */
        if (sticky) up = 1;
        else up = (k > 0 && (o->d[k - 1] & 1)); /* exact tie: round to even */
    }
    if (!up) return;

    int i = keep - 1;
    while (i >= 0) {
        if (rr->r[i] == 9) {
            rr->r[i] = 0;
            i--;
        } else {
            rr->r[i]++;
            return;
        }
    }
    /* carried out of the first digit */
    for (int j = keep; j > 0; j--) rr->r[j] = rr->r[j - 1];
    rr->r[0] = 1;
    rr->rn = keep + 1;
    rr->x = o->x + 1;
}

#endif /* MOQI_FPFMT_H */
