/* stdio.h — stdio-lite for MoQiOS user programs.
 *
 * print/puts/putchar/printf write to fd 1 (freestanding only).
 * snprintf/vsnprintf are pure formatters with no syscall dependency.
 * Supported conversions: %d %i %u %x %X %s %c %p %%, with optional
 * length modifiers l and ll. No floating point, no width/precision.
 */
#ifndef MOQI_STDIO_H
#define MOQI_STDIO_H

#include <stddef.h>

#ifndef MOQI_VA_LIST
#define MOQI_VA_LIST
typedef __builtin_va_list va_list;
#define va_start __builtin_va_start
#define va_end   __builtin_va_end
#define va_arg   __builtin_va_arg
#endif

/* Pure formatters (host-testable, no syscalls). Return the number of
 * characters that would have been written, excluding the NUL, like C99. */
int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int snprintf(char *buf, size_t size, const char *fmt, ...);

/* fd-1 output (freestanding only — these issue the write syscall). */
void print(const char *s);
void putchar(int c);
int  puts(const char *s);
int  printf(const char *fmt, ...);

#endif /* MOQI_STDIO_H */
