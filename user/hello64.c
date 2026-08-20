// hello64 — RLIMIT_NPROC 执行语义验收测试（TDD 目标，见 docs/rlimit.md）。
// 覆盖：默认 RLIM_INFINITY、cur>max 拒绝（EINVAL）、setrlimit 下调/读回、
// 真实执行闸点：把软限压到 1 后 fork 必须 EAGAIN（本进程自身已计入所属
// real UID 的活任务数，计数 >= 1，故 nproc_cur=1 时任何 fork 都必然拒绝，
// 与常驻服务数量无关）、恢复 INFINITY 后 fork 成功且子进程继承、子进程
// 退出后计数释放（父进程可再次成功 fork）。
//
// 注意：本测试只在自己的任务内降低 NPROC 软限并验证闸点行为；该限制是
// per-task 的，不影响 init 或其他 hello 测试的后续 spawn（它们各自保持
// 默认 INFINITY）。
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/resource.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello64: FAIL " name "\n"); failures++; } } while (0)

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello64: start\n");

    /* 1. 默认值：RLIM_INFINITY / RLIM_INFINITY */
    struct rlimit rl;
    CHECK(getrlimit(RLIMIT_NPROC, &rl) == 0, "getrlimit NPROC ok");
    CHECK(rl.rlim_cur == RLIM_INFINITY && rl.rlim_max == RLIM_INFINITY,
          "default infinity");

    /* 2. cur > max → EINVAL(-22) */
    struct rlimit bad = { 64, 4 };
    CHECK(setrlimit(RLIMIT_NPROC, &bad) == -22, "cur>max EINVAL");

    /* 3. 下调软限到 1（硬限保持 INFINITY）并读回。
     * 非特权进程无法提升硬限（Linux 语义），所以这里不动硬限，保证后续
     * 能把软限恢复回 INFINITY。 */
    struct rlimit one = { 1, RLIM_INFINITY };
    CHECK(setrlimit(RLIMIT_NPROC, &one) == 0, "set 1 soft");
    CHECK(getrlimit(RLIMIT_NPROC, &rl) == 0 && rl.rlim_cur == 1 &&
          rl.rlim_max == RLIM_INFINITY, "readback 1 soft");

    /* 4. 真实执行：软限=1 时 fork 必 EAGAIN。
     * 本进程自身是 UID 1000 且已计入该 UID 的活任务数，计数 >= 1，
     * 故 nproc_cur=1 使任何新任务创建都被拒绝（uid_count < cur 不成立）。 */
    long denied = fork();
    CHECK(denied == -11, "fork EAGAIN at nproc=1");

    /* 5. 恢复 INFINITY 后 fork 成功，子进程继承 INFINITY 并正常退出。 */
    struct rlimit inf = { RLIM_INFINITY, RLIM_INFINITY };
    CHECK(setrlimit(RLIMIT_NPROC, &inf) == 0, "restore infinity");
    long child = fork();
    if (child == 0) {
        struct rlimit crl;
        if (getrlimit(RLIMIT_NPROC, &crl) != 0 || crl.rlim_cur != RLIM_INFINITY)
            _exit(3); /* 未继承 */
        _exit(0);
    }
    CHECK(child > 0, "fork ok after restore");
    int st = 0;
    CHECK(waitpid(child, &st, 0) == child, "waitpid child");
    CHECK(st == 0, "child exits cleanly");

    /* 6. 子进程退出（被 reap）后计数释放：父进程再次 fork 成功。 */
    long again = fork();
    if (again == 0) {
        _exit(0);
    }
    CHECK(again > 0, "fork ok after child reaped");
    if (again > 0) {
        int st2 = 0;
        CHECK(waitpid(again, &st2, 0) == again, "waitpid second child");
        CHECK(st2 == 0, "second child clean");
    }

    if (failures == 0) {
        print("hello64: PASS\n");
        exit(0);
    }
    print("hello64: FAIL\n");
    exit(1);
    return 1;
}
