// hello61 — fork COW 事务化克隆回归测试（review §5.2t 后续）。
// 大页表规模（~96 MiB 匿名映射 → ~48 张 PT 页）下 fork：
// 子进程读共享页验证内容一致，写触发 COW 私有副本不污染父进程。
// 主要防守三阶段重构（计数/预分配/构建）的记账错误。
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/moqi_syscalls.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello61: FAIL " name "\n"); failures++; } } while (0)

#define PROT_RW 3
#define MAP_PRIV_ANON 0x22

static long mmap_raw(long addr, long len, long prot, long flags, long fd, long off) {
    return syscall6(SYS_mmap, addr, len, prot, flags, fd, off);
}
static long munmap_raw(long addr, long len) {
    return syscall2(SYS_munmap, addr, len);
}

#define SPAN (96 * 1024 * 1024)

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello61: start\n");

    long m = mmap_raw(0, SPAN, PROT_RW, MAP_PRIV_ANON, -1, 0);
    CHECK(m > 0, "96MiB mmap");
    if (m <= 0) {
        print("hello61: FAIL\n");
        exit(1);
    }
    volatile unsigned char *p = (volatile unsigned char *)m;
    /* 每 2 MiB 写一个标记字节（恰好每张 PT 页一个），强制全表建立 */
    for (long off = 0; off < SPAN; off += 2 * 1024 * 1024)
        p[off] = (unsigned char)(off >> 21);

    long child = fork();
    if (child == 0) {
        /* 子进程：读验证共享内容 */
        for (long off = 0; off < SPAN; off += 2 * 1024 * 1024) {
            if (p[off] != (unsigned char)(off >> 21)) _exit(3);
        }
        /* 写触发 COW：子进程私改 */
        for (long off = 0; off < SPAN; off += 2 * 1024 * 1024)
            p[off] = 0xFF;
        _exit(0);
    }
    int st = 0;
    CHECK(waitpid(child, &st, 0) == child, "waitpid");
    CHECK(st == 0, "child verify");

    /* 父进程不受子进程 COW 写影响 */
    int clean = 1;
    for (long off = 0; off < SPAN; off += 2 * 1024 * 1024) {
        if (p[off] != (unsigned char)(off >> 21)) clean = 0;
    }
    CHECK(clean, "parent pages intact after child COW writes");

    CHECK(munmap_raw(m, SPAN) == 0, "munmap");

    if (failures == 0) {
        print("hello61: PASS\n");
        exit(0);
    }
    print("hello61: FAIL\n");
    exit(1);
    return 1;
}
