/* mman.h — POSIX/glibc-style memory-management calls over the MoQiOS system calls.
 *
 * Every function follows the glibc convention: success returns 0 (mmap/mremap: the address), failure returns -1
 * (MAP_FAILED) and stores the kernel's errno in errno. As in glibc, a kernel return value in [-4095, -1] is an
 * error and anything else is a result, so a mapping at a very high address is not mistaken for one.
 * Constants are Linux x86_64's. See docs/kernel-subsystems.md for what the kernel does with each call.
 */
#ifndef MOQI_MMAN_H
#define MOQI_MMAN_H

#include <stddef.h>

#include "errno.h"

#define PROT_NONE  0x0
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4

#define MAP_SHARED           0x1
#define MAP_PRIVATE          0x2
#define MAP_FIXED            0x10
#define MAP_ANONYMOUS        0x20
#define MAP_GROWSDOWN        0x100
#define MAP_LOCKED           0x2000
#define MAP_NORESERVE        0x4000
#define MAP_POPULATE         0x8000
#define MAP_NONBLOCK         0x10000
#define MAP_STACK            0x20000
#define MAP_FIXED_NOREPLACE  0x100000

#define MAP_FAILED ((void *)-1)

#define MREMAP_MAYMOVE 1
#define MREMAP_FIXED   2

#define MADV_NORMAL     0
#define MADV_RANDOM     1
#define MADV_SEQUENTIAL 2
#define MADV_WILLNEED   3
#define MADV_DONTNEED   4
#define MADV_FREE       8

#define MS_ASYNC      1
#define MS_INVALIDATE 2
#define MS_SYNC       4

#define MCL_CURRENT 1
#define MCL_FUTURE  2
#define MCL_ONFAULT 4

#define MLOCK_ONFAULT 1

void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
int munmap(void *addr, size_t length);
int mprotect(void *addr, size_t length, int prot);
int madvise(void *addr, size_t length, int advice);
int msync(void *addr, size_t length, int flags);
int mincore(void *addr, size_t length, unsigned char *vec);

/* The fifth argument is read only with MREMAP_FIXED (the new address), as in glibc. */
void *mremap(void *old_addr, size_t old_size, size_t new_size, int flags, ...);

int mlock(const void *addr, size_t length);
int mlock2(const void *addr, size_t length, unsigned int flags);
int munlock(const void *addr, size_t length);
int mlockall(int flags);
int munlockall(void);

#endif /* MOQI_MMAN_H */
