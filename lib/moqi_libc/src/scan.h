/* scan.h — the scanf engine's view of its input: a character source with one level of pushback and the allocator used by
 * the "m" modifier. sscanf, fscanf and scanf only differ in the source they hand to __moqi_vscan (scan.c). */
#ifndef MOQI_SCAN_H
#define MOQI_SCAN_H

#include <stddef.h>

/* va_list comes from the includer: include/stdio.h in the library, <stdarg.h> in the host test. */

struct moqi_scan_src {
    int (*get)(void *ctx);                 /* next byte (0..255), or -1 at the end of the input or on an error (errno says which) */
    void (*unget)(void *ctx, int c);       /* push back the byte that get returned last */
    void *(*alloc)(void *old, size_t n);   /* realloc; alloc(NULL, n) is malloc. Returns NULL on failure */
    void (*release)(void *p);              /* free */
    void *ctx;
};

/* Reads input as the format says and stores through the pointers in ap. Returns the number of assignments, or -1 when the
 * input ended (or failed) before the first conversion finished. */
int __moqi_vscan(const struct moqi_scan_src *src, const char *fmt, va_list ap);

#endif
