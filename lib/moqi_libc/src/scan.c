/* scan.c — the scanf engine, __moqi_vscan (see scan.h and include/stdio.h).
 *
 * One engine serves sscanf, fscanf and scanf: it pulls bytes from a source with one level of pushback, so the three only
 * differ in the source they pass. It allocates only for the POSIX "m" modifier, through the source's allocator, and it
 * has no other dependencies: the number parsing is its own, and floating-point text is handed to strtod/strtof.
 *
 * The behavior follows glibc 2.43 in the C locale as measured (host_tests/test_scanf_abi.c checks about 8000 rows
 * generated from it). The details that matter to a caller:
 *   - the return value is the number of stored conversions, or -1 when the input ended (or failed) before the first
 *     conversion finished; a malformed format or a mismatch returns the count so far;
 *   - one byte of lookahead is read past every field and pushed back, except at the end of the input, where nothing is
 *     pushed back and the source keeps its end-of-file state;
 *   - white space in the format skips any amount of white space in the input, and so does every conversion except
 *     %c %[ %n; a literal must match exactly;
 *   - integer conversions take the longest run of digits in the field width and report overflow as ERANGE with the clamped
 *     value, like strtol/strtoul; "0x" and (for %i and %b) "0b" prefixes are recognised;
 *   - %f %e %g %a read the longest valid prefix of a floating-point number (decimal, hexadecimal, inf, infinity, nan,
 *     nan(...)) and convert it with strtod/strtof; the long double form (%Lf) is not supported and fails with EINVAL;
 *   - strings and characters: %s stops at white space, %[...] at the first byte outside (or inside, with ^) the set, %c
 *     reads exactly the width; the wide forms (%lc %ls %l[ %C %S) accept ASCII only, anything else is EILSEQ;
 *   - %m allocates the result; it is freed again when the call fails before the end of that conversion, or runs out of
 *     memory (ENOMEM is not reported, the call returns -1 like glibc);
 *   - %N$ positional arguments, the ' and I flags (no effect in the C locale), and the w8/w16/w32/w64/wf* width modifiers
 *     are accepted.
 */
#include "../include/errno.h"
#include "../include/stdio.h"
#include "../include/stdlib.h"
#include "scan.h"

#define SC_LONG      0x0001   /* l: long, double, wide characters */
#define SC_LONGDBL   0x0002   /* L, ll, q: long long, long double */
#define SC_SHORT     0x0004   /* h */
#define SC_SUPPRESS  0x0008   /* * */
#define SC_SIGNED    0x0040   /* d i */
#define SC_CHAR      0x0200   /* hh */
#define SC_HEXFLOAT  0x0800
#define SC_READPTR   0x1000   /* %p */
#define SC_MALLOC    0x2000   /* m */

#define INT_MAX_ 2147483647

enum { R_OK = 0, R_CONV = 1, R_INPUT = 2, R_NOMEM = 3 };

struct sc {
    const struct moqi_scan_src *src;
    int c;              /* the byte most recently read, -1 once the end of the input has been seen */
    int inchar_errno;   /* errno at the moment the end was seen, handed back by every later read */
    size_t nread;       /* bytes consumed so far (what %n stores) */
};

/* Reads the next byte; once the end has been seen it is not asked again and errno is restored to what it was then. */
static int inchar(struct sc *st) {
    if (st->c == -1) {
        errno = st->inchar_errno;
        return -1;
    }
    int c = st->src->get(st->src->ctx);
    st->c = c;
    if (c != -1) st->nread++;
    else st->inchar_errno = errno;
    return c;
}

static void unget_any(struct sc *st, int c) {
    if (c == -1) return;
    st->nread--;
    st->src->unget(st->src->ctx, c);
}

static int is_space(int c) { return c == ' ' || (c >= 9 && c <= 13); }
static int is_digit(int c) { return c >= '0' && c <= '9'; }
static int is_xdigit(int c) { return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; }
static int is_nchar(int c) { return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }

/* Digits of a field width or argument number; -1 when the value does not fit an int. */
static int read_int(const unsigned char **pf) {
    int v = **pf - '0';
    while (is_digit(*++*pf)) {
        if (v >= 0) {
            int d = **pf - '0';
            if (INT_MAX_ / 10 < v) v = -1;
            else {
                v *= 10;
                if (INT_MAX_ - d < v) v = -1;
                else v += d;
            }
        }
    }
    return v;
}

