/// hello52: ioperm (TSS I/O bitmap) end-to-end proof.
///
///   1. ioperm_set(0x70, 2, true) grants the RTC index/data ports.
///   2. outb(0x70, 0x00) + inb(0x71) reads RTC seconds — must be valid BCD
///      (<= 0x59, low nibble <= 9).
///   3. fork: the child inherits the permission — its RTC read works and it
///      exits 0.
///   4. ioperm_set(0x70, 2, false) revokes the ports; a forked child that
///      touches 0x71 must die on #GP. This kernel kills a user task on a
///      faulting exception with exit code 128 + vector (idt.zig
///      handleException → task.exitTask), and #GP is vector 13, so the
///      waitpid status must be exactly 141.
///   5. Range validation: port 65535 + count 2 overflows the 16-bit port
///      space → -EINVAL.
///
/// Prints "hello52: PASS" on success, "hello52: FAIL <tag>" + exit(1)
/// otherwise, and always ends with "hello52 done" on the success path.

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

#define SYS_IOPERM_SET 483

#define EINVAL 22

/* Exit status the kernel reports for a user task killed by #GP (vector 13):
   handleException → exitTask(128 + vector). */
#define EXIT_GP 141

#define RTC_INDEX 0x70
#define RTC_DATA  0x71
#define RTC_SEC   0x00

static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile ("outb %0, %1" :: "a"(val), "Nd"(port));
}

static inline uint8_t inb(uint16_t port) {
    uint8_t val;
    __asm__ volatile ("inb %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *tag) {
    print("hello52: FAIL ");
    print(tag);
    print("\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static int64_t ioperm_set(uint64_t port, uint64_t count, uint64_t enable) {
    return syscall3(SYS_IOPERM_SET, port, count, enable);
}

/* Read RTC seconds (BCD). Caller must hold the port permission. */
static uint8_t rtc_seconds(void) {
    outb(RTC_INDEX, RTC_SEC);
    return inb(RTC_DATA);
}

static int bcd_seconds_valid(uint8_t v) {
    return v <= 0x59 && (v & 0x0F) <= 9;
}

void _start(void) {
    /* 5. Range validation happens before any permission exists. */
    if (ioperm_set(65535, 2, 1) != -EINVAL)
        fail("range-overflow-not-einval");
    if (ioperm_set(0x70, 0, 1) != -EINVAL)
        fail("zero-count-not-einval");

    /* 1. Grant the RTC ports. */
    if (ioperm_set(RTC_INDEX, 2, 1) != 0)
        fail("ioperm_set-enable");

    /* 2. Read RTC seconds — must be valid BCD. */
    if (!bcd_seconds_valid(rtc_seconds()))
        fail("rtc-seconds-not-bcd");

    /* 3. fork: the child inherits the granted permission. */
    {
        int64_t child = syscall1(SYS_FORK, 0);
        if (child < 0)
            fail("fork-inherit");
        if (child == 0) {
            syscall1(SYS_EXIT, bcd_seconds_valid(rtc_seconds()) ? 0 : 3);
            for (;;) {}
        }
        int32_t status = -1;
        if (syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&status, 0) != child)
            fail("waitpid-inherit");
        if (status != 0)
            fail("child-inherit-read");
    }

    /* 4. Revoke, then a forked child touching the port must die on #GP. */
    if (ioperm_set(RTC_INDEX, 2, 0) != 0)
        fail("ioperm_set-disable");
    {
        int64_t child = syscall1(SYS_FORK, 0);
        if (child < 0)
            fail("fork-revoke");
        if (child == 0) {
            /* Must fault here; surviving the read is a failure. */
            (void)rtc_seconds();
            syscall1(SYS_EXIT, 2);
            for (;;) {}
        }
        int32_t status = -1;
        if (syscall3(SYS_WAITPID, (uint64_t)child, (uint64_t)&status, 0) != child)
            fail("waitpid-revoke");
        if (status != EXIT_GP)
            fail("revoked-port-not-gp");
    }

    print("hello52: PASS\n");
    print("hello52 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
