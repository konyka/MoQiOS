/* format.c — the printf formatting engine and the string-buffer printf functions (see include/stdio.h).
 *
 * One engine, __moqi_vformat, serves every printf function: it writes either into a caller's buffer (snprintf and
 * friends, truncating like C99) or through a sink callback in chunks (printf, dprintf; stdio.c). It has no syscalls and
 * no allocation, so it runs from signal handlers and on the host in the unit tests.
 *
 * The conversion grammar and every corner of it follow glibc as measured (host_tests/test_printf_abi.c, generated from
 * glibc): % [flags # 0 - + space ' I] [width | *] [. precision | .*] [length hh h l ll L q z Z j t] conversion, with
 * d i u o x X b B c s p n m % C S. A conversion it does not know is echoed the way glibc echoes it: '%', the flags in
 * glibc's fixed order, the width, ".precision", then the conversion character, with the length modifier dropped.
 * Floating point (e f g a) and positional arguments (%1$d) are not supported; they are echoed as unknown conversions.
 * Failure is -1: EINVAL when the format ends inside a conversion, EILSEQ for a wide character that is not ASCII (this
 * is the C locale), EOVERFLOW when the result would not fit an int or a width/precision does not.
 */
#include "../include/errno.h"
#include "../include/stdio.h"
#include "../include/string.h"

#define FMT_INT_MAX 2147483647ULL

struct fmt_out {
    char *buf;
    size_t cap;              /* bytes of buf that may be used */
    size_t fill;             /* bytes in buf */
    unsigned long long pos;  /* characters produced so far, including those that did not fit */
    moqi_sink_fn sink;       /* NULL: buf is the destination and what does not fit is dropped */
    void *ctx;
    int err;                 /* errno value of the first failure, 0 if none */
};

static void out_flush(struct fmt_out *o) {
    if (o->err || o->fill == 0) return;
    int e = o->sink(o->ctx, o->buf, o->fill);
    o->fill = 0;
    if (e) o->err = e;
}

static int out_room(struct fmt_out *o, unsigned long long n) {
    if (o->err) return 0;
    if (o->pos + n > FMT_INT_MAX) {
        o->err = EOVERFLOW;
        return 0;
    }
    return 1;
}

static void out_bytes(struct fmt_out *o, const char *p, size_t n) {
    if (!out_room(o, n)) return;
    o->pos += n;
    while (n) {
        size_t space = o->cap - o->fill;
        if (space == 0) {
            if (!o->sink) return;
            out_flush(o);
            if (o->err) return;
            continue;
        }
        size_t k = n < space ? n : space;
        for (size_t i = 0; i < k; i++) o->buf[o->fill + i] = p[i];
        o->fill += k;
        p += k;
        n -= k;
    }
}

/* n copies of c. A huge width into a buffer that is already full costs nothing: only the counter moves. */
static void out_fill(struct fmt_out *o, char c, unsigned long long n) {
    if (!out_room(o, n)) return;
    o->pos += n;
    while (n) {
        size_t space = o->cap - o->fill;
        if (space == 0) {
            if (!o->sink) return;
            out_flush(o);
            if (o->err) return;
            continue;
        }
        size_t k = n < space ? (size_t)n : space;
        for (size_t i = 0; i < k; i++) o->buf[o->fill + i] = c;
        o->fill += k;
        n -= k;
    }
}

static void out_char(struct fmt_out *o, char c) { out_bytes(o, &c, 1); }

