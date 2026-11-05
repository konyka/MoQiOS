/* stdlib.c — simple conversions, environment lookup (exit and atexit are in exit.c). */
#include "../include/stdlib.h"
#include "../include/unistd.h"
#include "../include/ctype.h"

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
