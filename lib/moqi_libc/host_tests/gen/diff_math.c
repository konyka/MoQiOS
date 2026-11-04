/* diff_math.c — differential fuzzer: random arguments go through glibc's math functions and through src/math.c, and every
 * result bit, errno and integer quotient must agree (a NaN only has to be a NaN of the same quietness).
 *
 *   zig cc -O1 -g -w -fno-builtin -Dsqrt=m_sqrt ... (every function renamed, see run line in docs) -c ../src/math.c -o math_m.o
 *   gcc -O1 -o diff_math gen/diff_math.c math_m.o -lm && ./diff_math N SEED
 */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int *m_errno_location(void) { return &errno; }
#define DECL1(n) double m_##n(double)
#define DECL2(n) double m_##n(double, double)
DECL1(sqrt); DECL1(fabs); DECL1(floor); DECL1(ceil); DECL1(trunc); DECL1(round); DECL1(rint); DECL1(nearbyint);
DECL2(copysign); DECL2(fmod); DECL2(remainder); DECL2(fmax); DECL2(fmin); DECL2(fdim); DECL2(nextafter);
double m_ldexp(double, int); double m_scalbn(double, int); double m_frexp(double, int *); double m_modf(double, double *); double m_remquo(double, double, int *);
long m_lround(double); long long m_llround(double); long m_lrint(double); long long m_llrint(double);

static uint64_t rng;
static uint64_t next(void) {
    uint64_t z = (rng += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}
static unsigned rnd(unsigned n) { return (unsigned)(next() % n); }
static uint64_t B(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static double D(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }
static int isnanb(uint64_t u) { return (u & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL && (u & 0xfffffffffffffULL); }
static int eq(uint64_t a, uint64_t b) {
    if (isnanb(a) || isnanb(b)) return isnanb(a) && isnanb(b) && ((a >> 51) & 1) == ((b >> 51) & 1);
    return a == b;
}
static uint64_t rbits(void) {
    switch (rnd(9)) {
    case 0: return next();
    case 1: return B((double)(int)(next() % 4001) - 2000.0);
    case 2: return B((double)(int64_t)next() / 1099511627776.0);
    case 3: return B((double)(int)(next() % 8001 - 4000) / 4.0);
    case 4: return next() & 0x800fffffffffffffULL;
    case 5: return (next() & 0x800fffffffffffffULL) | ((uint64_t)(1 + rnd(2046)) << 52);
    case 6: return B(4503599627370496.0 + (double)(next() % 8)) | (next() & 0x8000000000000000ULL);
    case 7: return B(1.0) + (uint64_t)(next() % 64) - 32;
    default: return B((double)(int64_t)next());
    }
}

int main(int argc, char **argv) {
    long iters = argc > 1 ? atol(argv[1]) : 1000000;
    rng = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
    long bad = 0;
#define REPORT(...) do { if (++bad <= 30) { printf(__VA_ARGS__); printf("\n"); } } while (0)
#define U1(n) do { uint64_t a = rbits(); errno = 0; volatile double x = D(a); double g = n(x); int ge = errno; errno = 0; double m = m_##n(x); int me = errno; \
    if (!eq(B(g), B(m)) || ge != me) REPORT(#n "(%016llx): glibc %016llx e%d, mine %016llx e%d", (unsigned long long)a, (unsigned long long)B(g), ge, (unsigned long long)B(m), me); } while (0)
#define U2(n) do { uint64_t a = rbits(), b = rbits(); if (rnd(4) == 0) b = a + (uint64_t)(next() % 5) - 2; errno = 0; volatile double x = D(a), y = D(b); double g = n(x, y); int ge = errno; errno = 0; double m = m_##n(x, y); int me = errno; \
    if (!eq(B(g), B(m)) || ge != me) REPORT(#n "(%016llx, %016llx): glibc %016llx e%d, mine %016llx e%d", (unsigned long long)a, (unsigned long long)b, (unsigned long long)B(g), ge, (unsigned long long)B(m), me); } while (0)
#define L1(n) do { uint64_t a = rbits(); volatile double x = D(a); long long g = (long long)n(x); long long m = (long long)m_##n(x); \
    if (g != m) REPORT(#n "(%016llx): glibc %lld, mine %lld", (unsigned long long)a, g, m); } while (0)
    for (long it = 0; it < iters; it++) {
        U1(sqrt); U1(fabs); U1(floor); U1(ceil); U1(trunc); U1(round); U1(rint); U1(nearbyint);
        U2(copysign); U2(fmod); U2(remainder); U2(fmax); U2(fmin); U2(fdim); U2(nextafter);
        L1(lround); L1(llround); L1(lrint); L1(llrint);
        {
            uint64_t a = rbits();
            int n = (int)rnd(4800) - 2400;
            if (rnd(30) == 0) n = (int)next();
            errno = 0; volatile double x = D(a); double g = ldexp(x, n); int ge = errno; errno = 0; double m = m_ldexp(x, n); int me = errno;
            if (!eq(B(g), B(m)) || ge != me) REPORT("ldexp(%016llx, %d): glibc %016llx e%d, mine %016llx e%d", (unsigned long long)a, n, (unsigned long long)B(g), ge, (unsigned long long)B(m), me);
            errno = 0; g = scalbn(x, n); ge = errno; errno = 0; m = m_scalbn(x, n); me = errno;
            if (!eq(B(g), B(m)) || ge != me) REPORT("scalbn(%016llx, %d)", (unsigned long long)a, n);
            int e1 = 7, e2 = 7; g = frexp(x, &e1); m = m_frexp(x, &e2);
            if (!eq(B(g), B(m)) || e1 != e2) REPORT("frexp(%016llx): glibc %016llx %d, mine %016llx %d", (unsigned long long)a, (unsigned long long)B(g), e1, (unsigned long long)B(m), e2);
            double i1 = 1, i2 = 1; g = modf(x, &i1); m = m_modf(x, &i2);
            if (!eq(B(g), B(m)) || !eq(B(i1), B(i2))) REPORT("modf(%016llx)", (unsigned long long)a);
        }
        {
            uint64_t a = rbits(), b = rbits();
            if (rnd(2)) { a = B(1.0 + (double)rnd(100000) / 13.0) + ((uint64_t)rnd(40) << 52); b = B(1.0 + (double)rnd(1000) / 7.0) + ((uint64_t)rnd(30) << 52); }
            volatile double x = D(a), y = D(b);
            int q1 = 7, q2 = 7; errno = 0; double g = remquo(x, y, &q1); int ge = errno; errno = 0; double m = m_remquo(x, y, &q2); int me = errno;
            int a1 = q1 < 0 ? -q1 : q1, a2 = q2 < 0 ? -q2 : q2;
            (void)a1; (void)a2;
            int qok = q1 == q2;
            if (!eq(B(g), B(m)) || ge != me || !qok) REPORT("remquo(%016llx, %016llx): glibc %016llx q%d e%d, mine %016llx q%d e%d", (unsigned long long)a, (unsigned long long)b, (unsigned long long)B(g), q1, ge, (unsigned long long)B(m), q2, me);
        }
    }
    printf("%ld iterations, %ld differences\n", iters, bad);
    return bad != 0;
}
