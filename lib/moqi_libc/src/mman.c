/* mman.c — memory-management wrappers (see include/mman.h). */
#include <stdarg.h>

#include "../include/moqi_syscalls.h"
#include "../include/mman.h"

/* The host unit test links this file against a recording stub instead of the real `syscall` instruction. */
#ifdef MOQI_HOST_TEST_SYSCALL
extern long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6);
#define MM_SYSCALL6(nr, a1, a2, a3, a4, a5, a6) moqi_test_syscall6((nr), (a1), (a2), (a3), (a4), (a5), (a6))
#else
#define MM_SYSCALL6(nr, a1, a2, a3, a4, a5, a6) syscall6((nr), (a1), (a2), (a3), (a4), (a5), (a6))
#endif

#define MM_ERROR_WINDOW 4095

static long mm_call(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    return MM_SYSCALL6(nr, a1, a2, a3, a4, a5, a6);
}

static int mm_is_error(long ret) {
    return (unsigned long)ret > (unsigned long)-MM_ERROR_WINDOW - 1;
}

static int mm_int(long ret) {
    if (mm_is_error(ret)) {
        errno = (int)-ret;
        return -1;
    }
    return 0;
}

static void *mm_ptr(long ret) {
    if (mm_is_error(ret)) {
        errno = (int)-ret;
        return MAP_FAILED;
    }
    return (void *)ret;
}

void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset) {
    return mm_ptr(mm_call(SYS_mmap, (long)addr, (long)length, prot, flags, fd, offset));
}

int munmap(void *addr, size_t length) {
    return mm_int(mm_call(SYS_munmap, (long)addr, (long)length, 0, 0, 0, 0));
}

int mprotect(void *addr, size_t length, int prot) {
    return mm_int(mm_call(SYS_mprotect, (long)addr, (long)length, prot, 0, 0, 0));
}

int madvise(void *addr, size_t length, int advice) {
    return mm_int(mm_call(SYS_madvise, (long)addr, (long)length, advice, 0, 0, 0));
}

int msync(void *addr, size_t length, int flags) {
    return mm_int(mm_call(SYS_msync, (long)addr, (long)length, flags, 0, 0, 0));
}

int mincore(void *addr, size_t length, unsigned char *vec) {
    return mm_int(mm_call(SYS_mincore, (long)addr, (long)length, (long)vec, 0, 0, 0));
}

void *mremap(void *old_addr, size_t old_size, size_t new_size, int flags, ...) {
    long new_addr = 0;
    if (flags & MREMAP_FIXED) {
        va_list ap;
        va_start(ap, flags);
        new_addr = (long)va_arg(ap, void *);
        va_end(ap);
    }
    return mm_ptr(mm_call(SYS_mremap, (long)old_addr, (long)old_size, (long)new_size, flags, new_addr, 0));
}

int mlock(const void *addr, size_t length) {
    return mm_int(mm_call(SYS_mlock, (long)addr, (long)length, 0, 0, 0, 0));
}

int mlock2(const void *addr, size_t length, unsigned int flags) {
    return mm_int(mm_call(SYS_mlock2, (long)addr, (long)length, (long)flags, 0, 0, 0));
}

int munlock(const void *addr, size_t length) {
    return mm_int(mm_call(SYS_munlock, (long)addr, (long)length, 0, 0, 0, 0));
}

int mlockall(int flags) {
    return mm_int(mm_call(SYS_mlockall, flags, 0, 0, 0, 0, 0));
}

int munlockall(void) {
    return mm_int(mm_call(SYS_munlockall, 0, 0, 0, 0, 0, 0));
}
