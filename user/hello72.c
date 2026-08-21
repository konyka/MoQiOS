// hello72 - ioprio process ABI acceptance.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello72: FAIL " name "\n"); failures++; } } while (0)

/* Native dispatcher ABI requested for ioprio_set/get. */
#define SYS_ioprio_set 292
#define SYS_ioprio_get 293

#define WHO_PROCESS 1
#define WHO_PGRP 2
#define WHO_USER 3

#define IOPRIO_CLASS_RT 1
#define IOPRIO_CLASS_BE 2
#define IOPRIO_CLASS_IDLE 3

#define EINVAL 22
#define ENOSYS 38
#define ESRCH 3

static long ioprio(unsigned long io_class, unsigned long data) {
    return (long)((io_class << 13) | data);
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    print("hello72: start\n");

    const long default_prio = syscall2(SYS_ioprio_get, WHO_PROCESS, 0);
    CHECK(default_prio == ioprio(IOPRIO_CLASS_BE, 4),
          "process default is best-effort data4");

    CHECK(syscall3(SYS_ioprio_set, WHO_PROCESS, 0,
                   ioprio(IOPRIO_CLASS_BE, 2)) == 0,
          "process best-effort data2 set succeeds");
    const long roundtrip = syscall2(SYS_ioprio_get, WHO_PROCESS, 0);
    CHECK(roundtrip == ioprio(IOPRIO_CLASS_BE, 2),
          "process best-effort data2 roundtrip");

    const long invalid_values[] = {
        ioprio(0, 1),                    /* invalid class */
        ioprio(4, 0),                    /* reserved class */
        ioprio(IOPRIO_CLASS_IDLE, 1),    /* idle class carries no data */
    };
    for (unsigned long i = 0; i < sizeof(invalid_values) / sizeof(invalid_values[0]); i++) {
        CHECK(syscall3(SYS_ioprio_set, WHO_PROCESS, 0, invalid_values[i]) == -EINVAL,
              "invalid priority returns EINVAL");
        CHECK(syscall2(SYS_ioprio_get, WHO_PROCESS, 0) == roundtrip,
              "invalid priority preserves old value");
    }

    CHECK(syscall3(SYS_ioprio_set, WHO_PGRP, 0,
                   ioprio(IOPRIO_CLASS_BE, 2)) == -ENOSYS,
          "pgrp set is unsupported");
    CHECK(syscall2(SYS_ioprio_get, WHO_PGRP, 0) == -ENOSYS,
          "pgrp get is unsupported");
    CHECK(syscall3(SYS_ioprio_set, WHO_USER, 0,
                   ioprio(IOPRIO_CLASS_BE, 2)) == -ENOSYS,
          "user set is unsupported");
    CHECK(syscall2(SYS_ioprio_get, WHO_USER, 0) == -ENOSYS,
          "user get is unsupported");

    const unsigned long invalid_target = 0x7fffffffUL;
    CHECK(syscall3(SYS_ioprio_set, WHO_PROCESS, invalid_target,
                   ioprio(IOPRIO_CLASS_BE, 2)) == -ESRCH,
          "invalid process target set returns ESRCH");
    CHECK(syscall2(SYS_ioprio_get, WHO_PROCESS, invalid_target) == -ESRCH,
          "invalid process target get returns ESRCH");

    if (failures == 0) {
        print("hello72: PASS\nhello72 done\n");
        _exit(0);
    }
    print("hello72: FAIL\nhello72 done\n");
    _exit(1);
}
