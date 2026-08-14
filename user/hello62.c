// hello62 — 文件映射 fault-around（预缺页窗口）验收测试。
// 在 /tmp（tmpfs）造 256 KiB 已知模式文件，MAP_PRIVATE 只读映射后顺序扫描
// 校验每个字节——窗口跨越 4 个 64 KiB 区间，页内容错乱（页偏移错误）必现。
// 随后 MAP_SHARED 只读复核，并确认窗口外的页仍可独立缺页。
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/moqi_syscalls.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello62: FAIL " name "\n"); failures++; } } while (0)

#define PROT_READ_ 1
#define MAP_PRIV_ 0x02
#define MAP_SHAR_ 0x01
#define FILE_SIZE (256 * 1024)

static long mmap_raw(long addr, long len, long prot, long flags, long fd, long off) {
    return syscall6(SYS_mmap, addr, len, prot, flags, fd, off);
}
static long munmap_raw(long addr, long len) {
    return syscall2(SYS_munmap, addr, len);
}

static unsigned char pattern_at(long off) {
    return (unsigned char)((off * 131 + 7) & 0xFF);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello62: start\n");

    /* 1. 造文件：4 KiB 块写入已知模式 */
    long fd = open("/tmp/hello62.bin", O_WRONLY | O_CREAT, 0o644);
    CHECK(fd >= 0, "create tmpfs file");
    unsigned char wbuf[4096];
    for (long off = 0; off < FILE_SIZE; off += 4096) {
        for (long i = 0; i < 4096; i++) wbuf[i] = pattern_at(off + i);
        CHECK(write(fd, wbuf, 4096) == 4096, "write chunk");
    }
    close(fd);

    fd = open("/tmp/hello62.bin", O_RDONLY, 0);
    CHECK(fd >= 0, "reopen read");

    /* 2. MAP_PRIVATE 顺序扫描全量校验 */
    long m = mmap_raw(0, FILE_SIZE, PROT_READ_, MAP_PRIV_, fd, 0);
    CHECK(m > 0, "mmap private");
    if (m > 0) {
        volatile unsigned char *p = (volatile unsigned char *)m;
        long bad = -1;
        for (long off = 0; off < FILE_SIZE; off++) {
            if (p[off] != pattern_at(off)) { bad = off; break; }
        }
        CHECK(bad < 0, "private scan content");
        CHECK(munmap_raw(m, FILE_SIZE) == 0, "munmap private");
    }

    /* 3. MAP_SHARED 只读复核（窗口同样生效，共享帧零拷贝） */
    long ms = mmap_raw(0, FILE_SIZE, PROT_READ_, MAP_SHAR_, fd, 0);
    CHECK(ms > 0, "mmap shared");
    if (ms > 0) {
        volatile unsigned char *p = (volatile unsigned char *)ms;
        long bad = -1;
        for (long off = 0; off < FILE_SIZE; off += 1) {
            if (p[off] != pattern_at(off)) { bad = off; break; }
        }
        CHECK(bad < 0, "shared scan content");
        CHECK(munmap_raw(ms, FILE_SIZE) == 0, "munmap shared");
    }
    close(fd);

    if (failures == 0) {
        print("hello62: PASS\n");
        exit(0);
    }
    print("hello62: FAIL\n");
    exit(1);
    return 1;
}