static void out_dec(struct fmt_out *o, unsigned long long v) {
    char tmp[24];
    size_t i = sizeof tmp;
    do {
        tmp[--i] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    out_bytes(o, tmp + i, sizeof tmp - i);
}

enum { LEN_NONE, LEN_HH, LEN_H, LEN_L, LEN_LL, LEN_OTHER };

struct spec {
    int alt, group, plus, space, left, zero, i18n;
    long long width;  /* never negative: a negative '*' width sets left */
    long long prec;   /* -1: none */
    int len;
};

static int len_is_wide(int len) { return len == LEN_L || len == LEN_LL || len == LEN_OTHER; }

/* A number: sign, prefix, precision zeros, digits, padded to the width. signed_conv gives the sign flags meaning;
 * alt is the '#' flag (forced for %p). */
static void emit_number(struct fmt_out *o, const struct spec *s, int signed_conv, int neg, unsigned long long mag,
                        unsigned base, int upper, int alt) {
    char tmp[64];
    size_t nd = 0;
    const char *dg = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (!(mag == 0 && s->prec == 0)) {
        unsigned long long v = mag;
        do {
            tmp[nd++] = dg[v % base];
            v /= base;
        } while (v);
    }
    char sign = 0;
    if (signed_conv) sign = neg ? '-' : s->plus ? '+' : s->space ? ' ' : 0;
    const char *prefix = "";
    size_t plen = 0;
    if (alt && mag != 0) {
        if (base == 16) {
            prefix = upper ? "0X" : "0x";
            plen = 2;
        } else if (base == 2) {
            prefix = upper ? "0B" : "0b";
            plen = 2;
        }
    }
    unsigned long long zeros = s->prec > (long long)nd ? (unsigned long long)s->prec - nd : 0;
    if (base == 8 && alt && zeros == 0 && (nd == 0 || tmp[nd - 1] != '0')) zeros = 1;
    unsigned long long total = (sign ? 1ULL : 0ULL) + plen + zeros + nd;
    unsigned long long spaces = 0, zfill = 0;
    if ((unsigned long long)s->width > total) {
        unsigned long long extra = (unsigned long long)s->width - total;
        if (s->left || !s->zero || s->prec >= 0) spaces = extra;
        else zfill = extra;
    }
    if (!s->left) out_fill(o, ' ', spaces);
    if (sign) out_char(o, sign);
    out_bytes(o, prefix, plen);
    out_fill(o, '0', zfill + zeros);
    while (nd) out_char(o, tmp[--nd]);
    if (s->left) out_fill(o, ' ', spaces);
}

/* Text of known length, padded with spaces to the width. */
static void emit_text(struct fmt_out *o, const struct spec *s, const char *text, size_t len) {
    unsigned long long pad = (unsigned long long)s->width > len ? (unsigned long long)s->width - len : 0;
    if (!s->left) out_fill(o, ' ', pad);
    out_bytes(o, text, len);
    if (s->left) out_fill(o, ' ', pad);
}

/* The wide characters are ASCII (checked by the caller); bytes go out in small runs. */
static void emit_wide(struct fmt_out *o, const struct spec *s, const wchar_t *w, size_t len) {
    unsigned long long pad = (unsigned long long)s->width > len ? (unsigned long long)s->width - len : 0;
    if (!s->left) out_fill(o, ' ', pad);
    char run[64];
    size_t i = 0;
    while (i < len) {
        size_t k = 0;
        while (k < sizeof run && i < len) run[k++] = (char)w[i++];
        out_bytes(o, run, k);
    }
    if (s->left) out_fill(o, ' ', pad);
}

/* Digits of a width or precision; returns 0 and the value, or -1 when it does not fit an int. */
static int parse_count(const char **pf, long long *out) {
    long long v = 0;
    const char *f = *pf;
    while (*f >= '0' && *f <= '9') {
        v = v * 10 + (*f - '0');
        if (v > (long long)FMT_INT_MAX) return -1;
        f++;
    }
    *pf = f;
    *out = v;
    return 0;
}

static void echo_unknown(struct fmt_out *o, const struct spec *s, char conv) {
    out_char(o, '%');
    if (s->alt) out_char(o, '#');
    if (s->group) out_char(o, '\'');
    if (s->plus) out_char(o, '+');
    else if (s->space) out_char(o, ' ');
    if (s->left) out_char(o, '-');
    if (s->zero) out_char(o, '0');
    if (s->i18n) out_char(o, 'I');
    if (s->width != 0) out_dec(o, (unsigned long long)s->width);
    if (s->prec != -1) {
        out_char(o, '.');
        out_dec(o, (unsigned long long)s->prec);
    }
    out_char(o, conv);
}

static const char null_text[] = "(null)";

int __moqi_vformat(char *buf, size_t size, moqi_sink_fn sink, void *ctx, const char *fmt, va_list ap) {
    struct fmt_out o;
    o.sink = sink;
    o.ctx = ctx;
    o.fill = 0;
    o.pos = 0;
    o.err = 0;
    o.buf = buf;
    o.cap = sink ? size : (size > 0 ? size - 1 : 0);

    while (*fmt && !o.err) {
        if (*fmt != '%') {
            const char *run = fmt;
            while (*fmt && *fmt != '%') fmt++;
            out_bytes(&o, run, (size_t)(fmt - run));
            continue;
        }
        fmt++;

        struct spec s;
        s.alt = s.group = s.plus = s.space = s.left = s.zero = s.i18n = 0;
        s.width = 0;
        s.prec = -1;
        s.len = LEN_NONE;

        for (int more = 1; more;) {
            switch (*fmt) {
            case '#': s.alt = 1; fmt++; break;
            case '\'': s.group = 1; fmt++; break;
            case '+': s.plus = 1; fmt++; break;
            case ' ': s.space = 1; fmt++; break;
            case 'I': s.i18n = 1; fmt++; break;
            case '-': s.left = 1; s.zero = 0; fmt++; break;
            case '0': if (!s.left) s.zero = 1; fmt++; break;
            default: more = 0; break;
            }
        }

        if (*fmt == '*') {
            long long w = va_arg(ap, int);
            if (w < 0) {
                s.left = 1;
                w = -w;
            }
            s.width = w;
            fmt++;
        } else if (parse_count(&fmt, &s.width) != 0) {
            o.err = EOVERFLOW;
            break;
        }

        if (*fmt == '.') {
            fmt++;
            if (*fmt == '*') {
                long long p = va_arg(ap, int);
                s.prec = p < 0 ? -1 : p;
                fmt++;
            } else if (parse_count(&fmt, &s.prec) != 0) {
                o.err = EOVERFLOW;
                break;
            }
        }

        switch (*fmt) {
        case 'h': fmt++; if (*fmt == 'h') { s.len = LEN_HH; fmt++; } else s.len = LEN_H; break;
        case 'l': fmt++; if (*fmt == 'l') { s.len = LEN_LL; fmt++; } else s.len = LEN_L; break;
        case 'L': case 'q': case 'z': case 'Z': case 'j': case 't': s.len = LEN_OTHER; fmt++; break;
        default: break;
        }

        char conv = *fmt;
        if (conv == '\0') {
            o.err = EINVAL;
            break;
        }
        fmt++;

        switch (conv) {
        case 'd':
        case 'i': {
            long long v;
            if (s.len == LEN_HH) v = (signed char)va_arg(ap, int);
            else if (s.len == LEN_H) v = (short)va_arg(ap, int);
            else if (s.len == LEN_NONE) v = va_arg(ap, int);
            else v = va_arg(ap, long);
            int neg = v < 0;
            emit_number(&o, &s, 1, neg, neg ? 0ULL - (unsigned long long)v : (unsigned long long)v, 10, 0, 0);
            break;
        }
        case 'u':
        case 'o':
        case 'x':
        case 'X':
        case 'b':
        case 'B': {
            unsigned long long v;
            if (s.len == LEN_HH) v = (unsigned char)va_arg(ap, unsigned int);
            else if (s.len == LEN_H) v = (unsigned short)va_arg(ap, unsigned int);
            else if (s.len == LEN_NONE) v = va_arg(ap, unsigned int);
            else v = va_arg(ap, unsigned long);
            unsigned base = conv == 'u' ? 10 : conv == 'o' ? 8 : (conv == 'b' || conv == 'B') ? 2 : 16;
            emit_number(&o, &s, 0, 0, v, base, conv == 'X' || conv == 'B', s.alt);
            break;
        }
        case 'c':
        case 'C': {
            if (conv == 'C' || len_is_wide(s.len)) {
                unsigned int w = va_arg(ap, unsigned int);
                if (w > 127) {
                    o.err = EILSEQ;
                    break;
                }
                char c = (char)w;
                emit_text(&o, &s, &c, 1);
            } else {
                char c = (char)va_arg(ap, int);
                emit_text(&o, &s, &c, 1);
            }
            break;
        }
        case 's':
        case 'S': {
            if (conv == 'S' || len_is_wide(s.len)) {
                const wchar_t *w = va_arg(ap, const wchar_t *);
                if (w == (const wchar_t *)0) {
                    size_t n = (s.prec >= 0 && s.prec < 6) ? 0 : 6;
                    emit_text(&o, &s, null_text, n);
                    break;
                }
                size_t n = 0;
                while ((s.prec < 0 || (long long)n < s.prec) && w[n] != 0) {
                    if (w[n] < 0 || w[n] > 127) {
                        o.err = EILSEQ;
                        break;
                    }
                    n++;
                }
                if (o.err) break;
                emit_wide(&o, &s, w, n);
            } else {
                const char *t = va_arg(ap, const char *);
                size_t n;
                if (t == (const char *)0) {
                    t = null_text;
                    n = (s.prec >= 0 && s.prec < 6) ? 0 : 6;
                } else {
                    n = 0;
                    while ((s.prec < 0 || (long long)n < s.prec) && t[n] != '\0') n++;
                }
                emit_text(&o, &s, t, n);
            }
            break;
        }
        case 'p': {
            void *p = va_arg(ap, void *);
            if (p == (void *)0) {
                emit_text(&o, &s, "(nil)", 5);
            } else {
                emit_number(&o, &s, 1, 0, (unsigned long long)(size_t)p, 16, 0, 1);
            }
            break;
        }
        case 'n': {
            void *p = va_arg(ap, void *);
            if (s.len == LEN_HH) *(signed char *)p = (signed char)o.pos;
            else if (s.len == LEN_H) *(short *)p = (short)o.pos;
            else if (s.len == LEN_NONE) *(int *)p = (int)o.pos;
            else *(long *)p = (long)o.pos;
            break;
        }
        case 'm': {
            const char *t = strerror(errno);
            size_t n = 0;
            while ((s.prec < 0 || (long long)n < s.prec) && t[n] != '\0') n++;
            emit_text(&o, &s, t, n);
            break;
        }
        case '%':
            out_char(&o, '%');
            break;
        default:
            echo_unknown(&o, &s, conv);
            break;
        }
    }

    if (!o.sink) {
        if (size > 0) buf[o.fill] = '\0';
    } else if (!o.err) {
        out_flush(&o);
    }
    if (o.err) {
        errno = o.err;
        return -1;
    }
    return (int)o.pos;
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    return __moqi_vformat(buf, size, (moqi_sink_fn)0, (void *)0, fmt, ap);
}

int snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return n;
}

int vsprintf(char *buf, const char *fmt, va_list ap) {
    return vsnprintf(buf, (size_t)-1, fmt, ap);
}

int sprintf(char *buf, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsprintf(buf, fmt, ap);
    va_end(ap);
    return n;
}
