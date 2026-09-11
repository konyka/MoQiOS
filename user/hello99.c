/// hello99: PROT_NONE reservation vs swap-entry encoding collision (§6.48).
///
/// mprotect(PROT_NONE) clears present but preserves the physical frame and
/// every permission bit so a later mprotect can restore the mapping in place.
/// The pre-fix swap encoding marked swap entries with bit 1 — which a
/// reservation of a formerly WRITABLE page also has set — so a fault on a
/// reservation was misclassified as a swap-in: the frame number was read as a
/// disk slot and garbage was mapped over the address (silent corruption), and
/// mprotect's swapEntryUpdate hijacked every PROT_NONE → PROT_RW restore,
/// leaving the mapping dead. The fix gives each encoding its own
/// OS-available marker bit (swap = bit 11, reservation = bit 10) and a single
/// classifier (mm/pte_kind.zig).
///
/// Probes (run twice: bare, then under armed swap + reclaim-floor pressure):
///   A. syscall user-copy on a reservation must be refused — a short write
///      as a read source (write), EFAULT as a write destination (pipe read) —
///      and the failed read must consume nothing.
///   B. a user-mode access must SIGSEGV — the handler repairs the page so the
///      retry succeeds and proves the original frame survived (no phantom
///      swap-in). A fresh mmap must also never land on the reserved address.
///   C. PROT_NONE → PROT_RW with no fault in between must restore the mapping
///      with the original contents (the deterministic pre-fix regression).
///   D. a 2 MiB huge-backed block: full-range PROT_NONE faults with SIGSEGV
///      and full-range repair preserves every written page.
///   E. (swap phase only) eight pattern pages held as reservations across a
///      >64 MiB sliding-window churn that forces real swap reclaim, then
///      restored and verified word for word.

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
#define SYS_MMAP      8
#define SYS_READ      10
#define SYS_MUNMAP    12
#define SYS_SIGACTION 13
#define SYS_PIPE      22
#define SYS_SYSINFO   99
#define SYS_MPROTECT  164
#define SYS_SWAPON    318
#define SYS_SWAPOFF   319
#define SYS_PMM_SET_RECLAIM_FLOOR 485

#define SIGSEGV 11
#define EFAULT  14

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define PROT_RW       (PROT_READ | PROT_WRITE)
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define PAGE          4096UL
#define HUGE_LEN      (2 * 1024 * 1024)
#define NRESERVED     8
#define CHURN_WINDOW  80   /* 80 MiB live > 64 MiB margin → reclaim fires */
#define CHURN_ROUNDS  120
#define MARGIN_PAGES  16384 /* 64 MiB, mirrors hello96 */

static void print(const char *s) {
    u64 n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (u64)s, n);
}

struct ksigaction {
    void (*handler)(int);
    unsigned long mask;
    unsigned long flags;
    void *restorer;
};

static s64 saved_floor = -1;
static int swap_armed = 0;

static void cleanup(void) {
    if (saved_floor >= 0) {
        syscall1(SYS_PMM_SET_RECLAIM_FLOOR, (u64)saved_floor);
        saved_floor = -1;
    }
    if (swap_armed) {
        syscall3(SYS_SWAPOFF, (u64)"/dev/sda", 0, 0);
        swap_armed = 0;
    }
}