/* ---- text of a floating-point number: a growable buffer that starts on the stack ----------------------------------- */

struct cbuf {
    char *p;
    size_t len, cap;
    int failed;
    char init[96];
};

static void cb_init(struct cbuf *b) {
    b->p = b->init;
    b->len = 0;
    b->cap = sizeof b->init;
    b->failed = 0;
}
static void cb_add(const struct moqi_scan_src *src, struct cbuf *b, char ch) {
    if (b->failed) return;
    if (b->len == b->cap) {
        size_t ncap = b->cap * 2;
        char *np;
        if (b->p == b->init) {
            np = (char *)src->alloc((void *)0, ncap);
            if (np) {
                for (size_t i = 0; i < b->len; i++) np[i] = b->init[i];
            }
        } else {
            np = (char *)src->alloc(b->p, ncap);
        }
        if (!np) {
            b->failed = 1;
            return;
        }
        b->p = np;
        b->cap = ncap;
    }
    b->p[b->len++] = ch;
}
static void cb_free(const struct moqi_scan_src *src, struct cbuf *b) {
    if (b->p != b->init && b->p) src->release(b->p);
    b->p = b->init;
}

/* ---- integers ------------------------------------------------------------------------------------------------------ */

struct num {
    unsigned long long mag;
    int neg;
    int over;   /* the magnitude does not fit 64 bits */
};

/* Reads one integer field. The digits are accumulated as they come (no text buffer): the sign, an optional 0x or 0b
 * prefix that is not part of the digits, then the longest run of digits valid in the base within the width. */
static int scan_int(struct sc *st, int base, int flags, int *pwidth, struct num *out) {
    int width = *pwidth;
    int c = inchar(st);
    if (c == -1) return R_INPUT;
    int have_sign = 0, have_digits = 0;
    out->mag = 0;
    out->neg = 0;
    out->over = 0;
    if (c == '-' || c == '+') {
        have_sign = 1;
        out->neg = c == '-';
        if (width > 0) --width;
        c = inchar(st);
    }
    if (width != 0 && c == '0') {
        if (width > 0) --width;
        c = inchar(st);
        if (width != 0 && lower(c) == 'x' && (base == 0 || base == 16)) {
            base = 16;
            if (width > 0) --width;
            if (width == 0) return R_CONV;   /* "0x" and nothing after it */
            c = inchar(st);
        } else if (width != 0 && lower(c) == 'b' && (base == 2 || base == 0)) {
            base = 2;
            if (width > 0) --width;
            if (width == 0) return R_CONV;
            c = inchar(st);
        } else {
            if (base == 0) base = 8;
            have_digits = 1;   /* the 0 itself is a digit; it adds nothing to the value */
        }
    }
    if (base == 0) base = 10;
    unsigned long long lim = ~0ULL / (unsigned)base;
    unsigned lim_d = (unsigned)(~0ULL % (unsigned)base);
    while (c != -1 && width != 0) {
        int d;
        if (is_digit(c)) d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        if (d >= base) break;
        have_digits = 1;
        if (out->mag > lim || (out->mag == lim && (unsigned)d > lim_d)) out->over = 1;
        else out->mag = out->mag * (unsigned)base + (unsigned)d;
        if (width > 0) --width;
        c = inchar(st);
    }
    if (!have_digits) {
        /* No number. A pointer may also be written "(nil)". */
        if (!have_sign && (flags & SC_READPTR) && (width < 0 || width >= 5) && c == '(' && lower(inchar(st)) == 'n' &&
            lower(inchar(st)) == 'i' && lower(inchar(st)) == 'l' && inchar(st) == ')') {
            out->mag = 0;
            *pwidth = width;
            return R_OK;
        }
        unget_any(st, st->c);
        return R_CONV;
    }
    unget_any(st, c);
    *pwidth = width;
    return R_OK;
}

/* ---- floating point ------------------------------------------------------------------------------------------------ */

/* Reads the text of one floating-point number into b. R_OK means b holds a complete number ("1.5e3", "0x1p-2", "-inf",
 * "nan(0x1)"); R_CONV that the text did not form one (what was read stays consumed, as in glibc). */
