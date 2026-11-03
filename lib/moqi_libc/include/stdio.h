/* stdio.h — stdio-lite for MoQiOS user programs.
 *
 * The printf family follows glibc's grammar and results, checked against glibc (host_tests/test_printf_abi.c):
 *   %[flags][width][.precision][length]conversion
 *   flags       # 0 - + space ' I   (' and I are accepted and do nothing, as in glibc's C locale)
 *   width       digits or * (a negative * is the - flag)
 *   precision   .digits or .* (a negative * is no precision; "." alone is 0)
 *   length      hh h l ll L q z Z j t
 *   conversion  d i u o x X b B (binary, as glibc 2.35+)  c s p n m  C S  %
 * %lc %ls %C %S (and any length from l up on c and s) are wide: ASCII only, anything else fails with EILSEQ. %m is
 * strerror(errno). %p prints (nil) for NULL. A NULL %s prints (null) unless the precision is under 6. An unknown
 * conversion is written back as it was meant to be read (see format.c).
 * Floating point: f F e E g G a A take a double and print it from its exact decimal (or hexadecimal) expansion, so the
 * text is glibc's digit for digit, ties and carries included; inf and nan print as inf/nan (INF/NAN for the capitals),
 * without zero padding. h and l are accepted and ignored; L (long double) is not supported: it fails with EINVAL.
 * No positional arguments (%1$d).
 *
 * Failure is -1 with errno: EINVAL (the format ends inside a conversion), EILSEQ (non-ASCII wide character), EOVERFLOW
 * (the result, a width or a precision does not fit an int), ENOMEM (asprintf), or the error of write(). Output that was
 * produced before a failure in the snprintf and sprintf functions stays in the buffer, terminated.
 *
 * snprintf/vsnprintf/sprintf/vsprintf are pure formatters with no syscall dependency. The functions that write
 * (printf, dprintf, puts, putchar) issue write(2) directly: there is no stdio buffering, so output appears at once, in
 * chunks of at most 512 bytes for long results, and a failure part-way leaves what was already written written.
 * There is no FILE type: printf/puts/putchar write to fd 1.
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
#define va_copy  __builtin_va_copy
#endif

/* Pure formatters (host-testable, no syscalls). Return the number of characters that would have been written,
 * excluding the NUL, like C99; size 0 writes nothing. sprintf has no bound. */
int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int snprintf(char *buf, size_t size, const char *fmt, ...);
int vsprintf(char *buf, const char *fmt, va_list ap);
int sprintf(char *buf, const char *fmt, ...);

/* A formatted string in memory from malloc (free it). On failure *strp is NULL. */
int vasprintf(char **strp, const char *fmt, va_list ap);
int asprintf(char **strp, const char *fmt, ...);

/* The formatting engine behind all of them. With sink NULL it formats into buf like vsnprintf. Otherwise buf (size
 * bytes) is a staging area and every full or final chunk goes to sink(ctx, data, n), which returns 0 or an errno value
 * to stop with. Returns the character count or -1 (errno set). */
typedef int (*moqi_sink_fn)(void *ctx, const char *data, size_t n);
int __moqi_vformat(char *buf, size_t size, moqi_sink_fn sink, void *ctx, const char *fmt, va_list ap);

/* Output (freestanding only — these issue the write syscall). */
void print(const char *s);
int  putchar(int c);   /* the byte written, or -1 */
int  puts(const char *s); /* length + 1 (the newline), or -1 */
int  printf(const char *fmt, ...);
int  vprintf(const char *fmt, va_list ap);
int  dprintf(int fd, const char *fmt, ...);
int  vdprintf(int fd, const char *fmt, va_list ap);

#endif /* MOQI_STDIO_H */
