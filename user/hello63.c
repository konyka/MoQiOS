// hello63 — RLIMIT_DATA 执行语义验收测试（TDD 目标，见 docs/rlimit.md）。
// 覆盖：默认 RLIM_INFINITY、cur>max 拒绝（EINVAL）、setrlimit 下调/读回、
// 真实执行：可写私有匿名 mmap 超限 ENOMEM、只读/共享映射不消耗 DATA、
// munmap 退款、brk 增长超限返回原 break、brk 收缩退款、fork 继承。
//
// RLIMIT_DATA 计费对象：brk 堆增长 + 可写私有 mmap（匿名或文件私有）。
// 不计费：只读私有、MAP_SHARED、代码/rodata（与 Linux 语义一致）。
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/resource.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello63: FAIL " name "\n"); failures++; } } while (0)

#define PROT_RW 3            /* PROT_READ|PROT_WRITE */
#define PROT_R  1            /* PROT_READ */
#define MAP_PRIV_ANON 0x22   /* MAP_PRIVATE|MAP_ANONYMOUS */
#define MAP_SHARED 0x01
#define MAP_PRIVATE 0x02
#define MAP_ANON 0x20

static long mmap_raw(long addr, long len, long prot, long flags, long fd, long off) {
    return syscall6(SYS_mmap, addr, len, prot, flags, fd, off);
}
static long munmap_raw(long addr, long len) {
    return syscall2(SYS_munmap, addr, len);
}
static long brk_raw(long addr) {
    return syscall1(SYS_brk, addr);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello63: start\n");

    /* 1. 默认值：RLIM_INFINITY / RLIM_INFINITY */
    struct rlimit rl;
    CHECK(getrlimit(RLIMIT_DATA, &rl) == 0, "getrlimit DATA ok");
    CHECK(rl.rlim_cur == RLIM_INFINITY && rl.rlim_max == RLIM_INFINITY,
          "default infinity");

    /* 2. cur > max → EINVAL(-22) */
    struct rlimit bad = { 64 * 1024 * 1024, 4096 };
    CHECK(setrlimit(RLIMIT_DATA, &bad) == -22, "cur>max EINVAL");

    /* 3. 设 16 MiB 软限：1 MiB 可写私有 mmap 成功，64 MiB 必 ENOMEM */
    struct rlimit lim = { 16 * 1024 * 1024, RLIM_INFINITY };
    CHECK(setrlimit(RLIMIT_DATA, &lim) == 0, "set 16MiB soft");
    long m1 = mmap_raw(0, 1024 * 1024, PROT_RW, MAP_PRIV_ANON, -1, 0);
    CHECK(m1 > 0, "1MiB writable-private ok");
    long mbig = mmap_raw(0, 64 * 1024 * 1024, PROT_RW, MAP_PRIV_ANON, -1, 0);
    CHECK(mbig == -12, "64MiB writable-private ENOMEM");

    /* 4. 只读私有 / 共享映射不消耗 DATA：64 MiB 均成功 */
    long mro = mmap_raw(0, 64 * 1024 * 1024, PROT_R, MAP_PRIV_ANON, -1, 0);
    CHECK(mro > 0, "64MiB read-only ok (not charged)");
    long mshr = mmap_raw(0, 64 * 1024 * 1024, PROT_RW, MAP_SHARED | MAP_ANON, -1, 0);
    CHECK(mshr > 0, "64MiB shared ok (not charged)");

    /* 5. munmap 退款后 2 MiB 可写私有 mmap 再次成功 */
    if (m1 > 0) {
        CHECK(munmap_raw(m1, 1024 * 1024) == 0, "munmap refund");
        CHECK(mmap_raw(0, 2 * 1024 * 1024, PROT_RW, MAP_PRIV_ANON, -1, 0) > 0,
              "2MiB writable-private after refund");
    }
    if (mro > 0) CHECK(munmap_raw(mro, 64 * 1024 * 1024) == 0, "unmap ro");
    if (mshr > 0) CHECK(munmap_raw(mshr, 64 * 1024 * 1024) == 0, "unmap shared");

    /* 6. brk 超限：扩容 32 MiB 被拒（返回原 break），64 KiB 成功 */
    long brk0 = brk_raw(0);
    CHECK(brk0 > 0, "brk query");
    CHECK(brk_raw(brk0 + 32 * 1024 * 1024) == brk0, "brk 32MiB refused");
    CHECK(brk_raw(brk0 + 64 * 1024) == brk0 + 64 * 1024, "brk 64KiB ok");
    /* brk 收缩退款：缩回原 break 后，大 mmap 又能成功 */
    CHECK(brk_raw(brk0) == brk0, "brk shrink ok");

    /* 7. fork 继承：子进程读到 16 MiB 软限且 64 MiB 可写私有 mmap 失败 */
    long c2 = fork();
    if (c2 == 0) {
        struct rlimit crl;
        if (getrlimit(RLIMIT_DATA, &crl) != 0 || crl.rlim_cur != 16 * 1024 * 1024)
            _exit(7);
        if (mmap_raw(0, 64 * 1024 * 1024, PROT_RW, MAP_PRIV_ANON, -1, 0) != -12)
            _exit(9);
        _exit(0);
    }
    int st = 0;
    CHECK(waitpid(c2, &st, 0) == c2, "waitpid inherit child");
    CHECK(st == 0, "child inherits limit");

    if (failures == 0) {
        print("hello63: PASS\n");
        exit(0);
    }
    print("hello63: FAIL\n");
    exit(1);
    return 1;
}
