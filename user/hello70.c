// hello70 - native AIO io_cancel unsupported-path acceptance.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello70: FAIL " name "\n"); failures++; } } while (0)

/* Native syscall ABI numbers used by this acceptance. The setup/destroy
 * numbers are documented here for ABI completeness; cancellation itself is
 * the unsupported operation under test and needs no live context. */
#define SYS_io_setup 206
#define SYS_io_destroy 207
#define SYS_io_submit 208
#define SYS_io_cancel 217
#define ENOSYS 38

struct iocb_sentinel {
    unsigned char bytes[64];
};

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    print("hello70: start\n");

    struct iocb_sentinel iocb;
    struct iocb_sentinel result;
    for (int i = 0; i < (int)sizeof(iocb.bytes); i++) {
        iocb.bytes[i] = (unsigned char)(0xa0 + i);
        result.bytes[i] = (unsigned char)(0x50 + i);
    }
    struct iocb_sentinel iocb_before = iocb;
    struct iocb_sentinel result_before = result;

    const long ret = syscall3(SYS_io_cancel, 0, (long)&iocb, (long)&result);
    CHECK(ret == -ENOSYS, "io_cancel without context returns ENOSYS");
    CHECK(__builtin_memcmp(&iocb, &iocb_before, sizeof(iocb)) == 0,
          "io_cancel leaves iocb unchanged");
    CHECK(__builtin_memcmp(&result, &result_before, sizeof(result)) == 0,
          "io_cancel leaves result unchanged");

    if (failures == 0) {
        print("hello70: PASS\nhello70 done\n");
        _exit(0);
    }
    print("hello70: FAIL\nhello70 done\n");
    _exit(1);
}
