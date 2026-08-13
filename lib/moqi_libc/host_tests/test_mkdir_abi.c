#include <assert.h>

#include "../include/moqi_syscalls.h"
#include "../include/unistd.h"

int main(void) {
    long (*volatile mkdir_fn)(const char *, long) = mkdir;

    assert(mkdir_fn != 0);
    (void)mkdir_fn;
    assert(SYS_mkdir == 123);
    return 0;
}
