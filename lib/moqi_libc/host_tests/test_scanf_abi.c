/* test_scanf_abi.c — the scanf engine (sscanf, vsscanf and the shared conversion code behind fscanf) checked against glibc.
 *
 * test_scanf_rows.inc holds about 8000 rows measured on the host's glibc (gen/gen_scanf_rows.c): a format, the input text,
 * then the return value, errno (which starts at 0), the number of bytes consumed, whether the end of input was seen, and
 * the bytes written into four 64-byte slots that start filled with 0xAA. The rest are checks a table cannot hold: the
 * allocating "m" modifier, wide characters, allocation failure, a failing source, positional arguments past the table's
 * four slots, and a NULL destination.
 */
#include <assert.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/scan.h"

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }
#define EIO 5
#define EILSEQ 84

/* ---- a string source that records whether it was ever asked past the end ------------------------------------------- */

struct strsrc {
    const unsigned char *p;
    size_t len, i;
    int hit_end;
    long fail_at;     /* >= 0: reading at this offset fails with EIO */
    int fail_err;
};
static int s_get(void *ctx) {
    struct strsrc *s = (struct strsrc *)ctx;
    if (s->fail_at >= 0 && (long)s->i >= s->fail_at) {
        s->hit_end = 1;
        errno_slot = s->fail_err;
        return -1;
    }
    if (s->i >= s->len) {
        s->hit_end = 1;
        return -1;
    }
    return s->p[s->i++];
}
static void s_unget(void *ctx, int c) {
    struct strsrc *s = (struct strsrc *)ctx;
    (void)c;
    assert(s->i > 0);
    s->i--;
}

static int alloc_fail_after;   /* > 0: the Nth allocation from now fails */
static long live_allocs;
static size_t last_alloc_n;
static char alloc_log[256];
static size_t alloc_log_len;
/* Every reallocation moves the block and scribbles over the old one, so a pointer that was not updated after a growth is
 * caught the moment it is used. */
#define GUARD 16
static size_t blk_size(void *p) { return *(size_t *)((char *)p - 16); }
static void blk_check(void *p, const char *what) {
    size_t n = blk_size(p);
    for (int i = 0; i < GUARD; i++)
        if (((unsigned char *)p)[n + (size_t)i] != 0xCD) {
            fprintf(stderr, "heap overflow detected by the guard bytes (%s, block of %zu)\n", what, n);
            abort();
        }
}
static void *t_alloc(void *old, size_t n) {
    last_alloc_n = n;
    if (alloc_log_len < sizeof alloc_log - 16) alloc_log_len += (size_t)sprintf(alloc_log + alloc_log_len, "%c%zu ", old ? 'r' : 'm', n);
    if (alloc_fail_after > 0 && --alloc_fail_after == 0) return (void *)0;
    char *raw = (char *)malloc(16 + n + GUARD);
    if (!raw) return (void *)0;
    *(size_t *)raw = n;
    char *p = raw + 16;
    memset(p, 0xEE, n);
    memset(p + n, 0xCD, GUARD);
    if (old) {
        size_t have = blk_size(old);
        blk_check(old, "realloc");
        memcpy(p, old, have < n ? have : n);
        memset(old, 0xDD, have);
        free((char *)old - 16);
    } else {
        live_allocs++;
    }
    return p;
}
static void t_free(void *p) {
    if (!p) return;
    blk_check(p, "free");
    live_allocs--;
    free((char *)p - 16);
}

static struct strsrc cur;
static struct moqi_scan_src mk(const char *in, size_t len) {
    memset(&cur, 0, sizeof cur);
    cur.p = (const unsigned char *)in;
    cur.len = len;
    cur.fail_at = -1;
    struct moqi_scan_src src = { s_get, s_unget, t_alloc, t_free, &cur };
    return src;
}

