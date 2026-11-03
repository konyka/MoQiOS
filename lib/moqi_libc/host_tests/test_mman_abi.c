#include <assert.h>
#include <stddef.h>
#include <stdint.h>

#include "../include/moqi_syscalls.h"
#include "../include/errno.h"
#include "../include/mman.h"

/* Recording stub for the syscall instruction: every call is logged, the reply is scripted. */
long stub_nr;
long stub_args[6];
int stub_calls;
long stub_reply;

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    stub_nr = nr;
    stub_args[0] = a1; stub_args[1] = a2; stub_args[2] = a3;
    stub_args[3] = a4; stub_args[4] = a5; stub_args[5] = a6;
    stub_calls++;
    return stub_reply;
}

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static void arm(long reply) {
    stub_calls = 0; stub_nr = -1; stub_reply = reply;
    for (int i = 0; i < 6; i++) stub_args[i] = -12345;
}

int main(void) {
    /* Constants are Linux x86_64's. */
    assert(PROT_NONE == 0 && PROT_READ == 1 && PROT_WRITE == 2 && PROT_EXEC == 4);
    assert(MAP_SHARED == 0x1 && MAP_PRIVATE == 0x2 && MAP_FIXED == 0x10 && MAP_ANONYMOUS == 0x20);
    assert(MAP_GROWSDOWN == 0x100 && MAP_LOCKED == 0x2000 && MAP_NORESERVE == 0x4000 && MAP_POPULATE == 0x8000);
    assert(MAP_NONBLOCK == 0x10000 && MAP_STACK == 0x20000 && MAP_FIXED_NOREPLACE == 0x100000);
    assert(MREMAP_MAYMOVE == 1 && MREMAP_FIXED == 2);
    assert(MADV_NORMAL == 0 && MADV_RANDOM == 1 && MADV_SEQUENTIAL == 2 && MADV_WILLNEED == 3);
    assert(MADV_DONTNEED == 4 && MADV_FREE == 8);
    assert(MS_ASYNC == 1 && MS_INVALIDATE == 2 && MS_SYNC == 4);
    assert(MCL_CURRENT == 1 && MCL_FUTURE == 2 && MCL_ONFAULT == 4 && MLOCK_ONFAULT == 1);
    assert(MAP_FAILED == (void *)-1);
    assert(EPERM == 1 && ENOMEM == 12 && EAGAIN == 11 && EINVAL == 22 && EFAULT == 14 && EACCES == 13);
    assert(EEXIST == 17 && ENODEV == 19 && ENOSYS == 38 && EBADF == 9 && EOVERFLOW == 75 && EOPNOTSUPP == 95);
    /* The system call numbers are the kernel's. */
    assert(SYS_mmap == 8 && SYS_munmap == 12 && SYS_mremap == 25 && SYS_mprotect == 164 && SYS_madvise == 235);
    assert(SYS_mincore == 251 && SYS_mlock == 252 && SYS_munlock == 253 && SYS_msync == 254);
    assert(SYS_mlockall == 271 && SYS_munlockall == 272 && SYS_mlock2 == 496);

    /* mmap: arguments in order, the address comes back, errno is left alone on success. */
    errno_slot = 77;
    arm(0x200000000L);
    void *p = mmap((void *)0x1000, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 4096);
    assert(p == (void *)0x200000000L && errno_slot == 77);
    assert(stub_nr == SYS_mmap && stub_args[0] == 0x1000 && stub_args[1] == 8192 && stub_args[2] == 3);
    assert(stub_args[3] == 0x22 && stub_args[4] == -1 && stub_args[5] == 4096);

    /* mmap failure: MAP_FAILED and errno from the kernel's -errno. */
    arm(-12);
    assert(mmap((void *)0, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED && errno == ENOMEM);
    arm(-11);
    assert(mmap((void *)0, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS | MAP_LOCKED, -1, 0) == MAP_FAILED && errno == EAGAIN);
    /* The error window is the last 4095 values, as in glibc: -4095 is an error, -4096 is an address. */
    arm(-4095);
    assert(mmap((void *)0, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED && errno == 4095);
    errno_slot = 5;
    arm(-4096);
    assert(mmap((void *)0, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == (void *)-4096L && errno_slot == 5);
    /* A high user address is not mistaken for an error. */
    arm(0x7fffffff0000L);
    assert(mmap((void *)0, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == (void *)0x7fffffff0000L);

    /* The integer calls: 0 on success with errno untouched; -1 and errno on failure. */
    errno_slot = 99;
    arm(0);
    assert(munmap((void *)0x5000, 12288) == 0 && errno_slot == 99);
    assert(stub_nr == SYS_munmap && stub_args[0] == 0x5000 && stub_args[1] == 12288);
    assert(mprotect((void *)0x5000, 4096, PROT_READ) == 0);
    assert(stub_nr == SYS_mprotect && stub_args[0] == 0x5000 && stub_args[1] == 4096 && stub_args[2] == 1);
    assert(madvise((void *)0x5000, 4096, MADV_DONTNEED) == 0);
    assert(stub_nr == SYS_madvise && stub_args[2] == 4);
    unsigned char vec[4];
    assert(mincore((void *)0x5000, 8192, vec) == 0);
    assert(stub_nr == SYS_mincore && stub_args[1] == 8192 && stub_args[2] == (long)(uintptr_t)vec);
    assert(msync((void *)0x5000, 4096, MS_SYNC) == 0);
    assert(stub_nr == SYS_msync && stub_args[2] == 4);
    assert(mlock((void *)0x5000, 4096) == 0);
    assert(stub_nr == SYS_mlock && stub_args[0] == 0x5000 && stub_args[1] == 4096);
    assert(munlock((void *)0x5000, 4096) == 0);
    assert(stub_nr == SYS_munlock);
    assert(mlock2((void *)0x5000, 4096, MLOCK_ONFAULT) == 0);
    assert(stub_nr == SYS_mlock2 && stub_args[2] == 1);
    assert(mlockall(MCL_CURRENT | MCL_FUTURE) == 0);
    assert(stub_nr == SYS_mlockall && stub_args[0] == 3);
    assert(munlockall() == 0);
    assert(stub_nr == SYS_munlockall);
    assert(errno_slot == 99);

    arm(-1);
    assert(mlock((void *)0x5000, 4096) == -1 && errno == EPERM);
    arm(-22);
    assert(mlockall(0) == -1 && errno == EINVAL);
    arm(-12);
    assert(munlock((void *)0x5000, 4096) == -1 && errno == ENOMEM);
    arm(-11);
    assert(mlockall(MCL_FUTURE) == -1 && errno == EAGAIN);
    arm(-14);
    assert(mincore((void *)0x5000, 4096, (unsigned char *)0) == -1 && errno == EFAULT);
    arm(-13);
    assert(mprotect((void *)0x5000, 4096, PROT_WRITE) == -1 && errno == EACCES);

    /* mremap is variadic like glibc's: the fifth argument is read only with MREMAP_FIXED. */
    errno_slot = 0;
    arm(0x300000000L);
    void *g = mremap((void *)0x200000000L, 4096, 8192, MREMAP_MAYMOVE);
    assert(g == (void *)0x300000000L && errno_slot == 0);
    assert(stub_nr == SYS_mremap && stub_args[0] == 0x200000000L && stub_args[1] == 4096 && stub_args[2] == 8192);
    assert(stub_args[3] == 1 && stub_args[4] == 0);
    /* Without MREMAP_FIXED an extra argument a caller happens to pass is ignored, never forwarded as the new address. */
    arm(0x300000000L);
    g = mremap((void *)0x200000000L, 4096, 8192, MREMAP_MAYMOVE, (void *)0xdead000L);
    assert(g == (void *)0x300000000L && stub_args[3] == 1 && stub_args[4] == 0);
    arm(0x400000000L);
    g = mremap((void *)0x200000000L, 4096, 8192, MREMAP_MAYMOVE | MREMAP_FIXED, (void *)0x400000000L);
    assert(g == (void *)0x400000000L && stub_args[3] == 3 && stub_args[4] == 0x400000000L);
    arm(-11);
    assert(mremap((void *)0x200000000L, 4096, 1 << 30, MREMAP_MAYMOVE) == MAP_FAILED && errno == EAGAIN);

    /* Nothing here keeps state between calls. */
    assert(stub_calls == 1);
    return 0;
}