static int scan_float(struct sc *st, int *pflags, int *pwidth, struct cbuf *b) {
    const struct moqi_scan_src *src = st->src;
    int width = *pwidth;
    int c = inchar(st);
    if (width > 0) --width;
    if (c == -1) return R_INPUT;
    int got_digit = 0, got_dot = 0, got_e = 0;
    if (c == '-' || c == '+') {
        cb_add(src, b, (char)c);
        if (width == 0 || inchar(st) == -1) return R_CONV;
        c = st->c;
        if (width > 0) --width;
    }
    if (lower(c) == 'n') {
        cb_add(src, b, (char)c);
        if (width == 0 || inchar(st) == -1 || lower(st->c) != 'a') return R_CONV;
        if (width > 0) --width;
        cb_add(src, b, (char)st->c);
        if (width == 0 || inchar(st) == -1 || lower(st->c) != 'n') return R_CONV;
        if (width > 0) --width;
        cb_add(src, b, (char)st->c);
        if (width != 0 && inchar(st) != -1) {
            if (st->c == '(') {
                if (width > 0) --width;
                cb_add(src, b, '(');
                do {
                    if (width == 0 || inchar(st) == -1) return R_CONV;
                    if (!(is_nchar(st->c) || st->c == ')')) return R_CONV;
                    if (width > 0) --width;
                    cb_add(src, b, (char)st->c);
                } while (st->c != ')');
            } else {
                unget_any(st, st->c);
            }
        }
        *pwidth = width;
        return b->failed ? R_NOMEM : R_OK;
    }
    if (lower(c) == 'i') {
        static const char rest[] = "nf";
        static const char more[] = "inity";
        cb_add(src, b, (char)c);
        for (int i = 0; i < 2; i++) {
            if (width == 0 || inchar(st) == -1 || lower(st->c) != rest[i]) return R_CONV;
            if (width > 0) --width;
            cb_add(src, b, (char)st->c);
        }
        if (width != 0 && inchar(st) != -1) {
            if (lower(st->c) == 'i') {
                if (width > 0) --width;
                cb_add(src, b, (char)st->c);
                for (int i = 1; i < 5; i++) {
                    if (width == 0 || inchar(st) == -1 || lower(st->c) != more[i]) return R_CONV;
                    if (width > 0) --width;
                    cb_add(src, b, (char)st->c);
                }
            } else {
                unget_any(st, st->c);
            }
        }
        *pwidth = width;
        return b->failed ? R_NOMEM : R_OK;
    }
    int exp_char = 'e';
    if (width != 0 && c == '0') {
        cb_add(src, b, (char)c);
        c = inchar(st);
        if (width > 0) --width;
        if (lower(c) == 'x') {
            if (width == 0) return R_CONV;   /* "0x" and nothing after it */
            cb_add(src, b, (char)c);
            *pflags |= SC_HEXFLOAT;
            exp_char = 'p';
            c = inchar(st);
            if (width > 0) --width;
        } else {
            got_digit = 1;
        }
    }
    for (;;) {
        if (b->failed) return R_NOMEM;
        if (is_digit(c)) {
            cb_add(src, b, (char)c);
            got_digit = 1;
        } else if (!got_e && (*pflags & SC_HEXFLOAT) && is_xdigit(c)) {
            cb_add(src, b, (char)c);
            got_digit = 1;
        } else if (got_e && b->len > 0 && b->p[b->len - 1] == exp_char && (c == '-' || c == '+')) {
            cb_add(src, b, (char)c);
        } else if (got_digit && !got_e && lower(c) == exp_char) {
            cb_add(src, b, (char)exp_char);
            got_e = got_dot = 1;
            got_digit = 0;
        } else if (!got_dot && c == '.') {
            cb_add(src, b, '.');
            got_dot = 1;
        } else {
            unget_any(st, c);
            break;
        }
        if (width == 0 || inchar(st) == -1) break;
        c = st->c;
        if (width > 0) --width;
    }
    if (b->failed) return R_NOMEM;
    /* A sign alone, "0x" alone, a bare "." and "1e" (digits before the exponent only) all end without a digit to convert. */
    if (!got_digit) return R_CONV;
    *pwidth = width;
    return R_OK;
}

/* ---- string destinations ------------------------------------------------------------------------------------------- */

struct sd {
    unsigned char *base;
    size_t len, cap;
    unsigned esz;            /* 1 (char) or 4 (wchar_t) */
    char **slot;             /* the caller's pointer when the result is allocated (m), else NULL */
    size_t limit;            /* %c: the width, which the buffer never grows past (0 for strings, which just double) */
    int exact;               /* %c: no terminator follows, so the buffer grows only when another element arrives; the strings grow as soon as the buffer is full, to leave room for the terminator */
    int suppressed;
};

