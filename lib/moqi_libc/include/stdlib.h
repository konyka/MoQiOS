/* stdlib.h — stdlib-lite for MoQiOS user programs.
 *
 * malloc/free/calloc: first-fit free-list allocator over the kernel brk
 * syscall. exit() is _exit() (no atexit, no stdio flush).
 */
#ifndef MOQI_STDLIB_H
#define MOQI_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void  free(void *ptr);
void *calloc(size_t nmemb, size_t size);

void exit(int code) __attribute__((noreturn));

int atoi(const char *s);

#endif /* MOQI_STDLIB_H */
