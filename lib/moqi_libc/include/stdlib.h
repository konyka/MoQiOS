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

void exit(int code) __attribute__((noreturn));

int atoi(const char *s);

/* getenv walks the process environment (environ, set by crt0 from the
 * initial stack) without any syscall. Returns a pointer into the
 * environ entry (do not free), or NULL if name is not present. */
char *getenv(const char *name);

#endif /* MOQI_STDLIB_H */
