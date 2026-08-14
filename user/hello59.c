// hello59 — RLIMIT_STACK 执行语义验收测试（TDD 目标，见 docs/rlimit.md）。
// 覆盖：默认值上报、cur>max 拒绝（EINVAL）、软限下调与读回、prlimit64 读、
// fork 继承，以及真实执行：子进程把软/硬限压到 64 KiB 后无限递归，
// 必须被 SIGSEGV 杀死（waitpid 状态 128+11）。
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/resource.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello59: FAIL " name "\n"); failures++; } } while (0)

#define STACK_DEFAULT (8ULL * 1024 * 1024)
#define SIGSEGV_STATUS (128 + 11)

__attribute__((noinline)) static void recurse_forever(volatile unsigned long depth) {
    /* 每层带一个栈上缓冲区，确保帧足够大，快速越过 64 KiB 地板 */
    volatile char frame[256];
    frame[0] = (char)depth;
    frame[255] = frame[0];
    recurse_forever(depth + 1 + frame[255]);
    /* 调用返回后仍写帧：帧必须在递归调用期间存活，阻断尾调用优化 */
    frame[0] = frame[255];
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello59: start\n");

    /* 1. 默认值：8 MiB / 8 MiB */
    struct rlimit rl;
    CHECK(getrlimit(RLIMIT_STACK, &rl) == 0, "getrlimit default ok");
    CHECK(rl.rlim_cur == STACK_DEFAULT && rl.rlim_max == STACK_DEFAULT,
          "default 8MiB/8MiB");

    /* 2. cur > max → EINVAL(-22) */
    struct rlimit bad = { STACK_DEFAULT, 128 * 1024 };
    CHECK(setrlimit(RLIMIT_STACK, &bad) == -22, "cur>max EINVAL");

    /* 3. 下调软限到 256 KiB 并读回 */
    struct rlimit lower = { 256 * 1024, STACK_DEFAULT };
    CHECK(setrlimit(RLIMIT_STACK, &lower) == 0, "lower soft ok");
    CHECK(getrlimit(RLIMIT_STACK, &rl) == 0 && rl.rlim_cur == 256 * 1024 &&
          rl.rlim_max == STACK_DEFAULT, "readback lowered soft");

    /* 4. prlimit64 读取同值 */
    struct rlimit old;
    CHECK(prlimit64(0, RLIMIT_STACK, 0, &old) == 0 &&
          old.rlim_cur == 256 * 1024 && old.rlim_max == STACK_DEFAULT,
          "prlimit64 read");

    /* 5. fork 继承 + 真实执行：子进程压到 64 KiB 后递归 → SIGSEGV */
    long child = fork();
    if (child == 0) {
        struct rlimit crl;
        if (getrlimit(RLIMIT_STACK, &crl) != 0 || crl.rlim_cur != 256 * 1024)
            _exit(3); /* 未继承 */
        struct rlimit tiny = { 64 * 1024, 64 * 1024 };
        if (setrlimit(RLIMIT_STACK, &tiny) != 0)
            _exit(5);
        recurse_forever(0);
        _exit(7); /* 到达这里说明限制未执行 */
    }
    int st = 0;
    CHECK(waitpid(child, &st, 0) == child, "waitpid child");
    CHECK(st == SIGSEGV_STATUS, "child killed by SIGSEGV");

    /* 6. 父进程自身仍是 256 KiB 软限且栈可用 */
    CHECK(getrlimit(RLIMIT_STACK, &rl) == 0 && rl.rlim_cur == 256 * 1024,
          "parent limit intact");

    if (failures == 0) {
        print("hello59: PASS\n");
        exit(0);
    }
    print("hello59: FAIL\n");
    exit(1);
    return 1;
}
