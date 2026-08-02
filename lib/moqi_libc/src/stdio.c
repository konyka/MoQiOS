/* stdio.c — fd-1 output built on the pure formatter (freestanding only). */
#include "../include/stdio.h"
#include "../include/unistd.h"
#include "../include/string.h"

void print(const char *s) {
    write(STDOUT_FILENO, s, strlen(s));
}

void putchar(int c) {
    char ch = (char)c;
    write(STDOUT_FILENO, &ch, 1);
}

int puts(const char *s) {
    print(s);
    putchar('\n');
    return 0;
}

/* Format into a fixed stack buffer and write it out. Longer output is
 * truncated; user programs print short diagnostic lines, so 512 bytes
 * matches the style of the existing hand-rolled print helpers. */
int printf(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    print(buf);
    return n;
}
