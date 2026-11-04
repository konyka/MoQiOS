/* scanf.c — sscanf and vsscanf: the scanf engine (scan.c) over a NUL-terminated string. The stream forms (fscanf, scanf,
 * vfscanf, vscanf) are in stdio_file.c and stdio_streams.c. */
#include "../include/errno.h"
#include "../include/stdio.h"
#include "../include/stdlib.h"
#include "scan.h"

struct str_src {
    const unsigned char *s;
    size_t i;
};

/* The terminating NUL is the end of the input; it is never consumed. */
static int str_get(void *ctx) {
    struct str_src *p = (struct str_src *)ctx;
    if (p->s[p->i] == 0) return -1;
    return p->s[p->i++];
}
static void str_unget(void *ctx, int c) {
    (void)c;
    ((struct str_src *)ctx)->i--;
}
static void *str_alloc(void *old, size_t n) { return realloc(old, n); }
static void str_free(void *p) { free(p); }

int vsscanf(const char *s, const char *fmt, va_list ap) {
    if (!s || !fmt) {
        /* a NULL string crashes glibc; a NULL format is EINVAL there, as for the stream forms */
        errno = EINVAL;
        return -1;
    }
    struct str_src ss = { (const unsigned char *)s, 0 };
    struct moqi_scan_src src = { str_get, str_unget, str_alloc, str_free, &ss };
    return __moqi_vscan(&src, fmt, ap);
}

int sscanf(const char *s, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsscanf(s, fmt, ap);
    va_end(ap);
    return n;
}
