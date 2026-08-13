/* rlimit.c — resource limit wrappers (see docs/rlimit.md). */
#include "../include/resource.h"

long getrlimit(long resource, struct rlimit *rlim) {
    return syscall2(SYS_getrlimit, resource, (long)rlim);
}

long setrlimit(long resource, const struct rlimit *rlim) {
    return syscall2(SYS_setrlimit, resource, (long)rlim);
}

long prlimit64(long pid, long resource, const struct rlimit *new_limit,
               struct rlimit *old_limit) {
    return syscall4(SYS_prlimit64, pid, resource, (long)new_limit,
                    (long)old_limit);
}
