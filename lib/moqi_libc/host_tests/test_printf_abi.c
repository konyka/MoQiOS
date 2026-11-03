/* test_printf_abi.c — the printf family (vsnprintf, snprintf, vsprintf, sprintf, asprintf, vasprintf, dprintf, vdprintf,
 * printf, vprintf, puts, putchar) checked against glibc. test_printf_rows.inc holds 2400+ rows generated from glibc
 * (flags, width, precision, '*', every length modifier, wide characters, unknown conversions, output size limits); the
 * rest are checks that need pointers or failure injection, which a table cannot hold. */
#include <stdio.h>
#include <string.h>

void *malloc(unsigned long n); /* the host's, reached through the wrappers below */
void free(void *p);

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static int fail_malloc;
static unsigned long last_malloc_n;
static void *test_malloc(unsigned long n) { last_malloc_n = n; return fail_malloc ? (void *)0 : malloc(n); }

/* write() is captured: everything written goes to cap[], short writes and failures can be injected. */
static char cap[1 << 16];
static unsigned long cap_len;
static int write_calls;
static long write_limit;       /* >0: accept at most this many bytes per call */
static int write_fail_after;   /* >0: the Nth call from now fails with -EBADF (9) */
static int write_last_fd;
static int write_eintr;        /* the next N calls return -EINTR (4) */
static int write_zero;         /* the next call accepts nothing */
long test_write(int fd, const void *b, size_t n) {
    write_calls++;
    write_last_fd = fd;
    if (write_eintr > 0) { write_eintr--; return -4; }
    if (write_zero) { write_zero = 0; return 0; }
    if (write_fail_after && --write_fail_after == 0) return -9;
    if (write_limit > 0 && (long)n > write_limit) n = (unsigned long)write_limit;
    if (cap_len + n > sizeof cap) n = sizeof cap - cap_len;
    memcpy(cap + cap_len, b, n);
    cap_len += n;
    return (long)n;
}

/* Some glibc headers (Ubuntu's, with fortification) define printf, snprintf, sprintf and dprintf as macros. */
#undef printf
#undef snprintf
#undef sprintf
#undef dprintf
#define malloc test_malloc
#define write test_write
#define vsnprintf moqi_vsnprintf
#define snprintf moqi_snprintf
#define vsprintf moqi_vsprintf
#define sprintf moqi_sprintf
#define vasprintf moqi_vasprintf
#define asprintf moqi_asprintf
#define vdprintf moqi_vdprintf
#define dprintf moqi_dprintf
#define vprintf moqi_vprintf
#define printf moqi_printf
#define puts moqi_puts
#define putchar moqi_putchar
#define print moqi_print
#include "../src/format.c"
#include "../src/stdio.c"
#undef malloc
#undef write
#undef print

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

#define A(x) x
static int row_no;
static void check_row(const char *fmt, int want_n, int want_err, const char *want, size_t want_len, int overflow, int n, int err, const char *got) {
    row_no++;
    if (n != want_n || err != want_err) {
        fprintf(stderr, "row %d (%s): n want %d got %d, errno want %d got %d\n", row_no, fmt, want_n, n, want_err, err);
        bad++;
        return;
    }
    if (overflow) return;
    if (memcmp(got, want, want_len) != 0 || got[want_len] != 0) {
        fprintf(stderr, "row %d (%s): text mismatch: want [%.*s] got [%s]\n", row_no, fmt, (int)want_len, want, got);
        bad++;
        return;
    }
    for (size_t i = want_len + 1; i < 64; i++)
        if (got[i] != 'Z') { fprintf(stderr, "row %d (%s): wrote past the terminator at %zu\n", row_no, fmt, i); bad++; return; }
}
#define ROW_RUN(fmt, n_, e_, s_, len_, ovf_, ...) do { \
    char buf_[64]; memset(buf_, 'Z', sizeof buf_); errno_slot = 0; \
    int rn_ = moqi_snprintf(buf_, sizeof buf_, fmt, ##__VA_ARGS__, 0L, 0L, 0L, 0L, 0L, 0L); \
    check_row(fmt, n_, e_, s_, len_, ovf_, rn_, errno_slot, buf_); } while (0)
#define ROW(fmt, n_, e_, s_, ...) ROW_RUN(fmt, n_, e_, s_, sizeof(s_) - 1, 0, ##__VA_ARGS__)
#define ROW_OVF(fmt, n_, e_, zero_, ...) ROW_RUN(fmt, n_, e_, "", 0, 1, ##__VA_ARGS__)

