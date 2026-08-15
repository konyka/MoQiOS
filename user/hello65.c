// hello65 - bounded MAP_FIXED transactional replacement acceptance test.
// The test covers one-page anonymous replacement, RLIMIT_AS rollback on
// ENOMEM, preservation of the old mapping, and zero-fill after success.
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/resource.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello65: FAIL " name "\n"); failures++; } } while (0)

#define PAGE_SIZE 4096
#define PROT_RW 3
#define MAP_FIXED 0x10
#define MAP_PRIV_ANON 0x22

static long mmap_raw(long addr, long len, long prot, long flags, long fd, long off) {
    return syscall6(SYS_mmap, addr, len, prot, flags, fd, off);
}

static long munmap_raw(long addr, long len) {
    return syscall2(SYS_munmap, addr, len);
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    print("hello65: start\n");

    long page = mmap_raw(0, PAGE_SIZE, PROT_RW, MAP_PRIV_ANON, -1, 0);
    CHECK(page > 0, "anonymous page mapped");
    if (page > 0) {
        volatile unsigned long *word = (volatile unsigned long *)page;
        *word = 0x656c6c6f3635UL;

        CHECK(mmap_raw(0, PAGE_SIZE, PROT_RW, MAP_PRIV_ANON | MAP_FIXED, -1, 0) == -22,
              "fixed address zero EINVAL");
        CHECK(mmap_raw(page + 1, PAGE_SIZE, PROT_RW, MAP_PRIV_ANON | MAP_FIXED, -1, 0) == -22,
              "unaligned fixed address EINVAL");
        CHECK(*word == 0x656c6c6f3635UL, "invalid fixed requests preserved sentinel");

        struct rlimit low = { 1, RLIM_INFINITY };
        CHECK(setrlimit(RLIMIT_AS, &low) == 0, "lower AS limit");
        long denied = mmap_raw(page, PAGE_SIZE, PROT_RW,
                               MAP_PRIV_ANON | MAP_FIXED, -1, 0);
        CHECK(denied == -12, "equal-size fixed replacement ENOMEM");
        CHECK(*word == 0x656c6c6f3635UL, "failed replacement preserved sentinel");

        long unsupported = mmap_raw(page, PAGE_SIZE, 1, MAP_PRIV_ANON | MAP_FIXED, -1, 0);
        CHECK(unsupported == -12, "read-only fixed replacement rejected");
        CHECK(*word == 0x656c6c6f3635UL, "unsupported replacement preserved sentinel");

        struct rlimit unlimited = { RLIM_INFINITY, RLIM_INFINITY };
        CHECK(setrlimit(RLIMIT_AS, &unlimited) == 0, "restore AS limit");
        long replaced = mmap_raw(page, PAGE_SIZE, PROT_RW,
                                 MAP_PRIV_ANON | MAP_FIXED, -1, 0);
        CHECK(replaced == page, "fixed replacement succeeds");
        if (replaced == page) {
            volatile unsigned long *new_word = (volatile unsigned long *)replaced;
            CHECK(*new_word == 0, "replacement page is zero-filled");
        }
        CHECK(munmap_raw(page, PAGE_SIZE) == 0, "cleanup mapping");
    }

    if (failures == 0) {
        print("hello65: PASS\n");
        _exit(0);
    }
    print("hello65: FAIL\n");
    _exit(1);
    return 1;
}
