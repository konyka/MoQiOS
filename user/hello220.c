/* hello220: the scanf family in the freestanding user build, on the real kernel: sscanf over strings, fscanf over a file
 * written with fprintf, scanf on a pipe standing in for stdin, floating-point results through xmm registers, the
 * allocating "m" modifier on the real heap, and several threads scanning at the same time. The exact grammar (about 8200
 * rows measured on glibc, and millions of random calls compared against it) is checked on the host. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello220:   ok   " : "hello220:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static unsigned long long bits(double d) { unsigned long long u; memcpy(&u, &d, 8); return u; }

static volatile int worker_bad;
static volatile int stop;
static void *worker(void *arg) {
    long id = (long)arg;
    long n = 0;
    char text[96];
    while (!stop) {
        int a = 0, b = 0;
        double x = 0;
        char w[16];
        double want = (double)(n * 3 + id) / 4.0;
        snprintf(text, sizeof text, "%ld %d %.2f %s", n, (int)(id * 1000 + n % 1000), want, "word");
        int r = sscanf(text, "%d %d %lf %15s", &a, &b, &x, w);
        if (r != 4 || a != (int)n || b != (int)(id * 1000 + n % 1000) || bits(x) != bits(want) || strcmp(w, "word") != 0) worker_bad++;
        n++;
        if ((n & 15) == 0) yield();
    }
    return (void *)n;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello220: scanf family\n");

    /* A: sscanf */
    {
        int a = -1, b = -1, n = -1;
        long l = 0;
        unsigned u = 0;
        char s[32], c = 0;
        check(sscanf("12 34", "%d %d", &a, &b) == 2 && a == 12 && b == 34, "A: two integers");
        check(sscanf("  -7abc", "%d%s", &a, s) == 2 && a == -7 && strcmp(s, "abc") == 0, "A: white space is skipped, the number ends at the letter");
        check(sscanf("0x1F 017 0b101", "%i %i %i", &a, &b, &n) == 3 && a == 31 && b == 15 && n == 5, "A: %i takes hex, octal and binary prefixes");
        check(sscanf("ff 777", "%x %o", &u, &a) == 2 && u == 255 && a == 511, "A: %x and %o");
        check(sscanf("-1", "%u", &u) == 1 && u == 0xffffffffu, "A: %u of -1 wraps, as strtoul does");
        errno = 0;
        check(sscanf("99999999999999999999", "%ld", &l) == 1 && l == 9223372036854775807L && errno == ERANGE, "A: overflow clamps the value and sets ERANGE");
        check(sscanf("12345", "%3d%d", &a, &b) == 2 && a == 123 && b == 45, "A: the field width limits the digits");
        check(sscanf("abc def", "%s %c", s, &c) == 2 && strcmp(s, "abc") == 0 && c == 'd', "A: %s stops at white space, %c takes one character");
        check(sscanf("a-b_c1", "%[a-c_-]", s) == 1 && strcmp(s, "a-b_c") == 0, "A: a scan set with a range, a dash and an underscore");
        check(sscanf("abc123", "%[^0-9]%d", s, &a) == 2 && strcmp(s, "abc") == 0 && a == 123, "A: a negated scan set");
        check(sscanf("hello", "%d", &a) == 0, "A: a mismatch returns the count so far (0)");
        check(sscanf("", "%d", &a) == -1, "A: input that ends before the first conversion returns -1");
        check(sscanf("5", "%d%d", &a, &b) == 1, "A: input that ends after one conversion returns 1");
        check(sscanf("x 12", "x%d%n", &a, &n) == 1 && a == 12 && n == 4, "A: a literal, then %n counts characters consumed");
        check(sscanf("12 34", "%*d %d", &a) == 1 && a == 34, "A: %*d is read and not stored");
        check(sscanf("50%", "%d%%", &a) == 1 && a == 50, "A: %% matches a percent sign");
        check(sscanf("1 2 3 4 5 6", "%3$d %2$d %1$d", &a, &b, &n) == 3 && a == 3 && b == 2 && n == 1, "A: positional arguments");
        check(sscanf("77", "%hhd", &c) == 1 && c == 77, "A: %hhd stores a char");
        check(sscanf("5 6", "%ld %lld", &l, &(long long){0}) == 2 && l == 5, "A: l and ll modifiers");
    }

    /* B: floating point, through xmm registers */
    {
        double d = 0;
        float f = 0;
        check(sscanf("1.5", "%lf", &d) == 1 && bits(d) == bits(1.5), "B: 1.5 as a double");
        check(sscanf("0.1", "%lf", &d) == 1 && bits(d) == bits(0.1), "B: 0.1 is the nearest double");
        check(sscanf("3.14159", "%f", &f) == 1 && f == 3.14159f, "B: a float");
        check(sscanf("-2.5e-3", "%lf", &d) == 1 && bits(d) == bits(-2.5e-3), "B: an exponent");
        check(sscanf("0x1.8p1", "%lf", &d) == 1 && d == 3.0, "B: a hexadecimal float");
        check(sscanf("inf", "%lf", &d) == 1 && bits(d) == 0x7ff0000000000000ULL, "B: inf is +infinity");
        check(sscanf("-Infinity", "%lf", &d) == 1 && bits(d) == 0xfff0000000000000ULL, "B: -Infinity is -infinity");
        check(sscanf("nan", "%lf", &d) == 1 && d != d, "B: nan");
        check(sscanf("1e", "%lf", &d) == 0, "B: an exponent with no digits is not a number");
        check(sscanf("1.5 2.5", "%lf %lf", &d, &(double){0}) == 2 && d == 1.5, "B: two numbers");
        double a = 0, b = 0;
        check(sscanf("1e308 1e-320", "%lf %lf", &a, &b) == 2 && a == 1e308 && b > 0 && b < 1e-300, "B: a huge and a subnormal value");
        errno = 0;
        check(sscanf("1e999", "%lf", &d) == 1 && errno == ERANGE, "B: overflow sets ERANGE");
        errno = 0;
        long double ld = 0;
        unsigned char before[16];
        memcpy(before, &ld, 16);
        check(sscanf("1.5", "%Lf", &ld) == 0 && errno == EINVAL && memcmp(before, &ld, 16) == 0, "B: %Lf (long double) is refused with EINVAL and stores nothing");
    }

    /* C: fscanf over a file, and pushing the lookahead back */
    {
        unlink("/tmp/h220_a");
        FILE *f = fopen("/tmp/h220_a", "w");
        for (int i = 0; i < 600; i++) fprintf(f, "%d %d %.3f\n", i, i * 7, (double)i / 8.0);
        fclose(f);
        f = fopen("/tmp/h220_a", "r");
        int ok = f != (FILE *)0, rows = 0;
        while (f) {
            int a, b;
            double x;
            int r = fscanf(f, "%d %d %lf", &a, &b, &x);
            if (r == -1) break;
            if (r != 3 || a != rows || b != rows * 7 || bits(x) != bits((double)rows / 8.0)) {
                ok = 0;
                break;
            }
            rows++;
        }
        check(ok && rows == 600 && feof(f) && !ferror(f), "C: 600 lines written with fprintf are read back exactly (the file spans several buffer refills)");
        rewind(f);
        int a = 0;
        char line[64];
        check(fscanf(f, "%d", &a) == 1 && a == 0 && fgets(line, sizeof line, f) && strcmp(line, " 0 0.000\n") == 0, "C: fgets continues right after what fscanf took");
        check(fscanf(f, "%d", &a) == 1 && a == 1 && fgetc(f) == ' ', "C: the byte after the number is still there (pushed back)");
        fclose(f);
        f = fopen("/tmp/h220_a", "w");
        errno = 0;
        check(fscanf(f, "%d", &a) == -1 && errno == EBADF, "C: fscanf on a write-only stream fails with EBADF");
        fclose(f);
        unlink("/tmp/h220_a");
    }

    /* D: scanf reads stdin: stand a pipe in for it in a child */
    {
        int fds[2];
        long pid = -1;
        if (pipe(fds) == 0) pid = fork();
        if (pid == 0) {
            int n1 = -1, n2 = -1;
            char w[16];
            dup2(fds[0], 0);
            close(fds[1]);
            int ok = scanf("%d %15s %d", &n1, w, &n2) == 3 && n1 == 42 && strcmp(w, "life") == 0 && n2 == 7;
            ok &= scanf("%d", &n1) == -1 && feof(stdin);
            _exit(ok ? 0 : 1);
        }
        if (pid > 0) {
            close(fds[0]);
            write(fds[1], "42 life\n7", 9);
            close(fds[1]);
            int status = 0;
            check(waitpid(pid, &status, 0) == pid && ((status >> 8) & 0xff) == 0, "D: scanf reads three values from stdin (a pipe) and then sees end of file");
        } else {
            check(0, "D: could not create the pipe or fork");
        }
    }

    /* E: the allocating modifier on the real heap */
    {
        char *w1 = (char *)0, *w2 = (char *)0;
        check(sscanf("hello world", "%ms %ms", &w1, &w2) == 2 && w1 && w2 && strcmp(w1, "hello") == 0 && strcmp(w2, "world") == 0, "E: %ms allocates exact-size strings");
        free(w1);
        free(w2);
        char big[3000];
        memset(big, 'z', sizeof big - 1);
        big[sizeof big - 1] = 0;
        w1 = (char *)0;
        check(sscanf(big, "%ms", &w1) == 1 && w1 && strlen(w1) == sizeof big - 1, "E: a 2999-character string grows the buffer several times");
        free(w1);
        w1 = (char *)0;
        check(sscanf("", "%ms", &w1) == -1 && w1 == (char *)0, "E: no input leaves the pointer NULL");
        for (int i = 0; i < 2000; i++) {
            w1 = (char *)0;
            if (sscanf("abc def", "%ms", &w1) != 1) {
                failures++;
                break;
            }
            free(w1);
        }
        check(1, "E: 2000 allocate-and-free rounds completed");
    }

    /* F: several threads scanning at the same time */
    {
        pthread_t t[4];
        int created = 0;
        for (long i = 0; i < 4; i++) {
            int tries = 0;
            while (pthread_create(&t[i], (void *)0, worker, (void *)i) != 0 && tries++ < 1000) yield();
            if (tries < 1000) created++;
        }
        long mine_bad = 0;
        for (int k = 0; k < 1500; k++) {
            char text[48];
            double x = 0, want = 1.0 + (double)k / 64.0;
            snprintf(text, sizeof text, "%.6f", want);
            yield();
            if (sscanf(text, "%lf", &x) != 1 || bits(x) != bits(want)) mine_bad++;
        }
        stop = 1;
        long total = 0;
        for (int i = 0; i < created; i++) {
            void *rv = (void *)0;
            pthread_join(t[i], &rv);
            total += (long)rv;
        }
        check(created == 4 && worker_bad == 0 && mine_bad == 0 && total > 50, "F: four threads and the main thread scanning and re-parsing numbers never saw a wrong result");
    }

    print(failures == 0 ? "hello220: PASS\n" : "hello220: FAIL\n");
    return failures;
}
