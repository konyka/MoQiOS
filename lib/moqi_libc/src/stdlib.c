/* stdlib.c — exit, simple conversions, environment lookup. */
#include "../include/stdlib.h"
#include "../include/unistd.h"
#include "../include/ctype.h"

/* No atexit handlers; the FILE buffers are flushed first (stdio.c). */
/* Weak, so a program (or a host test) that does not link the stdio code still gets a working exit. */
extern int fflush_all(void) __attribute__((weak));
void exit(int code) {
    if (fflush_all) fflush_all();
    _exit(code);
}

/* environ is defined and initialised by crt0.c from the initial stack. */
char *getenv(const char *name) {
    if (name == (const char *)0 || environ == (char **)0) return (char *)0;
    unsigned long nlen = 0;
    while (name[nlen]) nlen++;
    if (nlen == 0) return (char *)0;
    for (char **e = environ; *e; e++) {
        const char *entry = *e;
        unsigned long i = 0;
        while (i < nlen && entry[i] == name[i]) i++;
        if (i == nlen && entry[i] == '=') return (char *)entry + nlen + 1;
    }
    return (char *)0;
}

int atoi(const char *s) {
    while (isspace((unsigned char)*s)) s++;
    int neg = 0;
    if (*s == '-' || *s == '+') {
        neg = (*s == '-');
        s++;
    }
    int v = 0;
    while (isdigit((unsigned char)*s)) {
        v = v * 10 + (*s - '0');
        s++;
    }
    return neg ? -v : v;
}
