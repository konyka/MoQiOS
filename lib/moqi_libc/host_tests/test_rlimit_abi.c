#include <assert.h>
#include <stddef.h>

#include "../include/moqi_syscalls.h"
#include "../include/resource.h"

int main(void) {
    long (*volatile getrlimit_fn)(long, struct rlimit *) = getrlimit;
    long (*volatile setrlimit_fn)(long, const struct rlimit *) = setrlimit;
    long (*volatile prlimit64_fn)(long, long, const struct rlimit *,
                                  struct rlimit *) = prlimit64;

    assert(getrlimit_fn != 0);
    assert(setrlimit_fn != 0);
    assert(prlimit64_fn != 0);
    (void)getrlimit_fn;
    (void)setrlimit_fn;
    (void)prlimit64_fn;

    assert(SYS_getrlimit == 236);
    assert(SYS_setrlimit == 237);
    assert(SYS_prlimit64 == 238);

    assert(sizeof(struct rlimit) == 16);
    assert(offsetof(struct rlimit, rlim_cur) == 0);
    assert(offsetof(struct rlimit, rlim_max) == 8);

    assert(RLIMIT_NOFILE == 7);
    assert(RLIMIT_DATA == 2);
    assert(RLIMIT_NPROC == 6);
    assert(RLIMIT_STACK == 3);
    assert(RLIMIT_FSIZE == 1);
    assert(RLIMIT_RSS == 5);
    assert(RLIMIT_CPU == 0 && RLIMIT_MEMLOCK == 8 && RLIMIT_AS == 9 && RLIMIT_LOCKS == 10);
    assert(RLIMIT_SIGPENDING == 11 && RLIMIT_MSGQUEUE == 12 && RLIMIT_NICE == 13);
    assert(RLIMIT_RTPRIO == 14 && RLIMIT_RTTIME == 15);
    assert(RLIM_INFINITY == (rlim_t)~0ULL);
    return 0;
}
