/* stdlib.h — stdlib-lite for MoQiOS user programs.
 *
 * malloc/free/calloc: first-fit free-list allocator over the kernel brk
 * syscall. exit() is _exit() (no atexit, no stdio flush).
 *
 * malloc/free/calloc are thread-safe but NOT async-signal-safe. A signal
 * handler that interrupts its own thread inside the allocator does not
 * deadlock: malloc/calloc return NULL, and free parks the pointer (up to
 * 8; beyond that it is leaked) until the interrupted call finishes. The
 * owner identity is the TCB at %fs:0, so raw CLONE_VM children without
 * CLONE_SETTLS (sharing the parent's FS) look like reentry, not contention.
 *
 * free() ignores pointers that are not the start of a live allocation
 * (double free, a block already merged into a neighbour, stack or
 * misaligned addresses) instead of corrupting the heap.
 */
#ifndef MOQI_STDLIB_H
#define MOQI_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void  free(void *ptr);
void *calloc(size_t nmemb, size_t size);

/* Failure is a NULL return with errno ENOMEM (an overflowing request, no memory, or a call from a signal handler that
 * interrupted the allocator). realloc keeps the original block when it fails, shrinks and grows in place when it can,
 * realloc(p, 0) frees and returns NULL, and realloc(NULL, n) is malloc(n); a pointer that is not a live allocation is
 * refused with EINVAL instead of corrupting the heap. posix_memalign returns the error (EINVAL for an alignment that is
 * not a power of two multiple of sizeof(void *), ENOMEM) and leaves *memptr and errno alone on failure. aligned_alloc
 * takes any power of two (EINVAL otherwise, size need not be a multiple); memalign also rounds a non-power-of-two up. */
void *realloc(void *ptr, size_t size);
void *reallocarray(void *ptr, size_t nmemb, size_t size);
int posix_memalign(void **memptr, size_t align, size_t size);
void *aligned_alloc(size_t align, size_t size);
void *memalign(size_t align, size_t size);

void exit(int code) __attribute__((noreturn));

int atoi(const char *s);
long atol(const char *s);
long long atoll(const char *s);

/* Number parsing with glibc's exact behavior: leading white space, an optional sign, base 0 picks 16/8/2/10 from a
 * 0x/0/0b prefix, a bare "0x" is the number 0 with the end pointer just after the 0, a result that does not fit is
 * the type's limit with errno ERANGE, a base outside 0 and 2..36 is EINVAL with the end pointer left alone, and
 * errno is otherwise not touched. The unsigned forms accept a minus sign and negate modulo 2^64 (but a magnitude too
 * large still fails). long and long long are the same width here, so the ll forms are the plain ones. */
long strtol(const char *s, char **end, int base);
unsigned long strtoul(const char *s, char **end, int base);
long long strtoll(const char *s, char **end, int base);
unsigned long long strtoull(const char *s, char **end, int base);

int abs(int x);
long labs(long x);
long long llabs(long long x);

typedef struct { int quot; int rem; } div_t;
typedef struct { long quot; long rem; } ldiv_t;
typedef struct { long long quot; long long rem; } lldiv_t;
div_t div(int num, int den);
ldiv_t ldiv(long num, long den);
lldiv_t lldiv(long long num, long long den);

/* glibc's random(3) generator (additive feedback, 31 lags): the same seed gives the same sequence as glibc. An
 * unseeded generator behaves as srand(1). Not thread-safe. */
#define RAND_MAX 2147483647
int rand(void);
void srand(unsigned seed);
/* POSIX's reentrant generator with glibc's exact output (three LCG steps combined into one value). */
int rand_r(unsigned *seed);

/* qsort is stable (equal elements keep their order), as glibc's merge sort is; it allocates a scratch copy of the array
 * with malloc and falls back to an in-place insertion sort, still stable, when that fails. bsearch probes the middle
 * ((lo + hi) / 2) first, so with duplicates it finds the same one glibc does. */
void qsort(void *base, size_t nmemb, size_t size, int (*cmp)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t nmemb, size_t size, int (*cmp)(const void *, const void *));

/* getenv walks the process environment (environ, set by crt0 from the
 * initial stack) without any syscall. Returns a pointer into the
 * environ entry (do not free), or NULL if name is not present. */
char *getenv(const char *name);

/* Environment changes with glibc's behavior. setenv copies name and value; an existing name is replaced only when
 * overwrite is non-zero. A name that is empty or contains '=' (or a NULL value) is EINVAL. putenv keeps the caller's
 * string itself in environ (changing it later changes the environment), replaces an entry of the same name, and a
 * string without '=' removes that name. unsetenv removes every entry of the name; clearenv empties the environment.
 * The array that arrives with the process is copied on the first insertion, never grown in place. Allocation failure
 * is ENOMEM with the environment unchanged. Replaced strings and old arrays are not freed, so a pointer from getenv
 * stays valid. Safe for concurrent callers with each other; getenv does not lock. */
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
int putenv(char *string);
int clearenv(void);

#endif /* MOQI_STDLIB_H */
