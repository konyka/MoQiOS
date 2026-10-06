/// hello103: CR4.UMIP blocks user-mode descriptor-table disclosure.
///
/// Without UMIP, ring 3 may execute sgdt/sidt/sldt/smsw/str and read the
/// kernel's GDT/IDT/TSS addresses and CR0 bits. With UMIP every one of them
/// raises #GP, which the kernel turns into process death with status
/// 128 + 13. Each instruction runs in its own forked child; a control child
/// that executes nothing privileged must still exit normally.

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

#define SYS_WRITE   1
#define SYS_EXIT    2
#define SYS_WAITPID 6
#define SYS_FORK    57

#define GP_STATUS (128 + 13)

enum probe { CONTROL, SGDT, SIDT, SLDT, SMSW, STR, NPROBES };

static const char *const names[NPROBES] = { "control", "sgdt", "sidt", "sldt", "smsw", "str" };

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

static __attribute__((noreturn)) void run_probe(enum probe p) {
    uint8_t table[10];
    uint16_t sel = 0;
    uint64_t msw = 0;
    switch (p) {
    case SGDT: __asm__ volatile ("sgdt %0" : "=m"(table)); break;
    case SIDT: __asm__ volatile ("sidt %0" : "=m"(table)); break;
    case SLDT: __asm__ volatile ("sldt %0" : "=m"(sel)); break;
    case SMSW: __asm__ volatile ("smsw %0" : "=r"(msw)); break;
    case STR:  __asm__ volatile ("str %0" : "=m"(sel)); break;
    default: break;
    }
    (void)msw;
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}

void _start(void) {
    print("hello103: UMIP descriptor-table instructions\n");
    int failures = 0;
    for (int p = 0; p < NPROBES; p++) {
        const int64_t pid = syscall1(SYS_FORK, 0);
        if (pid == 0) run_probe((enum probe)p);
        if (pid < 0) {
            print("hello103: FAIL fork\n");
            failures++;
            continue;
        }
        int status = -1;
        syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0);
        const int want = p == CONTROL ? 0 : GP_STATUS;
        print("hello103:   ");
        print(names[p]);
        print(" status=");
        print_dec(status);
        print("\n");
        if (status != want) {
            print("hello103: FAIL ");
            print(names[p]);
            print(p == CONTROL ? " control child did not exit cleanly\n" : " executed in user mode\n");
            failures++;
        }
    }
    print(failures == 0 ? "hello103: PASS\n" : "hello103: FAIL\n");
    print("hello103 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
