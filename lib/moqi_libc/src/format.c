/* format.c — printf formatting core (vsnprintf/snprintf).
 *
 * Pure formatter: no syscalls, no globals. Host-testable.
 * Conversions: %d %i %u %x %X %s %c %p %% with optional l / ll length
 * modifiers. No floating point, no width/precision, no flags.
 */
#include "../include/stdio.h"

struct out {
    char *buf;
    size_t size;   /* total buffer size including NUL */
    size_t pos;    /* characters that would have been written so far */
};

static void out_char(struct out *o, char c) {
    if (o->pos + 1 < o->size) o->buf[o->pos] = c;
    o->pos++;
}

static void out_str(struct out *o, const char *s) {
    while (*s) out_char(o, *s++);
}

/* Digits are produced least-significant first, so emit into a scratch
 * buffer and dump it backwards. Handles the full unsigned range, which
 * also covers INT_MIN/LONG_MIN after negation. */
static void out_uint(struct out *o, unsigned long long v, unsigned base, int upper) {
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char tmp[22]; /* ceil(64 / log2(8)) + sign margin; 20 is enough for base 10 */
    int i = 0;
    if (v == 0) {
        out_char(o, '0');
        return;
    }
    while (v > 0) {
        tmp[i++] = digits[v % base];
        v /= base;
    }
    while (i > 0) out_char(o, tmp[--i]);
}

static void out_int(struct out *o, long long v) {
    unsigned long long u;
    if (v < 0) {
        out_char(o, '-');
        u = 0ULL - (unsigned long long)v; /* safe for LLONG_MIN */
    } else {
        u = (unsigned long long)v;
    }
    out_uint(o, u, 10, 0);
}

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    struct out o = { buf, size, 0 };

    while (*fmt) {
        if (*fmt != '%') {
            out_char(&o, *fmt++);
            continue;
        }
        fmt++; /* skip '%' */
        if (*fmt == '%') {
            out_char(&o, '%');
            fmt++;
            continue;
        }

        int lng = 0; /* 0 = int, 1 = long, 2 = long long */
        while (*fmt == 'l') { lng++; fmt++; }
        if (lng > 2) lng = 2;

        switch (*fmt) {
        case 'd':
        case 'i': {
            long long v = (lng == 2) ? va_arg(ap, long long)
                        : (lng == 1) ? va_arg(ap, long)
                                     : va_arg(ap, int);
            out_int(&o, v);
            break;
        }
        case 'u': {
            unsigned long long v = (lng == 2) ? va_arg(ap, unsigned long long)
                                 : (lng == 1) ? va_arg(ap, unsigned long)
                                              : va_arg(ap, unsigned int);
            out_uint(&o, v, 10, 0);
            break;
        }
        case 'x':
        case 'X': {
            unsigned long long v = (lng == 2) ? va_arg(ap, unsigned long long)
                                 : (lng == 1) ? va_arg(ap, unsigned long)
                                              : va_arg(ap, unsigned int);
            out_uint(&o, v, 16, *fmt == 'X');
            break;
        }
        case 's': {
            const char *s = va_arg(ap, const char *);
            out_str(&o, s ? s : "(null)");
            break;
        }
        case 'c':
            out_char(&o, (char)va_arg(ap, int));
            break;
        case 'p': {
            void *p = va_arg(ap, void *);
            if (p == (void *)0) {
                out_str(&o, "(nil)");
            } else {
                out_str(&o, "0x");
                out_uint(&o, (unsigned long)(size_t)p, 16, 0);
            }
            break;
        }
        default:
            /* Unknown conversion: emit it literally. */
            out_char(&o, '%');
            if (lng > 0) out_char(&o, 'l');
            if (lng > 1) out_char(&o, 'l');
            if (*fmt) out_char(&o, *fmt);
            break;
        }
        if (*fmt) fmt++;
    }

    if (size > 0) buf[o.pos < size ? o.pos : size - 1] = '\0';
    return (int)o.pos;
}

int snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return n;
}
