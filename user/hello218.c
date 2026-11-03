/* hello218: printf's floating-point conversions (f F e E g G a A) in the freestanding user build, with the value passed in
 * an xmm register through varargs, and round trips with strtod. The exhaustive comparison against glibc (9000+ rows,
 * millions of random formats) is on the host. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello218:   ok   " : "hello218:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int is(const char *got, const char *want) { return strcmp(got, want) == 0; }
static unsigned long long bits(double d) { unsigned long long u; memcpy(&u, &d, 8); return u; }

static volatile int stop;
static volatile long worker_bad;
static void *worker(void *arg) {
    long id = (long)arg;
    long n = 0;
    char b[64];
    while (!stop) {
        double x = (double)(n + id * 1000) / 8.0;
        snprintf(b, sizeof b, "%.3f", x);
        double back = strtod(b, (char **)0);
        if (bits(back) != bits(x)) worker_bad++;
        n++;
        if ((n & 31) == 0) yield();
    }
    return (void *)n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello218: printf floating point\n");

    char b[600];
    snprintf(b, sizeof b, "%f|%e|%g|%a", 1.5, 1.5, 1.5, 1.5);
    check(is(b, "1.500000|1.500000e+00|1.5|0x1.8p+0"), "A: f, e, g and a of 1.5");
    snprintf(b, sizeof b, "%.0f|%.0f|%.0f|%.0f", 0.5, 1.5, 2.5, 3.5);
    check(is(b, "0|2|2|4"), "A: ties round to even, from the exact value (%.0f of 0.5, 1.5, 2.5, 3.5)");
    snprintf(b, sizeof b, "%.1f|%.1f|%.2f", 0.25, 0.35, 2.675);
    check(is(b, "0.2|0.3|2.67"), "A: 0.35 and 2.675 are below their decimal ties in binary, so they round down");
    snprintf(b, sizeof b, "%f", 0.1);
    check(is(b, "0.100000"), "A: 0.1");
    snprintf(b, sizeof b, "%.20f", 0.1);
    check(is(b, "0.10000000000000000555"), "A: 0.1 to 20 places shows the real binary value");
    snprintf(b, sizeof b, "%.17g|%.17g", 0.1, 1e23);
    check(is(b, "0.10000000000000001|9.9999999999999992e+22"), "A: %.17g round-trips (0.1 and 1e23 print their exact neighbors)");
    snprintf(b, sizeof b, "%g|%g|%g|%g", 100000.0, 1000000.0, 0.0001, 0.00001);
    check(is(b, "100000|1e+06|0.0001|1e-05"), "B: %g switches to the exponent style at 10^6 and below 10^-4");
    snprintf(b, sizeof b, "%#g|%#.3g|%#.0f|%#.0e", 1.0, 999.5, 3.0, 5.0);
    check(is(b, "1.00000|1.e+03|3.|5.e+00"), "B: '#' keeps trailing zeros and the point, including the 999.5 carry quirk");
    snprintf(b, sizeof b, "[%10.3f][%-10.3f][%010.3f][%+.1f][% .1f]", 3.14159, 3.14159, -3.14159, 2.0, 2.0);
    check(is(b, "[     3.142][3.142     ][-00003.142][+2.0][ 2.0]"), "B: width, left, zero, plus and space flags");
    {
        unsigned long long qn = 0xfff8000000000000ULL, pn = 0x7ff8000000000000ULL, pi = 0x7ff0000000000000ULL, ni = 0xfff0000000000000ULL;
        double dq, dp, dpi, dni;
        memcpy(&dq, &qn, 8); memcpy(&dp, &pn, 8); memcpy(&dpi, &pi, 8); memcpy(&dni, &ni, 8);
        snprintf(b, sizeof b, "%f|%F|%e|%G|%g", dpi, dni, dq, dpi, dp);
        check(is(b, "inf|-INF|-nan|INF|nan"), "B: inf and nan print as words, the sign of a negative nan is kept");
    }
    snprintf(b, sizeof b, "%08.2f|%+010f|%-8f|", 1.0 / 0.0, -1.0 / 0.0, 1.0 / 0.0);
    check(is(b, "     inf|      -inf|inf     |"), "B: inf is never zero padded");
    snprintf(b, sizeof b, "%a|%a|%.0a|%.1a|%A", 0.1, 4.9406564584124654e-324, 1.5, 1.96875, 255.5);
    check(is(b, "0x1.999999999999ap-4|0x0.0000000000001p-1022|0x2p+0|0x2.0p+0|0X1.FFP+7"), "C: hexadecimal floats: rounding carries into the lead digit (0x2.0p+0), subnormal, capitals");
    snprintf(b, sizeof b, "%.0f", 1e22);
    check(is(b, "10000000000000000000000"), "D: 1e22 is exact");
    snprintf(b, sizeof b, "%.0f", 1e23);
    check(is(b, "99999999999999991611392"), "D: 1e23 is really 99999999999999991611392");
    snprintf(b, sizeof b, "%.0f", 1.7976931348623157e308);
    check(strlen(b) == 309 && b[0] == '1' && b[1] == '7' && b[2] == '9' && b[308] == '8', "D: DBL_MAX has 309 digits");
    snprintf(b, sizeof b, "%.0e|%.20e", 4.9406564584124654e-324, 4.9406564584124654e-324);
    check(is(b, "5e-324|4.94065645841246544177e-324"), "D: the smallest subnormal");
    int n = snprintf((char *)0, 0, "%.700f", 1.0);
    check(n == 702, "D: snprintf(NULL, 0, \"%.700f\") counts 702 characters");

    /* Round trips through strtod. */
    int ok = 1;
    unsigned long long x = 0x9E3779B97F4A7C15ULL;
    for (int i = 0; i < 2000; i++) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        double d;
        unsigned long long u = (x & 0x800fffffffffffffULL) | (((x >> 20) % 2000 + 24) << 52); /* finite, exponent 24..2023 */
        if (((u >> 52) & 0x7ff) == 0x7ff) continue;
        memcpy(&d, &u, 8);
        snprintf(b, sizeof b, "%.17g", d);
        if (bits(strtod(b, (char **)0)) != bits(d)) { ok = 0; break; }
        snprintf(b, sizeof b, "%a", d);
        if (bits(strtod(b, (char **)0)) != bits(d)) { ok = 0; break; }
    }
    check(ok, "E: 2000 random doubles survive %.17g -> strtod and %a -> strtod");

    /* xmm registers across thread switches while formatting. */
    pthread_t t[3];
    int created = 0;
    for (long i = 0; i < 3; i++) {
        int tries = 0;
        while (pthread_create(&t[i], (void *)0, worker, (void *)i) != 0 && tries++ < 1000) yield();
        created++;
    }
    long mine_bad = 0;
    for (int k = 0; k < 1500; k++) {
        snprintf(b, sizeof b, "%.6f", 1.0 + (double)k / 64.0);
        yield();
        if (bits(strtod(b, (char **)0)) != bits(1.0 + (double)k / 64.0)) mine_bad++;
    }
    stop = 1;
    long total = 0;
    for (int i = 0; i < created; i++) {
        void *rv = (void *)0;
        pthread_join(t[i], &rv);
        total += (long)rv;
    }
    check(created == 3 && worker_bad == 0 && mine_bad == 0 && total > 50, "F: three threads and the main thread formatting and re-parsing numbers never saw a wrong result");

    print(failures == 0 ? "hello218: PASS\n" : "hello218: FAIL\n");
    return failures;
}
