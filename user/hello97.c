/// hello97: PCID no-flush CR3 vs. large-range TLB flush fallback (§6.46)
///
/// `flushLocal` degrades to a CR3 reload once a shootdown exceeds 32 pages
/// (mprotect commits the whole range, then issues ONE shootdownRange). A
/// review round suspected this reload degenerates to a no-op under
/// CR4.PCIDE = 1 because switchCr3's A→B→A fast path writes CR3 with the
/// no-flush bit (bit 63) set. That premise is FALSE: bit 63 is a write-only
/// command bit — "The instruction does not modify bit 63 of CR3, which is
/// reserved and always 0" (SDM vol. 3A, MOV to/from control registers) — so
/// the resident CR3 always reads back with bit 63 clear and the verbatim
/// reload stays a real flush of the current PCID's non-global entries.
/// Verified empirically under KVM (PCID live): readback after a no-flush
/// write returns bit 63 = 0, and this test passed UNCHANGED on the
/// pre-"fix" kernel. hello97 stays as the regression gate for that behavior.
///
/// Test shape (deterministic on SMP=1):
///   1. Map 64 pages (> the 32-page fallback threshold), touch them all so
///      the TLB holds writable entries.
///   2. Ping-pong with a child over pipes: each round-trip schedules
///      parent→child→parent with no intervening shootdown of this space, so
///      the switch back exercises the no-flush fast path (under PCID;
///      harmless legacy flush otherwise).
///   3. mprotect(range, PROT_READ) → one 64-page shootdown → flushLocal
///      fallback → CR3 reload.
///   4. Probe-write page 0. A REAL flush drops the writable entry: the write
///      faults and the SIGSEGV handler reports PASS. If the reload ever
///      degenerated to a no-op, the stale writable entry would let the write
///      land silently → FAIL.
///
/// Passes both with PCID off (TCG: legacy flushing reload) and on (KVM/real
/// hardware).

#include <stdint.h>

typedef int64_t s64;
typedef uint64_t u64;

static inline s64 syscall1(u64 nr, u64 a1) {
    s64 ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall2(u64 nr, u64 a1, u64 a2) {
    s64 ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall3(u64 nr, u64 a1, u64 a2, u64 a3) {
    s64 ret;
    register u64 rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall6(u64 nr, u64 a1, u64 a2, u64 a3, u64 a4, u64 a5, u64 a6) {
    s64 ret;
    register u64 rdx __asm__("rdx") = a3;
    register u64 r10 __asm__("r10") = a4;
    register u64 r8 __asm__("r8") = a5;
    register u64 r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_MMAP      8
#define SYS_READ      10
#define SYS_SIGACTION 13
#define SYS_PIPE      22
#define SYS_FORK      57
#define SYS_MPROTECT  164

#define SIGSEGV 11

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define PAGE  4096
#define NPAGES 64 /* > flushLocal's 32-page CR3-reload fallback threshold */
#define ROUNDS 8

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (u64)s, (u64)len);
}

struct ksigaction {
    void (*handler)(int);
    unsigned long mask;
    unsigned long flags;
    void *restorer;
};

static volatile int probe_armed;

static void segv_handler(int sig) {
    (void)sig;
    if (probe_armed) {
        /* The mprotect(PROT_READ) flush really invalidated the writable
         * TLB entries: the probe write faulted as required. */
        print("hello97: PASS (probe write faulted after 64-page PROT_READ flush)\n");
        print("hello97 done\n");
        syscall1(SYS_EXIT, 0);
    }
    print("hello97: FAIL (unexpected SIGSEGV)\n");
    print("hello97 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    print("hello97: PCID no-flush CR3 vs large-range flush fallback\n");

    struct ksigaction act = { segv_handler, 0, 0, 0 };
    if (syscall3(SYS_SIGACTION, SIGSEGV, (u64)&act, 0) != 0) {
        print("hello97: FAIL (sigaction)\n");
        print("hello97 done\n");
        syscall1(SYS_EXIT, 1);
    }

    int p2c[2] = { -1, -1 };
    int c2p[2] = { -1, -1 };
    if (syscall1(SYS_PIPE, (u64)p2c) < 0 || syscall1(SYS_PIPE, (u64)c2p) < 0) {
        print("hello97: FAIL (pipe)\n");
        print("hello97 done\n");
        syscall1(SYS_EXIT, 1);
    }

    const s64 child = syscall1(SYS_FORK, 0);
    if (child < 0) {
        print("hello97: FAIL (fork)\n");
        print("hello97 done\n");
        syscall1(SYS_EXIT, 1);
    }
    if (child == 0) {
        unsigned char b = 0;
        for (int i = 0; i < ROUNDS; i++) {
            if (syscall3(SYS_READ, (u64)p2c[0], (u64)&b, 1) != 1) syscall1(SYS_EXIT, 1);
            if (syscall3(SYS_WRITE, (u64)c2p[1], (u64)&b, 1) != 1) syscall1(SYS_EXIT, 1);
        }
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }

    const s64 base = syscall6(SYS_MMAP, 0, NPAGES * PAGE, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, (u64)-1, 0);
    if (base <= 0) {
        print("hello97: FAIL (mmap)\n");
        print("hello97 done\n");
        syscall1(SYS_EXIT, 1);
    }

    /* Populate writable TLB entries for the whole range. */
    for (int i = 0; i < NPAGES; i++)
        *(volatile u64 *)((u64)base + (u64)i * PAGE) = 0x9700 + (u64)i;

    /* parent→child→parent round-trips: the switch back into this space takes
     * the PCID no-flush fast path (no intervening shootdown of this space),
     * leaving CR3 bit 63 resident when PCID is active. */
    unsigned char token = 0xA5;
    for (int i = 0; i < ROUNDS; i++) {
        if (syscall3(SYS_WRITE, (u64)p2c[1], (u64)&token, 1) != 1) {
            print("hello97: FAIL (ping write)\n");
            print("hello97 done\n");
            syscall1(SYS_EXIT, 1);
        }
        if (syscall3(SYS_READ, (u64)c2p[0], (u64)&token, 1) != 1) {
            print("hello97: FAIL (pong read)\n");
            print("hello97 done\n");
            syscall1(SYS_EXIT, 1);
        }
    }

    /* One 64-page shootdown → flushLocal's CR3-reload fallback. */
    if (syscall3(SYS_MPROTECT, (u64)base, NPAGES * PAGE, PROT_READ) != 0) {
        print("hello97: FAIL (mprotect)\n");
        print("hello97 done\n");
        syscall1(SYS_EXIT, 1);
    }

    probe_armed = 1;
    *(volatile u64 *)(u64)base = 0xDEAD;

    /* Reaching here means the write landed through a STALE writable TLB
     * entry: the CR3-reload fallback invalidated nothing. */
    print("hello97: FAIL (stale writable TLB entry survived 64-page flush)\n");
    print("hello97 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}