static int scan(const char *in, size_t len, const char *fmt, ...) {
    struct moqi_scan_src src = mk(in, len);
    va_list ap;
    va_start(ap, fmt);
    int r = __moqi_vscan(&src, fmt, ap);
    va_end(ap);
    return r;
}

static int scan_with(const struct moqi_scan_src *src, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = __moqi_vscan(src, fmt, ap);
    va_end(ap);
    return r;
}

#define A10(b) &res[b], &res[b + 1], &res[b + 2], &res[b + 3], &res[b + 4], &res[b + 5], &res[b + 6], &res[b + 7], &res[b + 8], &res[b + 9]
/* The engine called with 70 destination pointers, the first `count` of which are used by the format. */
static int scan_with_args(const char *in, const char *fmt, char **res, int count) {
    (void)count;
    struct moqi_scan_src src = mk(in, strlen(in));
    return scan_with(&src, fmt, A10(0), A10(10), A10(20), A10(30), A10(40), A10(50), A10(60));
}

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int row_no;
static void hex(char *out, const unsigned char *b, int n) {
    for (int i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", b[i]);
    out[2 * n] = 0;
}

static void check_row(const char *fmt, const char *in, int ret, int err, long used, int eof, const char *s0, const char *s1, const char *s2,
                      const char *s3) {
    row_no++;
    _Alignas(8) unsigned char sl[4][64];
    memset(sl, 0xAA, sizeof sl);
    errno_slot = 0;
    int r = scan(in, strlen(in), fmt, sl[0], sl[1], sl[2], sl[3]);
    long u = (long)cur.i;
    int got_err = errno_slot, got_eof = cur.hit_end;
    const char *want[4] = { s0, s1, s2, s3 };
    char got[4][140];
    int ok = r == ret && got_err == err && u == used && got_eof == eof;
    for (int i = 0; i < 4; i++) {
        int last = -1;
        for (int j = 0; j < 64; j++)
            if (sl[i][j] != 0xAA) last = j;
        hex(got[i], sl[i], last + 1);
        if (strcmp(got[i], want[i]) != 0) ok = 0;
    }
    if (!ok) {
        fprintf(stderr, "row %d sscanf(\"%s\", \"%s\"): ret %d/%d errno %d/%d used %ld/%ld eof %d/%d (got/want)", row_no, in, fmt, r, ret,
                got_err, err, u, used, got_eof, eof);
        for (int i = 0; i < 4; i++)
            if (strcmp(got[i], want[i]) != 0) fprintf(stderr, " slot%d %s/%s", i, got[i], want[i]);
        fprintf(stderr, "\n");
        bad++;
    }
}
#define ROW(f, in, r, e, u, eof, a, b, c, d) check_row(f, in, r, e, u, eof, a, b, c, d)

int main(void) {
#include "test_scanf_rows.inc"

    /* ---- the allocating modifier ---- */
    {
        char *a = (char *)0, *b = (char *)0;
        live_allocs = 0;
        errno_slot = 0;
        CHECK(scan("hello world", 11, "%ms %ms", &a, &b) == 2 && a && b && strcmp(a, "hello") == 0 && strcmp(b, "world") == 0);
        t_free(a);
        t_free(b);
        CHECK(live_allocs == 0);
        a = (char *)0;
        CHECK(scan("abcdef", 6, "%3mc", &a) == 1 && a && memcmp(a, "abc", 3) == 0);
        t_free(a);
        a = (char *)0;
        CHECK(scan("abc", 3, "%5mc", &a) == -1 && a == (char *)0); /* a short field frees what it had allocated */
        CHECK(live_allocs == 0);
        CHECK(scan("aab", 3, "%m[a]", &a) == 1 && a && strcmp(a, "aa") == 0);
        t_free(a);
        a = (char *)0;
        CHECK(scan("   ", 3, "%ms", &a) == -1 && a == (char *)0);
        a = (char *)0;
        CHECK(scan("", 0, "%ms", &a) == -1 && a == (char *)0);
        CHECK(scan("x", 1, "%md", &a) == 0); /* "m" with a number conversion is an ordinary (ignored) modifier: nothing matches */
        a = b = (char *)0;
        int n = 0;
        CHECK(scan("abc def", 7, "%ms %d", &a, &n) == 1 && a && strcmp(a, "abc") == 0); /* a later failure keeps the earlier string */
        t_free(a);
        a = (char *)0;
        CHECK(scan("abc", 3, "%*ms", &a) == 0 && a == (char *)0); /* suppressed: nothing allocated, nothing assigned */
        CHECK(live_allocs == 0);
        /* a conversion that matches nothing releases its buffer */
        CHECK(scan("b", 1, "%m[a]", &a) == 0 && a == (char *)0 && live_allocs == 0);
        /* the whole result is exact-sized and grows past the first buffer */
        {
            char big[3000];
            memset(big, 'z', sizeof big - 1);
            big[sizeof big - 1] = 0;
            CHECK(scan(big, sizeof big - 1, "%ms", &a) == 1 && a && strlen(a) == sizeof big - 1);
            t_free(a);
            a = (char *)0;
        }
        /* allocation failures, as glibc behaves: no memory for the first buffer ends the call with EOF; a failed growth is retried
         * with one more element and the call carries on; a failed final shrink is ignored; a later conversion that cannot get
         * its buffer releases the earlier results too */
        live_allocs = 0;
        alloc_fail_after = 1;
        CHECK(scan("abc", 3, "%ms", &a) == -1 && a == (char *)0 && live_allocs == 0);
        {
            char big[3000];
            memset(big, 'z', sizeof big - 1);
            big[sizeof big - 1] = 0;
            alloc_fail_after = 2;
            a = (char *)0;
            CHECK(scan(big, sizeof big - 1, "%ms", &a) == 1 && a && strlen(a) == sizeof big - 1);
            t_free(a);
            a = (char *)0;
        }
        alloc_fail_after = 0;
        a = b = (char *)0;
        alloc_fail_after = 2; /* the shrink of the first result */
        CHECK(scan("one two", 7, "%ms %ms", &a, &b) == 2 && a && b && strcmp(a, "one") == 0 && strcmp(b, "two") == 0);
        t_free(a);
        t_free(b);
        a = b = (char *)0;
        alloc_fail_after = 3; /* the buffer of the second */
        CHECK(scan("one two", 7, "%ms %ms", &a, &b) == -1 && a == (char *)0 && b == (char *)0 && live_allocs == 0);
        alloc_fail_after = 0;
    }

    /* ---- wide characters (the C locale: ASCII only; anything else is EILSEQ) ---- */
    {
        wchar_t w[8];
        memset(w, 0xAA, sizeof w);
        errno_slot = 0;
        CHECK(scan("ab", 2, "%lc", w) == 1 && w[0] == L'a' && w[1] == (wchar_t)0xAAAAAAAA);
        memset(w, 0xAA, sizeof w);
        CHECK(scan("ab cd", 5, "%ls", w) == 1 && w[0] == L'a' && w[1] == L'b' && w[2] == 0 && w[3] == (wchar_t)0xAAAAAAAA);
        memset(w, 0xAA, sizeof w);
        CHECK(scan("abca", 4, "%l[abc]", w) == 1 && w[0] == L'a' && w[3] == L'a' && w[4] == 0);
        memset(w, 0xAA, sizeof w);
        errno_slot = 0;
        CHECK(scan("\xe9z", 2, "%lc", w) == 0 && errno_slot == EILSEQ && w[0] == (wchar_t)0xAAAAAAAA);
        wchar_t *m = (wchar_t *)0;
        live_allocs = 0;
        CHECK(scan("ab cd", 5, "%mls", &m) == 1 && m && m[0] == L'a' && m[1] == L'b' && m[2] == 0);
        t_free(m);
        m = (wchar_t *)0;
        CHECK(scan("abc", 3, "%mlc", &m) == 1 && m && m[0] == L'a');
        t_free(m);
        CHECK(live_allocs == 0);
    }



    /* ---- floating-point text longer than the on-stack buffer goes to the allocator, and is released again ---- */
    {
        static char longnum[400];
        memset(longnum, '0', sizeof longnum - 1);
        longnum[0] = '1';
        longnum[sizeof longnum - 1] = 0;
        double d = 0;
        live_allocs = 0;
        alloc_log_len = 0;
        alloc_log[0] = 0;
        CHECK(scan(longnum, sizeof longnum - 1, "%lf", &d) == 1 && cur.i == sizeof longnum - 1);
        CHECK(live_allocs == 0 && alloc_log[0] == 'm'); /* 1 followed by 398 zeros is infinity as a double (ERANGE), and it was converted */
        /* no memory for the longer buffer: -1, ENOMEM, nothing stored, nothing leaked */
        d = 5;
        live_allocs = 0;
        alloc_fail_after = 1;
        errno_slot = 0;
        CHECK(scan(longnum, sizeof longnum - 1, "%lf", &d) == -1 && errno_slot == 12 && d == 5 && live_allocs == 0);
        alloc_fail_after = 0;
        /* a long but valid number: the digits are all used */
        static char digits[300];
        memset(digits, '0', sizeof digits - 1);
        digits[sizeof digits - 1] = 0;
        digits[100] = '1';
        digits[101] = '.';
        digits[102] = '5';
        d = 0;
        CHECK(scan(digits, sizeof digits - 1, "%lf", &d) == 1 && d == 1.5 && cur.i == sizeof digits - 1);
        CHECK(live_allocs == 0);
    }

    /* ---- the long double forms are not supported: the number is read, nothing is stored, EINVAL ---- */
    {
        unsigned char sl[32];
        static const char *const ld[] = { "%Lf", "%llf", "%qf", "%Le", "%llg", "%La" };
        for (unsigned i = 0; i < sizeof ld / sizeof ld[0]; i++) {
            memset(sl, 0xAA, sizeof sl);
            errno_slot = 0;
            int r = scan("1.5 x", 5, ld[i], sl);
            int untouched = 1;
            for (unsigned j = 0; j < sizeof sl; j++) untouched &= sl[j] == 0xAA;
            if (r != 0 || errno_slot != 22 || !untouched || cur.i != 3) {
                fprintf(stderr, "long double %s: ret %d errno %d untouched %d consumed %zu\n", ld[i], r, errno_slot, untouched, cur.i);
                bad++;
            }
        }
    }

    /* ---- NUL bytes in the input are ordinary characters for the string conversions and end a number ---- */
    {
        unsigned char sl[8];
        wchar_t w[8];
        memset(sl, 0xAA, sizeof sl);
        CHECK(scan("a\0b", 3, "%s", sl) == 1 && memcmp(sl, "a\0b\0", 4) == 0 && cur.i == 3);
        memset(sl, 0xAA, sizeof sl);
        CHECK(scan("a\0b", 3, "%[^b]", sl) == 1 && memcmp(sl, "a\0\0", 3) == 0 && cur.i == 2);
        memset(sl, 0xAA, sizeof sl);
        CHECK(scan("a\0b", 3, "%3c", sl) == 1 && memcmp(sl, "a\0b", 3) == 0 && cur.i == 3);
        int n = 7;
        CHECK(scan("a\0b", 3, "a%d", &n) == 0 && n == 7 && cur.i == 1);
        memset(w, 0xAA, sizeof w);
        errno_slot = 0;
        CHECK(scan("a\0b", 3, "%3lc", w) == 0 && errno_slot == EILSEQ && w[0] == L'a' && w[1] == 0 && w[2] == (wchar_t)0xAAAAAAAA && cur.i == 2);
        memset(w, 0xAA, sizeof w);
        errno_slot = 0;
        CHECK(scan("a\0b", 3, "%ls", w) == 0 && errno_slot == EILSEQ && w[0] == L'a' && w[1] == 0 && w[2] == (wchar_t)0xAAAAAAAA && cur.i == 2);
        memset(w, 0xAA, sizeof w);
        CHECK(scan("a\0b", 3, "%l[a-z\001]", w) == 1 && w[0] == L'a' && w[1] == 0 && w[2] == (wchar_t)0xAAAAAAAA && cur.i == 1);
        int x = 0, y = 0;
        char ch[4];
        CHECK(scan("12\0" "3\0", 4, "%d%c%d", &x, ch, &y) == 3 && x == 12 && ch[0] == 0 && y == 3);
    }

    /* ---- the engine refuses a NULL format by itself ---- */
    errno_slot = 0;
    CHECK(scan("1", 1, (const char *)0) == -1 && errno_slot == 22);

    /* ---- allocation, step by step: the buffer sizes glibc asks for, the exact-size result, and no stale pointer ---- */
    {
        static char src[400];
        char *a = (char *)0;
        wchar_t *wa = (wchar_t *)0;
        memset(src, 'q', sizeof src);
        static const struct { int len; const char *want; } ms[] = {
            {3, "m100 r4 "}, {1, "m100 r2 "}, {99, "m100 "}, {100, "m100 r200 r101 "}, {150, "m100 r200 r151 "}, {199, "m100 r200 "},
            {200, "m100 r200 r400 r201 "}, {250, "m100 r200 r400 r251 "},
        };
        for (unsigned i = 0; i < sizeof ms / sizeof ms[0]; i++) {
            alloc_log_len = 0;
            alloc_log[0] = 0;
            live_allocs = 0;
            int r = scan(src, (size_t)ms[i].len, "%ms", &a);
            if (r != 1 || !a || strlen(a) != (size_t)ms[i].len || strcmp(alloc_log, ms[i].want) != 0) {
                fprintf(stderr, "%%ms of %d chars: ret %d allocs [%s] want [%s]\n", ms[i].len, r, alloc_log, ms[i].want);
                bad++;
            }
            t_free(a);
            a = (char *)0;
        }
        struct { const char *in, *fmt, *want; int wide; } sq[] = {
            {"abcdefgh", "%5mc", "m5 ", 0},       {"abcdefgh", "%mc", "m1 ", 0},      {"aab", "%m[a]", "m100 r3 ", 0},
            {"b", "%m[a]", "m100 ", 0},           {"ab cd", "%mls", "m400 r12 ", 1},  {"abcde", "%3mlc", "m12 ", 1},
            {"abc", "%ml[abc]", "m400 r16 ", 1},
        };
        for (unsigned i = 0; i < sizeof sq / sizeof sq[0]; i++) {
            alloc_log_len = 0;
            alloc_log[0] = 0;
            live_allocs = 0;
            int r = sq[i].wide ? scan(sq[i].in, strlen(sq[i].in), sq[i].fmt, &wa) : scan(sq[i].in, strlen(sq[i].in), sq[i].fmt, &a);
            if (strcmp(alloc_log, sq[i].want) != 0) {
                fprintf(stderr, "%s on %s: ret %d allocs [%s] want [%s]\n", sq[i].fmt, sq[i].in, r, alloc_log, sq[i].want);
                bad++;
            }
            t_free(a);
            t_free(wa);
            a = (char *)0;
            wa = (wchar_t *)0;
        }
        {
            static char longsrc[1400];
            memset(longsrc, 'z', sizeof longsrc);
            alloc_log_len = 0;
            alloc_log[0] = 0;
            static const struct { const char *fmt; const char *want; size_t n; } mc[] = {
                {"%1025mc", "m1024 r1025 ", 1025},           {"%1200mc", "m1024 r1200 ", 1200},           {"%2048mc", "m1024 r2048 ", 2048},
                {"%2049mc", "m1024 r2048 r2049 ", 2049},     {"%2500mc", "m1024 r2048 r2500 ", 2500},     {"%4096mc", "m1024 r2048 r4096 ", 4096},
                {"%4097mc", "m1024 r2048 r4096 r4097 ", 4097}, {"%5000mc", "m1024 r2048 r4096 r5000 ", 5000},
            };
            static char big5[6000];
            memset(big5, 'z', sizeof big5);
            for (unsigned i = 0; i < sizeof mc / sizeof mc[0]; i++) {
                alloc_log_len = 0;
                alloc_log[0] = 0;
                int r = scan(big5, sizeof big5, mc[i].fmt, &a);
                if (r != 1 || !a || strcmp(alloc_log, mc[i].want) != 0 || memcmp(a, big5, mc[i].n) != 0 || cur.i != mc[i].n) {
                    fprintf(stderr, "%s: ret %d allocs [%s] want [%s] consumed %zu\n", mc[i].fmt, r, alloc_log, mc[i].want, cur.i);
                    bad++;
                }
                t_free(a);
                a = (char *)0;
            }
            wchar_t *wm = (wchar_t *)0;
            static const struct { const char *fmt; const char *want; } wmc[] = {
                {"%1025mlc", "m4096 r4100 "}, {"%2048mlc", "m4096 r8192 "}, {"%2049mlc", "m4096 r8192 r8196 "}, {"%5000mlc", "m4096 r8192 r16384 r20000 "},
                {"%1100mC", "m4096 r4400 "},
            };
            for (unsigned i = 0; i < sizeof wmc / sizeof wmc[0]; i++) {
                alloc_log_len = 0;
                alloc_log[0] = 0;
                int r = scan(big5, sizeof big5, wmc[i].fmt, &wm);
                if (r != 1 || !wm || strcmp(alloc_log, wmc[i].want) != 0) {
                    fprintf(stderr, "%s: ret %d allocs [%s] want [%s]\n", wmc[i].fmt, r, alloc_log, wmc[i].want);
                    bad++;
                }
                t_free(wm);
                wm = (wchar_t *)0;
            }
            alloc_log_len = 0;
            alloc_log[0] = 0;
            CHECK(scan(longsrc, 250, "%2000mc", &a) == -1 && a == (char *)0 && strcmp(alloc_log, "m1024 ") == 0);
        }
        /* a result that grew once and filled its buffer exactly (199 characters and the terminator) is not shrunk, so only the
         * growth could have updated the caller's pointer; when the next conversion cannot get memory, that pointer is freed */
        {
            char *b = (char *)0;
            alloc_log_len = 0;
            live_allocs = 0;
            memset(src, 'q', 199);
            src[199] = ' ';
            memcpy(src + 200, "next", 4);
            alloc_fail_after = 3; /* m100, r200 for the first string; the third allocation (the second string's buffer) fails */
            CHECK(scan(src, 204, "%ms %ms", &a, &b) == -1 && a == (char *)0 && b == (char *)0 && live_allocs == 0);
            alloc_fail_after = 0;
        }
    }

    /* ---- the last-resort growth (the doubled size cannot be had) asks for exactly one more element ---- */
    {
        static char src[400];
        char *a = (char *)0;
        memset(src, 'q', 150);
        alloc_log_len = 0;
        alloc_log[0] = 0;
        live_allocs = 0;
        alloc_fail_after = 2;
        CHECK(scan(src, 150, "%ms", &a) == 1 && a && strlen(a) == 150 && strcmp(alloc_log, "m100 r200 r101 r202 r151 ") == 0);
        t_free(a);
        alloc_fail_after = 0;
        CHECK(live_allocs == 0);
    }

    /* ---- more %m results than one bookkeeping block holds (32): all are released together when a later one fails ---- */
    {
        enum { COUNT = 70 };
        static char fmt[COUNT * 4 + 1];
        static char in[COUNT * 3 + 1];
        static char *res[COUNT];
        for (int i = 0; i < COUNT; i++) {
            memcpy(fmt + i * 4, "%ms ", 4);
            memcpy(in + i * 3, "ab ", 3);
        }
        fmt[COUNT * 4] = 0;
        in[COUNT * 3] = 0;
        memset(res, 0, sizeof res);
        live_allocs = 0;
        int r = scan_with_args(in, fmt, res, COUNT);
        CHECK(r == COUNT && live_allocs == COUNT);
        for (int i = 0; i < COUNT; i++) {
            CHECK(res[i] && strcmp(res[i], "ab") == 0);
            t_free(res[i]);
        }
        CHECK(live_allocs == 0);
        /* the 67th buffer cannot be had: everything allocated so far, in every block, is freed and the pointers are NULL */
        memset(res, 0, sizeof res);
        alloc_fail_after = 2 * 66 + 1; /* two allocations (buffer, shrink) per completed string, then the failing buffer */
        live_allocs = 0;
        r = scan_with_args(in, fmt, res, COUNT);
        int all_null = 1;
        for (int i = 0; i < COUNT; i++) all_null &= res[i] == (char *)0;
        CHECK(r == -1 && all_null && live_allocs == 0);
        alloc_fail_after = 0;
    }

    /* ---- the source fails part-way: what was read is converted, the failure is passed on ---- */
    {
        static const struct { const char *in, *fmt; long fail_at; int ret, err, a, b; } fr[] = {
            {"12345", "%d", 2, 1, EIO, 12, -1},   {"12 34", "%d %d", 2, 1, EIO, 12, -1}, {"12 34", "%d %d", 3, 1, EIO, 12, -1},
            {"12", "%d%d", 2, 1, EIO, 12, -1},    {"12", "%d", 0, -1, EIO, -1, -1},      {"12 ", "%d", 3, 1, 0, 12, -1},
            {"", "%d", 0, -1, EIO, -1, -1},       {"a", "a%d", 1, -1, EIO, -1, -1},
        };
        for (unsigned i = 0; i < sizeof fr / sizeof fr[0]; i++) {
            int a = -1, b = -1;
            struct moqi_scan_src src = mk(fr[i].in, strlen(fr[i].in));
            cur.fail_at = fr[i].fail_at;
            cur.fail_err = EIO;
            errno_slot = 0;
            int r = scan_with(&src, fr[i].fmt, &a, &b);
            if (r != fr[i].ret || errno_slot != fr[i].err || a != fr[i].a || b != fr[i].b) {
                fprintf(stderr, "failing source %u (%s / %s @%ld): ret %d/%d errno %d/%d a %d/%d b %d/%d\n", i, fr[i].in, fr[i].fmt, fr[i].fail_at, r,
                        fr[i].ret, errno_slot, fr[i].err, a, fr[i].a, b, fr[i].b);
                bad++;
            }
        }
    }

    /* ---- a NULL destination for the pointer-taking conversions is skipped without a crash (glibc: the conversion fails) ---- */
    {
        char c = 'x';
        errno_slot = 0;
        CHECK(scan("abc", 3, "%s", (char *)0) == 0);
        CHECK(scan("abc", 3, "%c", (char *)0) == 0);
        CHECK(scan("abc", 3, "%ms", (char **)0) == 0);
        (void)c;
    }

    /* ---- positional arguments: the table's four slots are not a limit; a later number can be named first ---- */
    {
        int v[6] = { 0, 0, 0, 0, 0, 0 };
        CHECK(scan("1 2 3 4 5 6", 11, "%6$d %5$d %4$d %3$d %2$d %1$d", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) == 6);
        CHECK(v[5] == 1 && v[4] == 2 && v[3] == 3 && v[2] == 4 && v[1] == 5 && v[0] == 6);
    }

    if (bad) {
        fprintf(stderr, "test_scanf_abi: %d failures\n", bad);
        return 1;
    }
    printf("test_scanf_abi OK (%d table rows)\n", row_no);
    return 0;
}
