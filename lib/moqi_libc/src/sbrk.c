/* sbrk.c — heap growth over the kernel brk syscall (freestanding only).
 *
 * Provides the strong __moqi_heap_grow() that src/malloc.c's weak hook
 * resolves to in user programs.
 */
#include "../include/unistd.h"

void *__moqi_heap_grow(size_t bytes) {
    void *old = sbrk((long)bytes);
    if (old == (void *)-1 || old == (void *)0) return (void *)0;
    return old;
}
