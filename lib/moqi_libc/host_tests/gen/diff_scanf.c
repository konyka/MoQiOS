/* diff_scanf.c — differential fuzzer: the same random format and input go through glibc's sscanf and through __moqi_vscan,
 * and the return value, errno, bytes consumed, end-of-input flag and every byte written must agree.
 *
 *   zig cc -O1 -g -w -fno-builtin -Dstrtod=m_strtod -Dstrtof=m_strtof -D__moqi_vscan=m_vscan \
 *       -D__errno_location=m_errno_location -c ../src/scan.c -o scan_m.o
 *   (same -D flags for ../src/strtod.c) then   gcc -O1 -o diff gen/diff_scanf.c scan_m.o strtod_m.o && ./diff N SEED
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../src/scan.h"

int *m_errno_location(void) { return &errno; }
int m_vscan(const struct moqi_scan_src *src, const char *fmt, va_list ap);

struct strsrc { const unsigned char *p; size_t len, i; int hit_end; };
static int s_get(void *ctx) {
    struct strsrc *s = ctx;
    if (s->i >= s->len) { s->hit_end = 1; return -1; }
    return s->p[s->i++];
}
static void s_unget(void *ctx, int c) { (void)c; ((struct strsrc *)ctx)->i--; }
static void *t_alloc(void *old, size_t n) { return realloc(old, n); }
static void t_free(void *p) { free(p); }

static int mine(const char *in, const char *fmt, struct strsrc *s, void *a, void *b, void *c, void *d) {
    memset(s, 0, sizeof *s);
    s->p = (const unsigned char *)in;
    s->len = strlen(in);
    struct moqi_scan_src src = { s_get, s_unget, t_alloc, t_free, s };
    va_list ap;
    int r;
    {
        void *args[4] = { a, b, c, d };
        /* build a va_list by calling through a variadic trampoline */
        extern int tramp(const struct moqi_scan_src *, const char *, ...);
        r = tramp(&src, fmt, args[0], args[1], args[2], args[3]);
    }
    (void)ap;
    return r;
}
int tramp(const struct moqi_scan_src *src, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = m_vscan(src, fmt, ap);
    va_end(ap);
    return r;
}

static uint64_t rng;
static uint64_t next(void) {
    uint64_t z = (rng += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}
static unsigned rnd(unsigned n) { return (unsigned)(next() % n); }
static const char *pick(const char *const *a, unsigned n) { return a[rnd(n)]; }
#define N(a) (sizeof a / sizeof a[0])

int main(int argc, char **argv) {
    long iters = argc > 1 ? atol(argv[1]) : 1000000;
    rng = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
    static const char *mods[] = {"", "", "", "h", "hh", "l", "ll", "L", "j", "z", "t", "q"};
    static const char *flags[] = {"", "", "", "", "*", "'", "I"};
    static const char *widths[] = {"", "", "", "1", "2", "3", "4", "5", "6", "9", "12"};
    static const char *convs[] = {"d", "i", "u", "o", "x", "X", "b", "p", "f", "e", "g", "a", "E", "G", "F", "A", "s", "c", "n", "%", "[a-c]", "[^ab]",
                                  "[0-9a-f]", "[^\n]", "[]x]", "[^]x]", "[a-]", "[-b]", "[b-a]", "[", "y", "S", "C", "ls", "lc", "l[a-c]", "w8d", "w16d",
                                  "w32d", "w64d", "wf8d", "wf16d", "wf32d", "wf64d", "m", "ms", "mc"};
    static const char *lit[] = {" ", "  ", "\n", "a", "b", ",", ":", "-", "x", "%%", "\t", "\xe9", "0", "1"};
    static const char *alpha[] = {"0123456789", "0123456789abcdefABCDEFxXpP.+- ", "abc xyz\n\t", "01 b-+", "eE+-.0123456789", "nNaAiIfFtTyY()_ 0x1p-",
                                  "0123456789,.:;- \n\ta]x", "\x01\x7f\x80\xe9\xff 0a"};
    unsigned char slots[4][512];
    unsigned char slots2[4][512];
    long bad = 0;
    for (long it = 0; it < iters; it++) {
        char fmt[96];
        char *p = fmt;
        unsigned nunits = 1 + rnd(4);
        for (unsigned u = 0; u < nunits; u++) {
            if (rnd(4) == 0) { p += sprintf(p, "%s", pick(lit, N(lit))); continue; }
            const char *cv = pick(convs, N(convs));
            if (cv[0] == 'm' ) cv = "d";   /* the allocating forms are covered by the table test; here every result must live in a slot */
            const char *w = pick(widths, N(widths));
            const char *md = pick(mods, N(mods));
            /* %Lf, %llf and %qf store an 80-bit x87 value; this libc has no strtold, so they are not compared */
            if (strchr("fFeEgGaA", cv[0]) && cv[1] == 0 && (!strcmp(md, "L") || !strcmp(md, "ll") || !strcmp(md, "q"))) md = "l";
            p += sprintf(p, "%%%s%s%s%s", pick(flags, N(flags)), w, md, cv);
        }
        *p = 0;
        char in[48];
        unsigned n = rnd(26);
        const char *al = pick(alpha, N(alpha));
        size_t al_n = strlen(al);
        for (unsigned i = 0; i < n; i++) in[i] = al[rnd((unsigned)al_n)];
        in[n] = 0;
        if (strchr(fmt, '%') && strstr(fmt, "%[") == 0 && 0) continue;
        memset(slots, 0xAA, sizeof slots);
        memset(slots2, 0xAA, sizeof slots2);
        errno = 0;
        FILE *f = fmemopen(in, n ? n : 1, "r");
        if (n == 0) { fclose(f); f = fmemopen((void *)"", 0, "r"); }
        int r1 = f ? fscanf(f, fmt, slots[0], slots[1], slots[2], slots[3]) : -9;
        int e1 = errno;
        long used1 = f ? ftell(f) : 0;
        int eof1 = f ? feof(f) != 0 : 0;
        if (f) fclose(f);
        struct strsrc s;
        errno = 0;
        int r2 = mine(in, fmt, &s, slots2[0], slots2[1], slots2[2], slots2[3]);
        int e2 = errno;
        if (r1 != r2 || e1 != e2 || used1 != (long)s.i || eof1 != s.hit_end || memcmp(slots, slots2, sizeof slots) != 0) {
            if (++bad <= 20) {
                printf("DIFF fmt=[");
                for (char *q = fmt; *q; q++) printf(*q >= 32 && *q < 127 ? "%c" : "\\x%02x", (unsigned char)*q);
                printf("] in=[");
                for (unsigned i = 0; i < n; i++) printf(in[i] >= 32 && in[i] < 127 ? "%c" : "\\x%02x", (unsigned char)in[i]);
                printf("] glibc: ret=%d errno=%d used=%ld eof=%d | mine: ret=%d errno=%d used=%zu eof=%d%s\n", r1, e1, used1, eof1, r2, e2, s.i,
                       s.hit_end, memcmp(slots, slots2, sizeof slots) ? " BYTES" : "");
            }
        }
    }
    printf("%ld iterations, %ld differences\n", iters, bad);
    return bad != 0;
}
