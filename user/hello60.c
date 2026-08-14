// hello60 — RLIMIT_AS 执行语义验收测试（TDD 目标，见 docs/rlimit.md）。
// 覆盖：默认 RLIM_INFINITY、cur>max 拒绝、mmap/brk 超限失败与退款、
// fork 继承，以及真实执行：子进程压小 AS 软限后递归耗尽栈计费 → SIGSEGV。
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/resource.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello60: FAIL " name "\n"); failures++; } } while (0)

#define PROT_RW 3            /* PROT_READ|PROT_WRITE */
#define MAP_PRIV_ANON 0x22   /* MAP_PRIVATE|MAP_ANONYMOUS */
#define SIGSEGV_STATUS (128 + 11)

static long mmap_raw(long addr, long len, long prot, long flags, long fd, long off) {
    return syscall6(SYS_mmap, addr, len, prot, flags, fd, off);
}
static long munmap_raw(long addr, long len) {
    return syscall2(SYS_munmap, addr, len);
}
static long brk_raw(long addr) {
    return syscall1(SYS_brk, addr);
}

__attribute__((noinline)) static void recurse_forever(volatile unsigned long depth) {
    volatile char frame[256];
    frame[0] = (char)depth;
    frame[255] = frame[0];
    recurse_forever(depth + 1 + frame[255]);
    frame[0] = frame[255]; /* 阻断尾调用优化 */
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello60: start\n");

    /* 1. 默认值：RLIM_INFINITY / RLIM_INFINITY */
    struct rlimit rl;
    CHECK(getrlimit(RLIMIT_AS, &rl) == 0, "getrlimit AS ok");
    CHECK(rl.rlim_cur == RLIM_INFINITY && rl.rlim_max == RLIM_INFINITY,
          "default infinity");

    /* 2. cur > max → EINVAL(-22) */
    struct rlimit bad = { 64 * 1024 * 1024, 4096 };
    CHECK(setrlimit(RLIMIT_AS, &bad) == -22, "cur>max EINVAL");

    /* 3. 子进程栈计费执行：软限压到 1 MiB 后递归 → SIGSEGV */
    long c1 = fork();
    if (c1 == 0) {
        struct rlimit tiny = { 1024 * 1024, RLIM_INFINITY };
        if (setrlimit(RLIMIT_AS, &tiny) != 0) _exit(3);
        recurse_forever(0);
        _exit(5); /* 到达这里说明栈计费未执行 */
    }
    int st = 0;
    CHECK(waitpid(c1, &st, 0) == c1, "waitpid stack child");
    CHECK(st == SIGSEGV_STATUS, "stack charge SIGSEGV");

    /* 4. 父进程设 16 MiB 软限：1 MiB mmap 成功，64 MiB mmap 必 ENOMEM */
    struct rlimit lim = { 16 * 1024 * 1024, RLIM_INFINITY };
    CHECK(setrlimit(RLIMIT_AS, &lim) == 0, "set 16MiB soft");
    long m1 = mmap_raw(0, 1024 * 1024, PROT_RW, MAP_PRIV_ANON, -1, 0);
    CHECK(m1 > 0, "1MiB mmap ok");
    long mbig = mmap_raw(0, 64 * 1024 * 1024, PROT_RW, MAP_PRIV_ANON, -1, 0);
    CHECK(mbig == -12, "64MiB mmap ENOMEM");

    /* 5. munmap 退款后 2 MiB mmap 再次成功 */
    if (m1 > 0) {
        CHECK(munmap_raw(m1, 1024 * 1024) == 0, "munmap refund");
        CHECK(mmap_raw(0, 2 * 1024 * 1024, PROT_RW, MAP_PRIV_ANON, -1, 0) > 0,
              "2MiB mmap after refund");
    }

    /* 6. brk 超限：扩容 32 MiB 被拒（返回原 break），64 KiB 成功 */
    long brk0 = brk_raw(0);
    CHECK(brk0 > 0, "brk query");
    CHECK(brk_raw(brk0 + 32 * 1024 * 1024) == brk0, "brk 32MiB refused");
    CHECK(brk_raw(brk0 + 64 * 1024) == brk0 + 64 * 1024, "brk 64KiB ok");

    /* 7. fork 继承：子进程读到 16 MiB 软限且 64 MiB mmap 失败 */
    long c2 = fork();
    if (c2 == 0) {
        struct rlimit crl;
        if (getrlimit(RLIMIT_AS, &crl) != 0 || crl.rlim_cur != 16 * 1024 * 1024)
            _exit(7);
        if (mmap_raw(0, 64 * 1024 * 1024, PROT_RW, MAP_PRIV_ANON, -1, 0) != -12)
            _exit(9);
        _exit(0);
    }
    st = 0;
    CHECK(waitpid(c2, &st, 0) == c2, "waitpid inherit child");
    CHECK(st == 0, "child inherits limit");

    if (failures == 0) {
        print("hello60: PASS\n");
        exit(0);
    }
    print("hello60: FAIL\n");
    exit(1);
    return 1;
}
