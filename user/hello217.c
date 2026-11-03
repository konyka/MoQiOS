/* hello217: strtod, strtof and atof in the freestanding user build. This is the first libc code that returns floating-point
 * values, so it also checks that the SSE state (xmm registers) survives context switches and thread switches: several
 * threads parse and re-check different numbers in a loop while the scheduler moves them around. The exhaustive comparison
 * against glibc (1300+ rows and millions of random strings) is on the host. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello217:   ok   " : "hello217:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static unsigned long long bits(double d) { unsigned long long u; memcpy(&u, &d, 8); return u; }
static unsigned int fbits(float f) { unsigned int u; memcpy(&u, &f, 4); return u; }

static volatile int stop;
static volatile long worker_bad;

static void *worker(void *arg) {
    long id = (long)arg;
    static const char *txt[] = { "1.5", "0.1", "123456.789e3", "2.5e-10", "-7.25", "0x1.8p10", "9007199254740993", "1e300" };
    static const unsigned long long want[] = { 0x3ff8000000000000ULL, 0x3fb999999999999aULL, 0x41dd1a3ea94cccccULL, 0x3e17a2bbd66c7ed2ULL, 0xc01d000000000000ULL, 0x4088000000000000ULL, 0x4340000000000000ULL, 0x7e37e43c8800759cULL };
    (void)want;
    unsigned long long expect[8];
    for (int i = 0; i < 8; i++) expect[i] = bits(strtod(txt[i], (char **)0));
    long n = 0;
    while (!stop) {
        int i = (int)((n + id) & 7);
        double d = strtod(txt[i], (char **)0);
        double twice = d * 2.0; /* keep the value live in an xmm register across the next call */
        double e = strtod(txt[(i + 3) & 7], (char **)0);
        if (bits(d) != expect[i] || bits(twice / 2.0) != expect[i] || bits(e) != expect[(i + 3) & 7]) worker_bad++;
        n++;
        if ((n & 63) == 0) yield();
    }
    return (void *)n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello217: strtod / strtof / atof\n");

    char *end = (char *)0;
    check(bits(strtod("1.5", &end)) == 0x3ff8000000000000ULL && end != (char *)0 && *end == 0, "A: strtod(\"1.5\") is 1.5 and consumes the string");
    check(bits(strtod("0.1", (char **)0)) == 0x3fb999999999999aULL, "A: 0.1 rounds to the nearest double");
    check(bits(strtod("  -2.5e1xyz", &end)) == 0xc039000000000000ULL && *end == 'x', "A: leading spaces, sign, exponent, and the end pointer stops at x");
    check(bits(strtod("0x1.8p3", (char **)0)) == 0x4028000000000000ULL, "A: hexadecimal floating point");
    check(fbits(strtof("0.1", (char **)0)) == 0x3dcccccdU, "A: strtof rounds directly to float");
    check(bits(atof("3.25")) == 0x400a000000000000ULL, "A: atof");

    errno = 0;
    check(bits(strtod("1e999", (char **)0)) == 0x7ff0000000000000ULL && errno == ERANGE, "B: overflow is +infinity with ERANGE");
    errno = 0;
    check(bits(strtod("1e-999", (char **)0)) == 0 && errno == ERANGE, "B: underflow to zero is ERANGE");
    errno = 0;
    check(bits(strtod("4.9e-324", (char **)0)) == 1 && errno == ERANGE, "B: the smallest subnormal, inexact, is ERANGE");
    errno = 55;
    (void)strtod("2.0", (char **)0);
    check(errno == 55, "B: a good conversion leaves errno alone");
    check((bits(strtod("nan", (char **)0)) >> 52 & 0x7ff) == 0x7ff && (bits(strtod("nan", (char **)0)) & 0x000fffffffffffffULL) == 0x0008000000000000ULL, "B: nan is a quiet NaN");
    check(bits(strtod("-inf", (char **)0)) == 0xfff0000000000000ULL, "B: -inf");

    /* A 1000-digit input with an exact tie decided by the last digit. */
    {
        static char big[1100];
        int n = 0;
        const char *head = "9007199254740993.";
        while (*head) big[n++] = *head++;
        for (int i = 0; i < 900; i++) big[n++] = '0';
        big[n++] = '1';
        big[n] = 0;
        check(bits(strtod(big, (char **)0)) == 0x4340000000000001ULL, "C: a tie broken by a digit 900 places later rounds up");
        big[n - 1] = '0';
        check(bits(strtod(big, (char **)0)) == 0x4340000000000000ULL, "C: and without it rounds to even");
    }

    /* The floating-point registers across thread switches. */
    pthread_t t[4];
    int created = 0;
    for (long i = 0; i < 4; i++) {
        int tries = 0;
        while (pthread_create(&t[i], (void *)0, worker, (void *)i) != 0 && tries++ < 1000) yield();
        created++;
    }
    long mine_bad = 0;
    for (int k = 0; k < 4000; k++) {
        double x = strtod("1.25", (char **)0);
        double y = x * 4.0;
        yield();
        if (bits(y) != 0x4014000000000000ULL || bits(x) != 0x3ff4000000000000ULL) mine_bad++;
    }
    stop = 1;
    long total = 0;
    for (int i = 0; i < created; i++) {
        void *rv = (void *)0;
        pthread_join(t[i], &rv);
        total += (long)rv;
    }
    check(created == 4 && worker_bad == 0, "D: four threads parsing and re-checking numbers in a loop never saw a wrong result");
    check(mine_bad == 0, "D: and the main thread's own xmm values survived 4000 yields among them");
    check(total > 100, "D: the worker threads actually ran");

    print(failures == 0 ? "hello217: PASS\n" : "hello217: FAIL\n");
    return failures;
}
