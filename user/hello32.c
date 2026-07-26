/// hello32: synchronous SIGSEGV delivery and NX enforcement after fork
///
/// Before this pass the page-fault path always killed the process, so a
/// registered SIGSEGV handler was never reached from a fault. hello31 needed
/// sched_yield but could not assert "execute from a data page faults" because
/// any fault printed [SEGFAULT] and failed the smoke gate.
///
/// Part A: child registers a handler and touches address 0; the handler exits
/// cleanly instead of returning to the faulting instruction.
/// Part B: child maps a writable anonymous page and tries to execute from it;
/// with NX enforced this is an instruction-fetch fault delivered as SIGSEGV.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
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

#define SYS_WRITE      1
#define SYS_EXIT       2
#define SYS_FORK       57
#define SYS_WAITPID    6
#define SYS_MMAP       8
#define SYS_SIGACTION  13

#define SIGSEGV 11

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define PAGE 4096

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, len);
}

struct ksigaction {
    void (*handler)(int);
    unsigned long mask;
    unsigned long flags;
    void *restorer;
};

static volatile int handler_phase;

static void segv_handler(int sig) {
    (void)sig;
    if (handler_phase == 1) {
        print("hello32: null fault handler ok\n");
        syscall1(SYS_EXIT, 0);
    } else if (handler_phase == 2) {
        print("hello32: NX exec fault handler ok\n");
        syscall1(SYS_EXIT, 0);
    } else {
        print("hello32: unexpected handler phase\n");
        syscall1(SYS_EXIT, 1);
    }
    for (;;) {}
}

static int register_segv(void) {
    struct ksigaction act = { segv_handler, 0, 0, 0 };
    return syscall3(SYS_SIGACTION, SIGSEGV, (uint64_t)&act, 0) == 0 ? 0 : 1;
}

static int test_null_fault(void) {
    const int64_t child = syscall1(SYS_FORK, 0);
    if (child < 0) return 1;
    if (child == 0) {
        if (register_segv() != 0) syscall1(SYS_EXIT, 1);
        handler_phase = 1;
        volatile int *p = (volatile int *)0;
        *p = 1;
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }
    int64_t status = 0;
    syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);
    return status != 0 ? 1 : 0;
}

static int test_nx_exec_fault(void) {
    const int64_t child = syscall1(SYS_FORK, 0);
    if (child < 0) return 1;
    if (child == 0) {
        if (register_segv() != 0) syscall1(SYS_EXIT, 1);
        const int64_t page = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                      MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (page <= 0) syscall1(SYS_EXIT, 1);
        volatile unsigned char *code = (volatile unsigned char *)page;
        code[0] = 0xC3; /* ret */
        handler_phase = 2;
        void (*fn)(void) = (void (*)(void))page;
        fn();
        syscall1(SYS_EXIT, 1);
        for (;;) {}
    }
    int64_t status = 0;
    syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);
    return status != 0 ? 1 : 0;
}

void _start(void) {
    print("hello32: SIGSEGV test\n");

    int failures = 0;
    if (test_null_fault() != 0) {
        print("hello32: FAIL (null fault)\n");
        failures++;
    }
    if (test_nx_exec_fault() != 0) {
        print("hello32: FAIL (NX exec fault)\n");
        failures++;
    }

    if (failures == 0) {
        print("hello32: SIGSEGV PASS\n");
    } else {
        print("hello32: SIGSEGV FAIL\n");
    }

    print("hello32 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