__attribute__((noreturn)) static void fail_exit(const char *tag) {
    print("hello99: FAIL ");
    print(tag);
    print("\n");
    cleanup();
    print("hello99 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

static volatile int expect_segv;   /* probe armed: a SIGSEGV is required */
static volatile int segv_seen;
static volatile u64 repair_page;   /* range the handler re-permits so the */
static volatile u64 repair_len;    /* faulting instruction's retry succeeds */

static void segv_handler(int sig) {
    (void)sig;
    if (expect_segv) {
        segv_seen = 1;
        syscall3(SYS_MPROTECT, repair_page, repair_len, PROT_RW);
        return;
    }
    fail_exit("unexpected SIGSEGV (restore left the mapping dead?)");
}

static u64 pat(u64 phase, u64 idx) {
    return 0x9900000000000000UL | (phase << 24) | (idx * 0x9E3779B97F4A7C15UL);
}

static s64 mmap_anon(u64 len) {
    return syscall6(SYS_MMAP, 0, len, PROT_RW, MAP_PRIVATE | MAP_ANONYMOUS, (u64)-1, 0);
}

static int failures = 0;

static void check(int ok, const char *name) {
    if (!ok) {
        print("hello99: FAIL ");
        print(name);
        print("\n");
        failures++;
    }
}

/* Probe A: syscall user-copy against a reservation → EFAULT, nothing consumed. */
static void probe_efault(u64 phase) {
    const s64 a = mmap_anon(PAGE);
    if (a <= 0) { check(0, "probe A mmap"); return; }
    *(volatile u64 *)a = pat(phase, 1);
    if (syscall3(SYS_MPROTECT, (u64)a, PAGE, 0) != 0) { check(0, "probe A mprotect NONE"); return; }

    /* The console write path reports an uncopyable source as a 0-byte short
     * write (file_io.zig's convention; read(2) below uses -EFAULT). Either
     * refusal is correct — what must never happen is the pre-fix phantom
     * swap-in admitting the reservation and returning a full count. */
    check(syscall3(SYS_WRITE, 1, (u64)a, 16) <= 0,
          "probe A: write(2) from a PROT_NONE reservation must be refused");

    int p[2] = { -1, -1 };
    if (syscall1(SYS_PIPE, (u64)p) == 0) {
        char byte = 0x5A, out = 0;
        if (syscall3(SYS_WRITE, (u64)p[1], (u64)&byte, 1) == 1) {
            const s64 rr = syscall3(SYS_READ, (u64)p[0], (u64)a, 1);
            check(rr == -EFAULT,
                  "probe A: read(2) into a PROT_NONE reservation must be EFAULT");
            /* Only drain when the reservation read was refused — on a broken
             * kernel the phantom swap-in consumes the byte and an
             * unconditional drain would block forever. */
            if (rr == -EFAULT) {
                check(syscall3(SYS_READ, (u64)p[0], (u64)&out, 1) == 1 && out == byte,
                      "probe A: failed read must not consume pipe data");
            }
        } else {
            check(0, "probe A pipe write");
        }
    } else {
        check(0, "probe A pipe");
    }

    check(syscall3(SYS_MPROTECT, (u64)a, PAGE, PROT_RW) == 0, "probe A restore");
    check(*(volatile u64 *)a == pat(phase, 1), "probe A: reservation frame survived syscall probes");
    syscall2(SYS_MUNMAP, (u64)a, PAGE);
}

/* Probe B: user access → SIGSEGV (never a phantom swap-in); frame preserved;
 * the reserved address must stay occupied for placement. */
static void probe_segv(u64 phase) {
    const s64 b = mmap_anon(PAGE);
    if (b <= 0) { check(0, "probe B mmap"); return; }
    *(volatile u64 *)b = pat(phase, 2);
    if (syscall3(SYS_MPROTECT, (u64)b, PAGE, 0) != 0) { check(0, "probe B mprotect NONE"); return; }

    const s64 other = mmap_anon(PAGE);
    check(other > 0 && other != b, "probe B: fresh mmap must not reuse the reserved address");
    if (other > 0) syscall2(SYS_MUNMAP, (u64)other, PAGE);

    expect_segv = 1;
    segv_seen = 0;
    repair_page = (u64)b;
    repair_len = PAGE;
    volatile u64 v = *(volatile u64 *)b; /* fixed: SIGSEGV → handler repairs → retry */
    expect_segv = 0;

    check(segv_seen == 1, "probe B: accessing a PROT_NONE reservation must SIGSEGV");
    check(v == pat(phase, 2), "probe B: reservation frame preserved (no disk garbage)");
    syscall2(SYS_MUNMAP, (u64)b, PAGE);
}

/* Probe C: PROT_NONE → PROT_RW restore with no fault in between. Pre-fix the
 * commit loop took the swap-entry branch and left present=0 — the read below
 * SIGSEGVs on the broken kernel (deterministic RED). */
static void probe_restore(u64 phase) {
    const s64 c = mmap_anon(PAGE);
    if (c <= 0) { check(0, "probe C mmap"); return; }
    *(volatile u64 *)c = pat(phase, 3);
    if (syscall3(SYS_MPROTECT, (u64)c, PAGE, 0) != 0) { check(0, "probe C mprotect NONE"); return; }
    if (syscall3(SYS_MPROTECT, (u64)c, PAGE, PROT_RW) != 0) { check(0, "probe C mprotect RW"); return; }

    expect_segv = 0; /* any SIGSEGV here means restore left the mapping dead */
    volatile u64 v = *(volatile u64 *)c;
    check(v == pat(phase, 3), "probe C: PROT_RW restore returns the original frame");
    *(volatile u64 *)c = pat(phase, 4);
    check(*(volatile u64 *)c == pat(phase, 4), "probe C: restored page accepts writes");
    syscall2(SYS_MUNMAP, (u64)c, PAGE);
}

/* Probe D: huge-backed (2 MiB) full-range PROT_NONE → SIGSEGV → full-range
 * repair preserves every written page. */
static void probe_huge(u64 phase) {
    const s64 h = mmap_anon(HUGE_LEN);
    if (h <= 0) { check(0, "probe D mmap"); return; }
    volatile u64 *m = (volatile u64 *)h;
    m[0] = pat(phase, 5);
    m[256 * 512] = pat(phase, 6);           /* mid-block page */
    m[511 * 512] = pat(phase, 7);           /* last page */
    if (syscall3(SYS_MPROTECT, (u64)h, HUGE_LEN, 0) != 0) { check(0, "probe D mprotect NONE"); return; }

    expect_segv = 1;
    segv_seen = 0;
    repair_page = (u64)h;
    repair_len = HUGE_LEN;
    volatile u64 v = m[128 * 512];          /* untouched page: faults, repairs, reads 0 */
    expect_segv = 0;

    check(segv_seen == 1, "probe D: huge PROT_NONE access must SIGSEGV");
    check(v == 0, "probe D: untouched huge page reads back zero");
    check(m[0] == pat(phase, 5) && m[256 * 512] == pat(phase, 6) && m[511 * 512] == pat(phase, 7),
          "probe D: huge reservation frames preserved");
    syscall2(SYS_MUNMAP, (u64)h, HUGE_LEN);
}

static void run_probes(u64 phase) {
    probe_efault(phase);
    probe_segv(phase);
    probe_restore(phase);
    probe_huge(phase);
}

/* Phase E (swap armed): hold NRESERVED pattern pages as reservations across a
 * sliding-window churn that forces real swap reclaim against this page table,
 * then restore and verify every word. */
static u64 reserved[NRESERVED];
static u64 churn[CHURN_WINDOW];

static void phase_swap(void) {
    /* hello98 ran before us and syscallSwapoff is an intentional no-op
     * (§6.47), so swap may already be armed: tolerate EBUSY exactly like
     * hello98's own phase A does. */
    const s64 sw = syscall3(SYS_SWAPON, (u64)"/dev/sda", 0, 0);
    if (sw != 0 && sw != -16 /* EBUSY */)
        fail_exit("swapon scratch device");
    swap_armed = 1;

    u64 sinfo[16];
    for (int i = 0; i < 16; i++) sinfo[i] = 0;
    if (syscall1(SYS_SYSINFO, (u64)sinfo) != 0) fail_exit("sysinfo");
    const u64 freeram_pages = sinfo[5] / 4096;
    if (freeram_pages < MARGIN_PAGES * 3) fail_exit("not enough free RAM");
    saved_floor = syscall1(SYS_PMM_SET_RECLAIM_FLOOR, freeram_pages - MARGIN_PAGES);
    print("hello99:   swap armed, reclaim floor set\n");

    /* The same probes with swap live: a reservation must still SIGSEGV and
     * must never be read as a swap slot. */
    run_probes(9);

    for (int i = 0; i < NRESERVED; i++) {
        const s64 r = mmap_anon(PAGE);
        if (r <= 0) fail_exit("reserved page mmap");
        reserved[i] = (u64)r;
        *(volatile u64 *)r = pat(8, (u64)i);
        if (syscall3(SYS_MPROTECT, (u64)r, PAGE, 0) != 0)
            fail_exit("reserved page mprotect NONE");
    }

    for (int i = 0; i < CHURN_WINDOW; i++) churn[i] = 0;
    for (u64 round = 0; round < CHURN_ROUNDS; round++) {
        const int slot = (int)(round % CHURN_WINDOW);
        const s64 base = mmap_anon(1024 * 1024);
        if (base <= 0) fail_exit("churn mmap");
        volatile u64 *m = (volatile u64 *)base;
        for (u64 pg = 0; pg < 256; pg++) m[pg * 512] = pat(7, round << 8 | pg);
        if (churn[slot] != 0) {
            if (syscall2(SYS_MUNMAP, churn[slot], 1024 * 1024) != 0)
                fail_exit("churn munmap");
        }
        churn[slot] = (u64)base;
    }
    for (int i = 0; i < CHURN_WINDOW; i++)
        if (churn[i] != 0) syscall2(SYS_MUNMAP, churn[i], 1024 * 1024);

    /* Reservations survived reclaim pressure: restore and verify. */
    expect_segv = 0;
    for (int i = 0; i < NRESERVED; i++) {
        if (syscall3(SYS_MPROTECT, reserved[i], PAGE, PROT_RW) != 0)
            fail_exit("reserved page restore");
        if (*(volatile u64 *)reserved[i] != pat(8, (u64)i))
            fail_exit("reserved page contents corrupted under swap pressure");
        syscall2(SYS_MUNMAP, reserved[i], PAGE);
    }
    print("hello99:   reservations intact across reclaim churn\n");

    cleanup();
}

void _start(void) {
    print("hello99: PROT_NONE reservation vs swap-entry encoding\n");

    struct ksigaction act = { segv_handler, 0, 0, 0 };
    if (syscall3(SYS_SIGACTION, SIGSEGV, (u64)&act, 0) != 0)
        fail_exit("sigaction");

    /* Phase 1: no swap — the reservation/restore contract. */
    run_probes(1);
    print("hello99:   bare probes done\n");

    /* Phase 2: swap armed + reclaim pressure — the collision scenario. */
    phase_swap();

    if (failures == 0) {
        print("hello99: PASS (reservations SIGSEGV/EFAULT, restore intact, swap disjoint)\n");
        print("hello99 done\n");
        syscall1(SYS_EXIT, 0);
    }
    cleanup();
    print("hello99 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}
