// hello68 - observation-only resident RSS procfs telemetry acceptance test.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello68: FAIL " name "\n"); failures++; } } while (0)

#define PAGE_SIZE 4096
#define PROT_RW 3
#define MAP_PRIV_ANON 0x22

static int is_digit(char c) { return c >= '0' && c <= '9'; }

static unsigned long read_rss_kib(long pid) {
    char path[32] = "/proc/";
    int pos = 6;
    char digits[20];
    int n = 0;
    unsigned long value = (unsigned long)pid;
    if (value == 0) digits[n++] = '0';
    while (value > 0) {
        digits[n++] = (char)('0' + (value % 10));
        value /= 10;
    }
    while (n > 0) path[pos++] = digits[--n];
    path[pos++] = '/'; path[pos++] = 'r'; path[pos++] = 's'; path[pos++] = 's'; path[pos] = '\0';

    long fd = open(path, O_RDONLY, 0);
    if (fd < 0) return (unsigned long)-1;
    char buf[64];
    long count = read((int)fd, buf, sizeof(buf) - 1);
    close((int)fd);
    if (count <= 0) return (unsigned long)-1;
    buf[count] = '\0';
    const char *p = buf;
    const char *label = "VmRSS:\t";
    while (*label) { if (*p++ != *label++) return (unsigned long)-1; }
    unsigned long kib = 0;
    if (!is_digit(*p)) return (unsigned long)-1;
    while (is_digit(*p)) { kib = kib * 10 + (unsigned long)(*p++ - '0'); }
    return kib;
}

static long mmap_anon(void) {
    return syscall6(SYS_mmap, 0, PAGE_SIZE, PROT_RW, MAP_PRIV_ANON, -1, 0);
}

static long munmap_raw(long addr) { return syscall2(SYS_munmap, addr, PAGE_SIZE); }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello68: start\n");

    const long pid = getpid();
    const unsigned long baseline = read_rss_kib(pid);
    CHECK(baseline != (unsigned long)-1, "read baseline VmRSS");

    long page = mmap_anon();
    CHECK(page > 0, "anonymous page mapped");
    if (page > 0) {
        *(volatile unsigned char *)page = 0x68;
        const unsigned long after_map = read_rss_kib(pid);
        CHECK(after_map != (unsigned long)-1, "read mapped VmRSS");
        CHECK(after_map >= baseline + 4, "anonymous resident page grows VmRSS");
        CHECK(munmap_raw(page) == 0, "munmap resident page");
        const unsigned long after_unmap = read_rss_kib(pid);
        CHECK(after_unmap != (unsigned long)-1, "read unmapped VmRSS");
        CHECK(after_unmap <= after_map - 4, "munmap refunds observed VmRSS");
    }

    if (failures == 0) {
        print("hello68: PASS\nhello68 done\n");
        _exit(0);
    }
    print("hello68: FAIL\nhello68 done\n");
    _exit(1);
}
