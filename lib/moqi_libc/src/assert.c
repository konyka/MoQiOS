/* assert.c — the failure path of assert (see include/assert.h). */
#include "../include/errno.h"
#include "../include/signal.h"
#include "../include/unistd.h"

/* Builds the whole line in one buffer and writes it with one write, so that it cannot be interleaved with another thread's
 * output; a line that does not fit is cut. */
void __assert_fail(const char *expr, const char *file, unsigned int line, const char *function) {
    char buf[512];
    unsigned long n = 0;
    const char *parts[8];
    unsigned long np = 0;
    char num[12];
    int nl = 0;
    unsigned int v = line;
    char tmp[12];
    int tn = 0;
    if (v == 0) tmp[tn++] = '0';
    while (v) { tmp[tn++] = (char)('0' + v % 10); v /= 10; }
    while (tn) num[nl++] = tmp[--tn];
    num[nl] = 0;

    parts[np++] = program_invocation_short_name;
    parts[np++] = ": ";
    parts[np++] = file;
    parts[np++] = ":";
    parts[np++] = num;
    parts[np++] = ": ";
    if (function) {
        parts[np++] = function;
        parts[np++] = ": ";
    }
    for (unsigned long i = 0; i < np; i++) {
        for (const char *p = parts[i]; *p && n < sizeof buf - 1; p++) buf[n++] = *p;
    }
    static const char head[] = "Assertion `";
    static const char tail[] = "' failed.\n";
    for (const char *p = head; *p && n < sizeof buf - 1; p++) buf[n++] = *p;
    for (const char *p = expr; *p && n < sizeof buf - sizeof tail; p++) buf[n++] = *p;
    for (const char *p = tail; *p && n < sizeof buf - 1; p++) buf[n++] = *p;
    write(STDERR_FILENO, buf, n);
    abort();
}
