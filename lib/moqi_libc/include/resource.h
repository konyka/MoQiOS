/* resource.h — resource limit types and wrappers for moqi_libc.
 *
 * ABI matches the kernel (kernel/arch/x86_64/syscall_entry.zig): struct
 * rlimit is two little-endian u64 fields, RLIM_INFINITY is ~0ULL.
 * RLIMIT_NOFILE and RLIMIT_STACK are enforced by the kernel; the other
 * resources report fixed/stub values and setrlimit on them is a no-op.
 */
#ifndef MOQI_RESOURCE_H
#define MOQI_RESOURCE_H

#include "moqi_syscalls.h"

typedef unsigned long long rlim_t;

struct rlimit {
    rlim_t rlim_cur;
    rlim_t rlim_max;
};

#define RLIM_INFINITY ((rlim_t)~0ULL)

#define RLIMIT_FSIZE   1
#define RLIMIT_DATA    2
#define RLIMIT_STACK   3
#define RLIMIT_CORE    4
#define RLIMIT_RSS     5
#define RLIMIT_NPROC   6
#define RLIMIT_NOFILE  7
#define RLIMIT_AS      9

long getrlimit(long resource, struct rlimit *rlim);
long setrlimit(long resource, const struct rlimit *rlim);
long prlimit64(long pid, long resource, const struct rlimit *new_limit,
               struct rlimit *old_limit);

#endif /* MOQI_RESOURCE_H */