static int sd_grow(const struct moqi_scan_src *src, struct sd *d) {
    size_t want = d->cap * 2;
    if (d->limit && want > d->limit) want = d->limit;
    void *p = src->alloc(d->base, want * d->esz);
    if (!p) {
        want = d->len + 1;   /* last resort: just enough for the next element */
        p = src->alloc(d->base, want * d->esz);
        if (!p) return -1;
    }
    d->base = (unsigned char *)p;
    d->cap = want;
    *d->slot = (char *)p;
    return 0;
}

/* Stores one element (value >= 0) or, for value < 0, only advances over it (a wide byte that did not convert). */
static int sd_put(const struct moqi_scan_src *src, struct sd *d, long value) {
    if (d->suppressed) return 0;
    if (d->slot && d->len == d->cap && sd_grow(src, d) != 0) return -1;
    if (value >= 0) {
        if (d->esz == 1) d->base[d->len] = (unsigned char)value;
        else *(unsigned *)(void *)(d->base + d->len * 4) = (unsigned)value;
    }
    d->len++;
    if (d->slot && !d->exact && d->len == d->cap && sd_grow(src, d) != 0) return -1;
    return 0;
}

/* Ends a string: the terminator, then the allocated result is cut to its exact size. */
static void sd_finish(const struct moqi_scan_src *src, struct sd *d, int terminate) {
    if (d->suppressed) return;
    if (terminate) {
        if (d->esz == 1) d->base[d->len] = 0;
        else *(unsigned *)(void *)(d->base + d->len * 4) = 0;
        d->len++;
    }
    if (d->slot && d->len != d->cap) {
        void *p = src->alloc(d->base, d->len * d->esz);
        if (p) *d->slot = (char *)p;
    }
}

/* mbrtowc in the C locale for one byte: 1 for an ASCII character, 0 for NUL, -1 (EILSEQ) for anything else. */
static int wide_of(int c, long *w) {
    if (c == 0) {
        *w = 0;
        return 0;
    }
    if (c < 0x80) {
        *w = c;
        return 1;
    }
    errno = EILSEQ;
    return -1;
}

/* Writes the element at the current position without advancing (glibc's mbrtowc stores a converted NUL there). */
static int sd_poke(const struct moqi_scan_src *src, struct sd *d, unsigned value) {
    if (d->suppressed) return 0;
    if (d->slot && d->len == d->cap && sd_grow(src, d) != 0) return -1;
    *(unsigned *)(void *)(d->base + d->len * 4) = value;
    return 0;
}

/* One byte for %lc / %ls: 0 stored; 1 it is not a character (EILSEQ; a NUL byte is written but not counted, as glibc's
 * mbrtowc leaves it); -1 out of memory. */
static int put_wide_strict(const struct moqi_scan_src *src, struct sd *d, int c) {
    long w = 0;
    int n = wide_of(c, &w);
    if (n == 1) return sd_put(src, d, w) != 0 ? -1 : 0;
    if (n == 0 && sd_poke(src, d, 0) != 0) return -1;
    errno = EILSEQ;
    return 1;
}

/* The pointers of every %m result of this call, so that all can be released if the call fails with an allocation error. */
struct ptrlist {
    char **slot[32];
    unsigned n;
    struct ptrlist *next;
};

