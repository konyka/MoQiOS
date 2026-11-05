/* assert.h — assert and static_assert, with glibc's message and effect.
 *
 * A failed assert(expr) writes "<program>: <file>:<line>: <function>: Assertion `<expr>' failed." and a newline to the
 * standard error stream (unbuffered, so it appears at once) and calls abort(): the process dies of SIGABRT, no atexit
 * function runs and no FILE buffer is flushed. <program> is argv[0]'s last path component. With NDEBUG defined at the point
 * of inclusion assert expands to nothing, and its argument is not evaluated. This header may be included again after
 * changing NDEBUG, and each inclusion takes effect, as the C standard requires. static_assert is the C11 keyword.
 */
#undef assert

#ifdef NDEBUG
#define assert(expr) ((void)0)
#else
#ifndef MOQI_ASSERT_DECLARED
#define MOQI_ASSERT_DECLARED
void __assert_fail(const char *expr, const char *file, unsigned int line, const char *function) __attribute__((noreturn));
#endif
#define assert(expr) ((expr) ? (void)0 : __assert_fail(#expr, __FILE__, __LINE__, __func__))
#endif

#ifndef static_assert
#define static_assert _Static_assert
#endif
