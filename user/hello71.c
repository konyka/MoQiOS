// hello71 - mlock ABI rejection and MAP_FIXED metadata independence acceptance.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello71: FAIL " name "\n"); failures++; } } while (0)

#define SYS_mlock 252
#define SYS_munlock 253
#define SYS_mlockall 271
#define SYS_munlockall 272
#define ENOSYS 38

#define PAGE_SIZE 4096
#define PROT_RW 3
#define MAP_FIXED 0x10
#define MAP_PRIV_ANON 0x22
#define MCL_CURRENT 1
#define MCL_FUTURE 2

static long mmap_raw(long addr, long len, long prot, long flags, long fd, long off) {
    return syscall6(SYS_mmap, addr, len, prot, flags, fd, off);
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    print("hello71: start\n");

    long page = mmap_raw(0, PAGE_SIZE, PROT_RW, MAP_PRIV_ANON, -1, 0);
    CHECK(page > 0, "anonymous page mapped");
    if (page > 0) {
        volatile unsigned long *word = (volatile unsigned long *)page;
        *word = 0x68656c6c6f3731UL;

        CHECK(syscall2(SYS_mlock, page, PAGE_SIZE) == -ENOSYS,
              "mlock returns ENOSYS");
        CHECK(*word == 0x68656c6c6f3731UL, "mlock preserves sentinel");
        CHECK(syscall2(SYS_munlock, page, PAGE_SIZE) == -ENOSYS,
              "munlock returns ENOSYS");
        CHECK(*word == 0x68656c6c6f3731UL, "munlock preserves sentinel");
        CHECK(syscall1(SYS_mlockall, MCL_CURRENT | MCL_FUTURE) == -ENOSYS,
              "mlockall current future returns ENOSYS");
        CHECK(*word == 0x68656c6c6f3731UL, "mlockall preserves sentinel");
        CHECK(syscall0(SYS_munlockall) == -ENOSYS,
              "munlockall returns ENOSYS");
        CHECK(*word == 0x68656c6c6f3731UL, "munlockall preserves sentinel");

        const long replaced = mmap_raw(page, PAGE_SIZE, PROT_RW,
                                       MAP_PRIV_ANON | MAP_FIXED, -1, 0);
        CHECK(replaced == page, "MAP_FIXED anonymous replacement succeeds");
        if (replaced == page) {
            volatile unsigned long *new_word = (volatile unsigned long *)replaced;
            CHECK(*new_word == 0, "replacement zero-fills page");
            CHECK(syscall2(SYS_munmap, page, PAGE_SIZE) == 0, "cleanup replacement");
        }
    }

    if (failures == 0) {
        print("hello71: PASS\nhello71 done\n");
        _exit(0);
    }
    print("hello71: FAIL\nhello71 done\n");
    _exit(1);
}
