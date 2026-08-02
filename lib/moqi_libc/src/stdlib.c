/* stdlib.c — exit and simple conversions. */
#include "../include/stdlib.h"
#include "../include/unistd.h"
#include "../include/ctype.h"

/* No atexit handlers and no stdio buffers to flush: exit is _exit. */
void exit(int code) {
    _exit(code);
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
