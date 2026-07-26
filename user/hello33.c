/// hello33: a syscall must not write to a read-only user page
///
/// The kernel validated a syscall's destination buffer by asking only whether
/// the page belonged to user space, never whether it could be written. A
/// read-only page therefore passed validation, and the kernel's own copy then
/// took a supervisor-mode write-protect fault — a path with no recovery, which
/// brings the machine down. Any process can arrange one with mmap(PROT_READ).
///
/// Each destination is tried in its own forked child: a successful write into
/// text or rodata corrupts the caller, so sharing one process between the
/// cases would make every result after the first unreliable.
///
/// Child exit codes: 0 = rejected (good), 1 = write went through, 2 = setup
/// failed / inconclusive.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE   1
#define SYS_EXIT    2
#define SYS_WAITPID 6
#define SYS_MMAP    8
#define SYS_OPEN    9
#define SYS_READ    10
#define SYS_CLOSE   11
#define SYS_FORK    57

#define PROT_READ     0x1
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20
#define PAGE          4096

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

static void print_dec(int64_t v) {
    char buf[24];
    int pos = 0;
    if (v < 0) { print("-"); v = -v; }
    if (v == 0) { print("0"); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char t = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = t; }
    syscall3(SYS_WRITE, 1, (uint64_t)buf, pos);
}

static const char ro_area[64] = "this string should live in read-only memory";

enum { DEST_RODATA = 0, DEST_TEXT = 1, DEST_MMAP_RO = 2, PROBE_USER_WRITE = 3 };

/// Runs in the child. Never returns.
static void attempt(int which) {
    uint64_t dest = 0;
    if (which == PROBE_USER_WRITE) {
        /// Establishes whether mmap(PROT_READ) really produces a read-only
        /// page. If it does, this store faults and the child never exits 1.
        const int64_t page = syscall6(SYS_MMAP, 0, PAGE, PROT_READ,
                                      MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (page <= 0) syscall1(SYS_EXIT, 2);
        *(volatile char *)page = 'x';
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }
    if (which == DEST_RODATA) {
        dest = (uint64_t)ro_area;
    } else if (which == DEST_TEXT) {
        dest = (uint64_t)(void *)&print;
    } else {
        const int64_t page = syscall6(SYS_MMAP, 0, PAGE, PROT_READ,
                                      MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (page <= 0) syscall1(SYS_EXIT, 2);
        dest = (uint64_t)page;
    }

    /// Snapshot the destination so the verdict rests on whether the bytes
    /// actually changed. The return value alone is not evidence: a kernel that
    /// credits bytes it never copied would report success either way.
    char before[7];
    for (int i = 0; i < 7; i++) before[i] = ((volatile const char *)dest)[i];

    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/h33.txt", 0, 0);
    if (fd < 0) syscall1(SYS_EXIT, 2);
    syscall3(SYS_READ, (uint64_t)fd, dest, 7);
    syscall1(SYS_CLOSE, (uint64_t)fd);

    for (int i = 0; i < 7; i++) {
        if (((volatile const char *)dest)[i] != before[i]) syscall1(SYS_EXIT, 1);
    }
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

/// Returns the child's exit code, or -1 if it could not be run.
static int64_t run_case(int which, const char *label) {
    const int64_t child = syscall1(SYS_FORK, 0);
    if (child < 0) return -1;
    if (child == 0) attempt(which);

    int64_t status = 0;
    syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);

    print("hello33:   ");
    print(label);
    print("=");
    if (which == PROBE_USER_WRITE) {
        /// 128 + SIGSEGV. Anything else means the page took the store, and the
        /// cases below would be measuring nothing.
        print(status == 139 ? "SIGSEGV (page is read-only)\n"
                            : "UNPROTECTED — later cases prove nothing\n");
    } else if (status == 0) {
        print("rejected\n");
    } else if (status == 1) {
        print("WRITTEN\n");
    } else {
        print("inconclusive (");
        print_dec(status);
        print(")\n");
    }
    return status;
}

void _start(void) {
    print("hello33: read-only destination test\n");

    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)"/tmp/h33.txt", 0x41, 0);
    if (fd < 0) {
        print("hello33: SKIP (cannot create file)\n");
        print("hello33 done\n");
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
    syscall3(SYS_WRITE, (uint64_t)fd, (uint64_t)"payload", 7);
    syscall1(SYS_CLOSE, (uint64_t)fd);

    /// Establishes the premise: a store the process makes itself must fault,
    /// otherwise "the kernel declined to write" would prove nothing.
    print("hello33: premise check\n");
    const int premise_ok = run_case(PROBE_USER_WRITE, "user_store") == 139;

    int written = 0;
    if (run_case(DEST_MMAP_RO, "mmap_ro") == 1) written++;
    if (run_case(DEST_RODATA, "rodata") == 1) written++;
    if (run_case(DEST_TEXT, "text") == 1) written++;

    if (!premise_ok) {
        print("hello33: FAIL (read-only pages are not enforced at all)\n");
    } else if (written == 0) {
        print("hello33: PASS (no read-only destination accepted)\n");
    } else {
        print("hello33: FAIL (kernel wrote to a read-only page)\n");
    }

    print("hello33 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
