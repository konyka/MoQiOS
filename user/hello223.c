/* hello223: the math and ctype functions in the freestanding user build, on the real kernel. The exact bit-for-bit comparison with
 * glibc (25000 rows, 9 million random calls, and every defined argument of ctype) is done on the host; here the point is that the
 * code survives the user-space build (no function turned into a call to itself by the optimizer, doubles passed and returned in
 * xmm registers, errno per thread) and keeps its results when four threads use it while being preempted. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/math.h"
#include "../lib/moqi_libc/include/ctype.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello223:   ok   " : "hello223:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static unsigned long long bits(double d) { unsigned long long u; memcpy(&u, &d, 8); return u; }
static double dbl(unsigned long long u) { double d; memcpy(&d, &u, 8); return d; }

static volatile int worker_bad;
static volatile int stop;
static void *worker(void *arg) {
    long id = (long)arg;
    long n = 0;
    while (!stop) {
        double x = (double)(n % 1000) * 0.25 + (double)id;
        double r = sqrt(x * x);
        if (bits(r) != bits(x)) worker_bad++;
        if (fmod(x + 3.0, 3.0) != fmod(x, 3.0)) worker_bad++;
        int e;
        double m = frexp(x, &e);
        if (x != 0.0 && bits(ldexp(m, e)) != bits(x)) worker_bad++;
        errno = 0;
        (void)sqrt(-1.0 - x);
        if (errno != EDOM) worker_bad++;
        n++;
        if ((n & 63) == 0) yield();
    }
    return (void *)n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello223: math and ctype\n");

    /* A: exact results */
    check(bits(sqrt(2.0)) == 0x3ff6a09e667f3bcdULL, "A: sqrt(2) is the correctly rounded value");
    check(sqrt(1e300) == 1e150 && sqrt(0.25) == 0.5 && sqrt(0.0) == 0.0 && bits(sqrt(-0.0)) == 0x8000000000000000ULL, "A: sqrt of exact squares and of -0");
    errno = 0;
    check(isnan(sqrt(-1.0)) && errno == EDOM, "A: sqrt(-1) is a NaN with EDOM");
    check(floor(-0.5) == -1.0 && bits(ceil(-0.5)) == 0x8000000000000000ULL && trunc(2.9) == 2.0 && round(2.5) == 3.0 && rint(2.5) == 2.0 && rint(3.5) == 4.0, "A: floor, ceil, trunc, round and rint");
    check(lround(2.5) == 3 && lround(-2.5) == -3 && lrint(2.5) == 2 && llround(1e15 + 0.5) == 1000000000000001LL, "A: lround, lrint, llround");
    check(fmod(7.5, 2.0) == 1.5 && fmod(-7.5, 2.0) == -1.5 && remainder(7.0, 2.0) == -1.0 && remainder(5.0, 3.0) == -1.0, "A: fmod and remainder");
    int q = 0;
    check(remquo(10.0, 3.0, &q) == 1.0 && q == 3, "A: remquo(10, 3) is 1 with quotient 3");
    check(ldexp(1.0, 10) == 1024.0 && ldexp(1.0, 1024) == INFINITY && bits(ldexp(1.0, -1074)) == 1, "A: ldexp, including overflow and the smallest subnormal");
    int e = 0;
    check(frexp(8.0, &e) == 0.5 && e == 4, "A: frexp(8) is 0.5 * 2^4");
    double ip = 0;
    check(modf(-3.75, &ip) == -0.75 && ip == -3.0, "A: modf splits -3.75");
    check(fmax(NAN, 1.0) == 1.0 && fmin(-0.0, 0.0) == 0.0 && signbit(fmin(-0.0, 0.0)) && copysign(3.0, -0.0) == -3.0 && fdim(5.0, 3.0) == 2.0, "A: fmax with a NaN, signed zeros, copysign, fdim");
    check(bits(nextafter(1.0, 2.0)) == 0x3ff0000000000001ULL && bits(nextafter(0.0, 1.0)) == 1 && nextafter(1.0, 1.0) == 1.0, "A: nextafter");
    check(fabs(-2.5) == 2.5 && bits(fabs(-0.0)) == 0 && fabs(-INFINITY) == INFINITY, "A: fabs");
    check(fpclassify(1.0) == FP_NORMAL && fpclassify(0.0) == FP_ZERO && fpclassify(5e-324) == FP_SUBNORMAL && fpclassify(INFINITY) == FP_INFINITE && fpclassify(NAN) == FP_NAN, "A: fpclassify");

    /* B: a sweep, comparing against identities that must hold exactly */
    {
        int bad = 0;
        for (int i = 1; i <= 20000; i++) {
            double x = (double)i * 0.5 + 0.125;
            if (sqrt(x * x) != x) bad++;                          /* x*x is exact for these sizes */
            if (floor(x) + 1.0 != ceil(x)) bad++;                  /* x is never an integer here */
            if (trunc(-x) != -floor(x)) bad++;
            if (round(x) - x > 0.5 || x - round(x) > 0.5) bad++;
            double f = modf(x, &ip);
            if (ip + f != x) bad++;
            int ex;
            double mm = frexp(x, &ex);
            if (mm < 0.5 || mm >= 1.0 || ldexp(mm, ex) != x) bad++;
            if (fmod(x, 1.0) != f) bad++;
        }
        check(bad == 0, "B: 20000 values satisfy sqrt(x*x)==x, floor/ceil/trunc/round/modf/frexp/fmod identities");
    }

    /* C: the whole double range through the bit-level functions, compared among themselves */
    {
        int bad = 0;
        unsigned long long s = 0x9e3779b97f4a7c15ULL;
        for (int i = 0; i < 20000; i++) {
            s = s * 6364136223846793005ULL + 1442695040888963407ULL;
            double x = dbl(s);
            if (isnan(x)) continue;
            int ex;
            double mm = frexp(x, &ex);
            if (isfinite(x) && x != 0.0 && bits(ldexp(mm, ex)) != bits(x)) bad++;
            if (isfinite(x) && bits(copysign(fabs(x), x)) != bits(x)) bad++;
            if (isfinite(x) && floor(x) > x) bad++;
            if (isfinite(x) && ceil(x) < x) bad++;
            if (isfinite(x) && trunc(x) != (x < 0 ? ceil(x) : floor(x))) bad++;
            if (x > 0 && isfinite(x)) {
                double r = sqrt(x);
                if (r * r > x * (1 + 1e-15) || r * r < x * (1 - 1e-15)) { if (x > 1e-300 && x < 1e300) bad++; }
            }
        }
        check(bad == 0, "C: 20000 random bit patterns: frexp/ldexp round trip, copysign, floor/ceil/trunc order, sqrt squared");
    }

    /* D: ctype */
    {
        int bad = 0;
        for (int c = -1; c < 256; c++) {
            int upper = c >= 'A' && c <= 'Z', lower = c >= 'a' && c <= 'z', digit = c >= '0' && c <= '9';
            if (!!isalpha(c) != (upper || lower)) bad++;
            if (!!isalnum(c) != (upper || lower || digit)) bad++;
            if (!!isxdigit(c) != (digit || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) bad++;
            if (!!isprint(c) != (c >= 32 && c < 127)) bad++;
            if (!!ispunct(c) != (c > 32 && c < 127 && !(upper || lower || digit))) bad++;
            if (!!iscntrl(c) != ((c >= 0 && c < 32) || c == 127)) bad++;
            if (toupper(c) != (lower ? c - 32 : c)) bad++;
            if (tolower(c) != (upper ? c + 32 : c)) bad++;
        }
        check(bad == 0 && isblank(' ') && isblank('\t') && !isblank('\n') && isgraph('!') && !isgraph(' '), "D: ctype over -1..255");
    }

    /* E: threads */
    {
        pthread_t t[4];
        int created = 0;
        for (long i = 0; i < 4; i++) {
            int tries = 0;
            while (pthread_create(&t[i], (void *)0, worker, (void *)i) != 0 && tries++ < 1000) yield();
            if (tries < 1000) created++;
        }
        long main_bad = 0;
        for (int k = 0; k < 3000; k++) {
            double x = (double)k + 0.5;
            if (bits(sqrt(x * x)) != bits(x)) main_bad++;
            errno = 0;
            (void)fmod(1.0, 0.0);
            if (errno != EDOM) main_bad++;
            if ((k & 31) == 0) yield();
        }
        stop = 1;
        long total = 0;
        for (int i = 0; i < created; i++) {
            void *rv = (void *)0;
            pthread_join(t[i], &rv);
            total += (long)rv;
        }
        check(created == 4 && worker_bad == 0 && main_bad == 0 && total > 50, "E: four threads and the main thread: correct results, and each thread sees its own errno");
    }

    print(failures == 0 ? "hello223: PASS\n" : "hello223: FAIL\n");
    return failures;
}