static void table(void) {
#include "test_printf_rows.inc"
}

/* Floating point: a format, the bits of the double, snprintf's return value and its exact output, measured on glibc. */
static int frow_no;
static void check_frow(const char *fmt, unsigned long long bits, int want_n, const char *want) {
    frow_no++;
    double d;
    memcpy(&d, &bits, 8);
    static char buf[2048];
    errno_slot = 0;
    int n = moqi_snprintf(buf, sizeof buf, fmt, d);
    if (n != want_n || strcmp(buf, want) != 0) {
        fprintf(stderr, "frow %d (%s, bits %016llx): n want %d got %d\n  want [%.200s]\n  got  [%.200s]\n", frow_no, fmt, bits, want_n, n, want, buf);
        bad++;
    }
}
#define FROW(fmt, bits, n_, text) check_frow(fmt, bits, n_, text)

static void ftable(void) {
#include "test_printf_float_rows.inc"
}

static int fmt_into(char *buf, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = moqi_vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return n;
}

int main(void) {
    table();
    ftable();

    /* %n stores the number of characters produced so far, at each size, and counts what truncation dropped. */
    {
        char b[32];
        int ci = -1; long cl = -1; long long cll = -1; short cs = -1; signed char cc = -1;
        int n = moqi_snprintf(b, sizeof b, "abcdef%nxyz%ln%hn%hhn%lln", &ci, &cl, &cs, &cc, &cll);
        CHECK(n == 9 && strcmp(b, "abcdefxyz") == 0 && ci == 6 && cl == 9 && cs == 9 && cc == 9 && cll == 9);
        ci = -1;
        n = moqi_snprintf(b, 4, "abcdef%n", &ci);
        CHECK(n == 6 && ci == 6 && strcmp(b, "abc") == 0);
        ci = -1;
        moqi_snprintf(b, sizeof b, "%5.3d%n", 1, &ci);
        CHECK(ci == 5);
        long zz = -1, jj = -1, tt = -1;
        moqi_snprintf(b, sizeof b, "ab%zn%jn%tn", &zz, &jj, &tt);
        CHECK(zz == 2 && jj == 2 && tt == 2);
        ci = -1;
        moqi_snprintf(b, sizeof b, "%5n|", &ci);
        CHECK(ci == 0 && strcmp(b, "|") == 0);
    }

    /* Floating point arguments: the length modifiers h and l are accepted and change nothing (the argument is a double),
     * '*' widths and precisions combine with them, and a negative '*' precision means no precision. */
    {
        char b[64];
        int n = moqi_snprintf(b, sizeof b, "%lf|%hf", 2.5, 2.5);
        CHECK(n == 17 && strcmp(b, "2.500000|2.500000") == 0);
        n = moqi_snprintf(b, sizeof b, "%5.1f|%-8.3e|%+g", 2.5, 2.5, 2.5);
        CHECK(n == 20 && strcmp(b, "  2.5|2.500e+00|+2.5") == 0);
        n = moqi_snprintf(b, sizeof b, "%.*f|%*.*f|%-*.*e", 3, 2.5, 10, 2, 2.5, 12, 1, 2.5);
        CHECK(n == 29 && strcmp(b, "2.500|      2.50|2.5e+00     ") == 0);
        n = moqi_snprintf(b, sizeof b, "%.*f", -1, 2.5);
        CHECK(n == 8 && strcmp(b, "2.500000") == 0);
        /* Arguments after a float conversion are read from the right place. */
        n = moqi_snprintf(b, sizeof b, "%f %d %s %e %c", 1.25, 7, "ab", 0.5, 'z');
        CHECK(n == (int)strlen("1.250000 7 ab 5.000000e-01 z") && strcmp(b, "1.250000 7 ab 5.000000e-01 z") == 0);
        /* long double is not supported: -1 and EINVAL, and what came before the conversion stays in the buffer. */
        errno_slot = 0;
        n = moqi_snprintf(b, sizeof b, "ab%Lf", (double)1.5);
        CHECK(n == -1 && errno_slot == EINVAL && b[0] == 'a' && b[1] == 'b' && b[2] == 0);
    }

    /* Size handling: NULL with size 0 counts, size 1 only terminates, nothing is written for size 0. */
    {
        CHECK(moqi_snprintf((char *)0, 0, "%d%s", 12345, "abc") == 8);
        char b[4] = {'x', 'x', 'x', 'x'};
        CHECK(moqi_snprintf(b, 0, "abc") == 3 && b[0] == 'x');
        CHECK(moqi_snprintf(b, 1, "abc") == 3 && b[0] == 0 && b[1] == 'x');
        CHECK(moqi_snprintf(b, 2, "abc") == 3 && b[0] == 'a' && b[1] == 0 && b[2] == 'x');
        b[0] = 'x';
        CHECK(moqi_snprintf(b, 0, "abc%") == -1 && b[0] == 'x' && errno_slot == EINVAL);
    }

    /* Wide strings are not run past the precision: a string without a terminator is fine when the precision covers it. */
    {
        const int w[3] = {'a', 'b', 'c'}; /* no terminating zero */
        char b[16];
        CHECK(fmt_into(b, sizeof b, "%.3ls|", w) == 4 && strcmp(b, "abc|") == 0);
        const char s[3] = {'x', 'y', 'z'};
        CHECK(fmt_into(b, sizeof b, "%.3s|", s) == 4 && strcmp(b, "xyz|") == 0);
        CHECK(fmt_into(b, sizeof b, "%-6.2s|", s) == 7 && strcmp(b, "xy    |") == 0);
    }

    /* %m is strerror(errno), with the usual width and precision. */
    {
        char b[64];
        errno_slot = 0;
        CHECK(fmt_into(b, sizeof b, "%m|") == 8 && strcmp(b, "Success|") == 0);
        errno_slot = 2;
        CHECK(fmt_into(b, sizeof b, "%m|%d", 5) == 27 && strcmp(b, "No such file or directory|5") == 0);
        errno_slot = 13;
        CHECK(fmt_into(b, sizeof b, "[%-20m]") == 22 && strcmp(b, "[Permission denied   ]") == 0);
        CHECK(fmt_into(b, sizeof b, "[%.4m]") == 6 && strcmp(b, "[Perm]") == 0);
        errno_slot = 2;
        CHECK(fmt_into(b, sizeof b, "%y") == 2 && errno_slot == 2); /* success never touches errno */
    }

    /* sprintf / vsprintf: unbounded, terminated, count returned. */
    {
        char b[40];
        memset(b, 'Q', sizeof b);
        CHECK(moqi_sprintf(b, "%05d|%-4s|", 42, "ab") == 11 && strcmp(b, "00042|ab  |") == 0 && b[12] == 'Q');
        CHECK(moqi_sprintf(b, "%s", "") == 0 && b[0] == 0);
        errno_slot = 0;
        CHECK(moqi_sprintf(b, "ab%") == -1 && errno_slot == EINVAL && strcmp(b, "ab") == 0);
    }

    /* asprintf / vasprintf */
    {
        char *s = (char *)1;
        CHECK(moqi_asprintf(&s, "%s-%d", "ab", 5) == 4 && strcmp(s, "ab-5") == 0);
        free(s);
        s = (char *)1;
        CHECK(moqi_asprintf(&s, "%d", 12345) == 5 && last_malloc_n == 6 && strcmp(s, "12345") == 0); /* room for the NUL, no more */
        free(s);
        s = (char *)1;
        CHECK(moqi_asprintf(&s, "") == 0 && s && s[0] == 0);
        free(s);
        s = (char *)1;
        CHECK(moqi_asprintf(&s, "%c%c", 'a', 0) == 2 && s && s[0] == 'a' && s[1] == 0);
        free(s);
        char big[3000];
        memset(big, 'z', sizeof big - 1);
        big[sizeof big - 1] = 0;
        s = (char *)1;
        CHECK(moqi_asprintf(&s, "%s%s", big, big) == 5998 && s && strlen(s) == 5998 && s[5997] == 'z');
        free(s);
        s = (char *)1;
        errno_slot = 0;
        CHECK(moqi_asprintf(&s, "abc%") == -1 && s == (char *)0 && errno_slot == EINVAL);
        s = (char *)1;
        errno_slot = 0;
        fail_malloc = 1;
        CHECK(moqi_asprintf(&s, "%d", 5) == -1 && s == (char *)0 && errno_slot == ENOMEM);
        fail_malloc = 0;
    }

    /* dprintf / vdprintf / printf / vprintf: the whole output is written, to the right descriptor, exactly. */
    {
        cap_len = 0;
        CHECK(moqi_dprintf(7, "x=%d %s\n", 7, "yy") == 7 && write_last_fd == 7 && cap_len == 7 && memcmp(cap, "x=7 yy\n", 7) == 0);
        cap_len = 0;
        write_calls = 0;
        CHECK(moqi_printf("%s|%5d|%-4s|\n", "ab", 42, "c") == 15 && write_last_fd == 1 && cap_len == 15 && memcmp(cap, "ab|   42|c   |\n", 15) == 0);
        CHECK(write_calls == 1);
        cap_len = 0;
        CHECK(moqi_printf("%c%c%c", 'a', 0, 'b') == 3 && cap_len == 3 && cap[0] == 'a' && cap[1] == 0 && cap[2] == 'b'); /* NUL bytes survive */
        cap_len = 0;
        char big[1500];
        memset(big, 'k', sizeof big - 1);
        big[sizeof big - 1] = 0;
        CHECK(moqi_printf("<%s>", big) == 1501 && cap_len == 1501 && cap[0] == '<' && cap[1500] == '>' && cap[750] == 'k'); /* no 512-byte cut */
        cap_len = 0;
        CHECK(moqi_dprintf(3, "%s", "") == 0 && cap_len == 0);
        cap_len = 0;
        errno_slot = 0;
        CHECK(moqi_dprintf(3, "bad%") == -1 && errno_slot == EINVAL && cap_len == 0); /* nothing written on a format error */
        errno_slot = 0;
        CHECK(moqi_printf("ab%lc", 233) == -1 && errno_slot == EILSEQ && cap_len == 0);
        /* A partial write is continued; a failure is -1 with errno from the kernel's error. */
        cap_len = 0;
        write_limit = 4;
        write_calls = 0;
        CHECK(moqi_dprintf(3, "0123456789") == 10 && cap_len == 10 && memcmp(cap, "0123456789", 10) == 0 && write_calls == 3);
        write_limit = 0;
        cap_len = 0;
        write_fail_after = 1;
        errno_slot = 0;
        CHECK(moqi_dprintf(3, "abc") == -1 && errno_slot == 9);
        write_fail_after = 2;
        write_limit = 4;
        errno_slot = 0;
        CHECK(moqi_dprintf(3, "0123456789") == -1 && errno_slot == 9);
        write_limit = 0;
        write_fail_after = 0;
        /* An interrupted write is retried; a write that accepts nothing is an I/O error, not an endless loop. */
        cap_len = 0;
        write_eintr = 3;
        CHECK(moqi_dprintf(3, "retry") == 5 && cap_len == 5 && memcmp(cap, "retry", 5) == 0 && write_eintr == 0);
        cap_len = 0;
        write_zero = 1;
        errno_slot = 0;
        CHECK(moqi_dprintf(3, "stuck") == -1 && errno_slot == EIO && cap_len == 0);
        write_eintr = 2;
        errno_slot = 0;
        CHECK(moqi_putchar('q') == 113 && cap_len == 1 && cap[0] == 'q');
    }

    /* puts: the string and a newline in one write; returns the number of bytes written like glibc. putchar returns the byte. */
    {
        cap_len = 0;
        write_calls = 0;
        CHECK(moqi_puts("hi") == 3 && cap_len == 3 && memcmp(cap, "hi\n", 3) == 0 && write_calls == 1);
        cap_len = 0;
        CHECK(moqi_puts("") == 1 && cap_len == 1 && cap[0] == '\n');
        char big[600];
        memset(big, 'p', sizeof big - 1);
        big[sizeof big - 1] = 0;
        cap_len = 0;
        CHECK(moqi_puts(big) == 600 && cap_len == 600 && cap[598] == 'p' && cap[599] == '\n');
        cap_len = 0;
        CHECK(moqi_putchar('A') == 65 && cap_len == 1 && cap[0] == 'A');
        CHECK(moqi_putchar(0x141) == 65 && cap[1] == 'A');
        CHECK(moqi_putchar(-1) == 255 && (unsigned char)cap[2] == 255);
        write_fail_after = 1;
        errno_slot = 0;
        CHECK(moqi_putchar('x') == -1 && errno_slot == 9);
        write_fail_after = 1;
        errno_slot = 0;
        CHECK(moqi_puts("x") == -1 && errno_slot == 9);
    }

    if (bad) { fprintf(stderr, "test_printf_abi: %d failures\n", bad); return 1; }
    fprintf(stdout, "test_printf_abi: %d rows, %d floating-point rows and the failure-injection checks OK\n", row_no, frow_no);
    return 0;
}