int __moqi_vscan(const struct moqi_scan_src *src, const char *format, va_list ap_in) {
    struct sc st;
    st.src = src;
    st.c = 0;
    st.inchar_errno = 0;
    st.nread = 0;
    if (!format) {
        errno = EINVAL;
        return -1;
    }
    const unsigned char *f = (const unsigned char *)format;
    int done = 0;
    int skip_space = 0;
    va_list ap, ap0;
    va_copy(ap, ap_in);
    va_copy(ap0, ap_in);
    struct ptrlist plist0;
    plist0.n = 0;
    plist0.next = (struct ptrlist *)0;
    struct ptrlist *plist = &plist0;
    char **strptr = (char **)0;

#define ARG(type) (argpos == 0 ? va_arg(ap, type) : ({ va_list t_; va_copy(t_, ap0); for (unsigned p_ = argpos; --p_ > 0;) (void)va_arg(t_, void *); type r_ = va_arg(t_, type); va_end(t_); r_; }))
#define INPUT_ERROR() do { if (done == 0) done = -1; goto errout; } while (0)
#define CONV_ERROR() goto errout

    while (*f != '\0') {
        unsigned argpos = 0;
        int flags = 0, width, base = 0;
        unsigned fc;

        if (*f >= 0x80) errno = EILSEQ;   /* glibc probes a multibyte character here; every byte above ASCII is invalid in the C locale and is then matched as an ordinary byte */
        fc = *f++;
        if (fc != '%') {
            if (is_space((int)fc)) {
                skip_space = 1;
                continue;
            }
            int c = inchar(&st);
            if (c == -1) INPUT_ERROR();
            if (skip_space) {
                while (is_space(c)) {
                    if (inchar(&st) == -1) INPUT_ERROR();
                    c = st.c;
                }
                skip_space = 0;
            }
            if (c != (int)fc) {
                unget_any(&st, c);
                CONV_ERROR();
            }
            continue;
        }

        if (is_digit(*f)) {
            int v = read_int(&f);
            argpos = (unsigned)v;
            if (*f == '$') {
                ++f;
            } else {
                width = v;
                argpos = 0;
                goto got_width;
            }
        }
        while (*f == '*' || *f == '\'' || *f == 'I') {
            if (*f == '*') flags |= SC_SUPPRESS;
            ++f;
        }
        width = 0;
        if (is_digit(*f)) width = read_int(&f);
    got_width:
        if (width == 0) width = -1;

        switch (*f++) {
        case 'h':
            if (*f == 'h') {
                ++f;
                flags |= SC_CHAR;
            } else {
                flags |= SC_SHORT;
            }
            break;
        case 'l':
            if (*f == 'l') {
                ++f;
                flags |= SC_LONGDBL | SC_LONG;
            } else {
                flags |= SC_LONG;
            }
            break;
        case 'q':
        case 'L':
            flags |= SC_LONGDBL | SC_LONG;
            break;
        case 'm':
            flags |= SC_MALLOC;
            if (*f == 'l') {
                ++f;
                flags |= SC_LONG;
            }
            break;
        case 'z':
        case 'j':
        case 't':
            flags |= SC_LONG;
            break;
        case 'w': {
            int fast = 0;
            if (*f == 'f') {
                ++f;
                fast = 1;
            }
            int bw = 0;
            if (is_digit(*f)) bw = read_int(&f);
            if (fast) {
                if (bw == 16 || bw == 32 || bw == 64) bw = 64;   /* int_fast16_t and int_fast32_t are 64 bits here */
            }
            if (bw == 8) flags |= SC_CHAR;
            else if (bw == 16) flags |= SC_SHORT;
            else if (bw == 32) {
            } else if (bw == 64) flags |= SC_LONGDBL | SC_LONG;
            else {
                errno = EINVAL;
                goto errout;
            }
            break;
        }
        default:
            --f;
            break;
        }

        if (*f == '\0') CONV_ERROR();

        fc = *f++;
        if (skip_space || (fc != '[' && fc != 'c' && fc != 'C' && fc != 'n')) {
            int save_errno = errno;
            errno = 0;
            do {
                if ((st.c == -1 || inchar(&st) == -1) && errno == 4 /* EINTR */) INPUT_ERROR();
            } while (is_space(st.c));
            errno = save_errno;
            unget_any(&st, st.c);
            skip_space = 0;
        }

        switch (fc) {
        case '%': {
            int c = inchar(&st);
            if (c == -1) INPUT_ERROR();
            if (c != '%') {
                unget_any(&st, c);
                CONV_ERROR();
            }
            break;
        }

        case 'n':
            if (!(flags & SC_SUPPRESS)) {
                if (flags & SC_LONG) *ARG(long *) = (long)st.nread;
                else if (flags & SC_SHORT) *ARG(short *) = (short)st.nread;
                else if (!(flags & SC_CHAR)) *ARG(int *) = (int)st.nread;
                else *ARG(char *) = (char)st.nread;
            }
            break;

        case 'c':
        case 'C':
        case 's':
        case 'S':
        case '[': {
            struct sd d;
            int wide = fc == 'C' || fc == 'S' || (flags & SC_LONG) != 0;
            int is_char = fc == 'c' || fc == 'C';
            int is_set = fc == '[';
            unsigned char map[256];
            int not_in = 0;
            if (is_char && width == -1) width = 1;

            d.suppressed = (flags & SC_SUPPRESS) != 0;
            d.esz = wide ? 4u : 1u;
            d.slot = (char **)0;
            d.exact = is_char;
            d.limit = is_char ? (size_t)width : 0;
            d.len = 0;
            d.cap = 0;
            d.base = (unsigned char *)0;
            if (!d.suppressed) {
                if (flags & SC_MALLOC) {
                    strptr = ARG(char **);
                    if (strptr == (char **)0) CONV_ERROR();
                    if (plist->n == sizeof plist->slot / sizeof plist->slot[0]) {
                        struct ptrlist *nl = (struct ptrlist *)src->alloc((void *)0, sizeof *nl);
                        if (!nl) {
                            strptr = (char **)0;
                            done = -1;
                            goto errout;
                        }
                        nl->n = 0;
                        nl->next = plist;
                        plist = nl;
                    }
                    size_t initial = is_char ? (size_t)(width > 1024 ? 1024 : width) : 100;
                    *strptr = (char *)src->alloc((void *)0, initial * d.esz);
                    if (*strptr == (char *)0) {
                        strptr = (char **)0;
                        done = -1;
                        goto errout;
                    }
                    plist->slot[plist->n++] = strptr;
                    d.slot = strptr;
                    d.base = (unsigned char *)*strptr;
                    d.cap = initial;
                } else {
                    d.base = wide ? (unsigned char *)ARG(unsigned *) : (unsigned char *)ARG(char *);
                    if (d.base == (unsigned char *)0) CONV_ERROR();
                }
            }

            if (is_set) {
                for (int i = 0; i < 256; i++) map[i] = 0;
                if (*f == '^') {
                    ++f;
                    not_in = 1;
                }
                unsigned sch = *f;
                if (sch == ']' || sch == '-') {
                    map[sch] = 1;
                    ++f;
                }
                while ((sch = *f++) != '\0' && sch != ']') {
                    if (sch == '-' && *f != '\0' && *f != ']' && f[-2] <= *f) {
                        for (unsigned k = f[-2]; k < *f; ++k) map[k] = 1;
                    } else {
                        map[sch] = 1;
                    }
                }
                if (sch == '\0') CONV_ERROR();
            }

            size_t now = st.nread;
            int c = inchar(&st);
            if (c == -1) INPUT_ERROR();

            if (is_char) {
                /* exactly `width` bytes; fewer is an input failure */
                do {
                    if (wide) {
                        int r = put_wide_strict(src, &d, c);
                        if (r < 0) { done = -1; goto errout; }
                        if (r > 0) goto errout;
                    } else if (sd_put(src, &d, c) != 0) {
                        done = -1;
                        goto errout;
                    }
                } while (--width > 0 && inchar(&st) != -1 && (c = st.c, 1));
                if (width > 0) INPUT_ERROR();
                sd_finish(src, &d, 0);
            } else if (!is_set) {
                /* %s, %S: up to white space or the width */
                do {
                    if (is_space(c)) {
                        unget_any(&st, c);
                        break;
                    }
                    if (wide) {
                        int r = put_wide_strict(src, &d, c);
                        if (r < 0) { done = -1; goto errout; }
                        if (r > 0) goto errout;
                    } else if (sd_put(src, &d, c) != 0) {
                        done = -1;
                        goto errout;
                    }
                } while ((width <= 0 || --width > 0) && inchar(&st) != -1 && (c = st.c, 1));
                sd_finish(src, &d, 1);
            } else {
                /* %[: the bytes in (or, with ^, outside) the set */
                do {
                    if (map[c] == (unsigned char)not_in) {
                        unget_any(&st, c);
                        break;
                    }
                    if (wide) {
                        /* mbrtowc is not checked here: a byte above ASCII leaves its element untouched but still counts */
                        long w = 0;
                        int n = d.suppressed ? 1 : wide_of(c, &w);
                        if (sd_put(src, &d, n >= 0 ? w : -1) != 0) { done = -1; goto errout; }
                    } else if (sd_put(src, &d, c) != 0) {
                        done = -1;
                        goto errout;
                    }
                    if (width >= 0 && --width <= 0) break;
                } while (inchar(&st) != -1 && (c = st.c, 1));
                if (now == st.nread) CONV_ERROR();
                sd_finish(src, &d, 1);
            }
            if (!d.suppressed) {
                strptr = (char **)0;
                ++done;
            }
            break;
        }

        case 'x':
        case 'X':
            base = 16;
            goto number;
        case 'o':
            base = 8;
            goto number;
        case 'b':
            base = 2;
            goto number;
        case 'u':
            base = 10;
            goto number;
        case 'd':
            base = 10;
            flags |= SC_SIGNED;
            goto number;
        case 'i':
            base = 0;
            flags |= SC_SIGNED;
            goto number;
        case 'p':
            base = 16;
            flags |= SC_LONG | SC_READPTR;   /* a pointer is stored as unsigned long whatever modifier came before */
        number: {
            struct num v;
            int r = scan_int(&st, base, flags, &width, &v);
            if (r == R_INPUT) INPUT_ERROR();
            if (r != R_OK) CONV_ERROR();
            if (flags & SC_SIGNED) {
                long long sv;
                if (v.over || (!v.neg && v.mag > 9223372036854775807ULL) || (v.neg && v.mag > 9223372036854775808ULL)) {
                    errno = ERANGE;
                    sv = v.neg ? (-9223372036854775807LL - 1) : 9223372036854775807LL;
                } else {
                    sv = v.neg ? (long long)(0ULL - v.mag) : (long long)v.mag;
                }
                if (!(flags & SC_SUPPRESS)) {
                    if (flags & SC_LONG) *ARG(long *) = (long)sv;
                    else if (flags & SC_SHORT) *ARG(short *) = (short)sv;
                    else if (!(flags & SC_CHAR)) *ARG(int *) = (int)sv;
                    else *ARG(signed char *) = (signed char)sv;
                    ++done;
                }
            } else {
                unsigned long long uv;
                if (v.over) {
                    errno = ERANGE;
                    uv = ~0ULL;
                } else {
                    uv = v.neg ? 0ULL - v.mag : v.mag;
                }
                if (!(flags & SC_SUPPRESS)) {
                    if (flags & SC_LONG) *ARG(unsigned long *) = (unsigned long)uv;
                    else if (flags & SC_SHORT) *ARG(unsigned short *) = (unsigned short)uv;
                    else if (!(flags & SC_CHAR)) *ARG(unsigned *) = (unsigned)uv;
                    else *ARG(unsigned char *) = (unsigned char)uv;
                    ++done;
                }
            }
            break;
        }

        case 'e':
        case 'E':
        case 'f':
        case 'F':
        case 'g':
        case 'G':
        case 'a':
        case 'A': {
            struct cbuf b;
            cb_init(&b);
            int r = scan_float(&st, &flags, &width, &b);
            if (r == R_OK && (flags & SC_LONGDBL)) {
                /* long double is not supported: nothing is stored */
                cb_free(src, &b);
                errno = EINVAL;
                goto errout;
            }
            if (r == R_NOMEM) {
                cb_free(src, &b);
                errno = ENOMEM;
                done = -1;
                goto errout;
            }
            if (r != R_OK) {
                cb_free(src, &b);
                if (r == R_INPUT) INPUT_ERROR();
                CONV_ERROR();
            }
            cb_add(src, &b, '\0');
            if (b.failed) {
                cb_free(src, &b);
                errno = ENOMEM;
                done = -1;
                goto errout;
            }
            char *end;
            if (flags & SC_LONG) {
                double dv = strtod(b.p, &end);
                if (end != b.p && !(flags & SC_SUPPRESS)) *ARG(double *) = dv;
            } else {
                float fv = strtof(b.p, &end);
                if (end != b.p && !(flags & SC_SUPPRESS)) *ARG(float *) = fv;
            }
            int none = end == b.p;
            cb_free(src, &b);
            if (none) CONV_ERROR();
            if (!(flags & SC_SUPPRESS)) ++done;
            break;
        }

        default:
            CONV_ERROR();
        }
    }

    if (skip_space) {
        do {
            inchar(&st);
        } while (is_space(st.c));
        unget_any(&st, st.c);
    }

errout:
    if (done == -1) {
        for (struct ptrlist *p = plist; p; p = p->next)
            for (unsigned i = 0; i < p->n; i++) {
                src->release(*p->slot[i]);
                *p->slot[i] = (char *)0;
            }
    } else if (strptr != (char **)0) {
        src->release(*strptr);
        *strptr = (char *)0;
    }
    while (plist != &plist0) {
        struct ptrlist *nx = plist->next;
        src->release(plist);
        plist = nx;
    }
    va_end(ap);
    va_end(ap0);
    return done;
#undef ARG
#undef INPUT_ERROR
#undef CONV_ERROR
}
