/// hello101: real swapoff acceptance (§6.50) — drain + disable, replacing the
/// documented no-op stub that hello96-100 tolerated.
///
/// Phase A (error gates): swapoff on a never-armed device is EINVAL, an
/// unreadable path pointer is EFAULT, an unknown device is ENODEV — the same
/// conventions as swapon. (Runs while swap is disarmed: hello96/98/99/100
/// each end with a real swapoff.)
///
/// Phase B (drain correctness): swapon the AHCI scratch disk, then under the
/// reclaim floor (hello96 technique) the main task plus ONE CLONE_VM thread
/// (a single shared page table — the drain's dedupe path walks it once)
/// write position-dependent patterns into a sliding window of 1 MiB regions.
/// Regions are written exactly once and NEVER touched again before swapoff,
/// so their pages stay swapped out; a min-freeswap anti-vacuity assertion
/// proves swap genuinely engaged. swapoff must then migrate every in-use
/// slot's page back to RAM and disable the device. Only AFTER swapoff do
/// both threads verify all regions word-for-word (own + sibling's) — a FAIL
/// means drain content corruption, never a lost concurrent store.
///
/// Phase C (commit semantics): sysinfo totalswap/freeswap must be 0, a
/// second swapoff is EINVAL (device disabled), and re-swapon must work
/// (followed by a clean swapoff with zero usage).

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

static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall"
                      : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8)
                      : "rcx", "r11", "memory");
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

#define SYS_WRITE       1
#define SYS_EXIT        2
#define SYS_MMAP        8
#define SYS_MUNMAP      12
#define SYS_SCHED_YIELD 24
#define SYS_SYSINFO     99
#define SYS_CLONE       243
#define SYS_SWAPON      318
#define SYS_SWAPOFF     319
#define SYS_PMM_SET_RECLAIM_FLOOR 485

#define CLONE_VM     0x100
#define CLONE_FS     0x200
#define CLONE_FILES  0x400
#define CLONE_THREAD 0x10000

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20

#define EFAULT  14
#define ENODEV  19
#define EINVAL  22

#define NWORKERS      2          /* main + 1 CLONE_VM thread (shared page table) */
#define NTHREADS      (NWORKERS - 1)
#define THREAD_STACK  (64 * 1024)
#define REGION_LEN    (1 * 1024 * 1024)  /* < 2 MiB: stays 4K-page backed */
#define REGION_WORDS  (REGION_LEN / 8)
#define WINDOW        36         /* live regions per worker: 2x36=72 MiB > 64 MiB margin */
#define ROUNDS        44
#define MARGIN_PAGES  16384      /* 64 MiB: keep this much RAM truly free */

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
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

/* Position-dependent pattern: any content carried over a swap-out/drain
 * cycle must reproduce exactly, and cross-region/worker confusion shows up
 * immediately. */
static uint64_t pat(int worker, uint32_t round, uint64_t idx) {
    return ((uint64_t)(uint32_t)(worker + 1) << 56) | ((uint64_t)round << 32) |
           (idx * 0x9E3779B97F4A7C15ULL);
}

/* Shared CLONE_VM state (single address space, so plain globals are shared). */
static volatile int64_t worker_done[NWORKERS];
static volatile int64_t worker_fail[NWORKERS];
static volatile int64_t worker_verified[NWORKERS];
static volatile int64_t verify_go = 0;
static volatile int64_t next_worker_id = 1; /* main is worker 0 */
static uint64_t regions[NWORKERS][WINDOW];
static uint32_t region_round[NWORKERS][WINDOW];

/* ── sysinfo readout (offsets per Linux: freeram@40, totalswap@64,
   freeswap@72; §6.49 wired the swap fields) ── */
static uint64_t sinfo_buf[16];

static uint64_t freeram_pages(void) {
    for (int i = 0; i < 16; i++) sinfo_buf[i] = 0;
    syscall1(SYS_SYSINFO, (uint64_t)sinfo_buf);
    return sinfo_buf[5] / 4096;
}

static uint64_t totalswap_pages(void) {
    for (int i = 0; i < 16; i++) sinfo_buf[i] = 0;
    syscall1(SYS_SYSINFO, (uint64_t)sinfo_buf);
    return sinfo_buf[8] / 4096;
}

static uint64_t freeswap_pages(void) {
    for (int i = 0; i < 16; i++) sinfo_buf[i] = 0;
    syscall1(SYS_SYSINFO, (uint64_t)sinfo_buf);
    return sinfo_buf[9] / 4096;
}

static volatile uint64_t min_freeswap;

static void note_freeswap(void) {
    uint64_t f = freeswap_pages();
    if (f < min_freeswap) min_freeswap = f;
}

static void worker_note_fail(int w, int64_t code) {
    if (!worker_fail[w]) worker_fail[w] = code;
}

/* Churn: write a fresh region each round; when the window is full, release
 * the oldest region WITHOUT verifying it — its pages stay swapped out so
 * swapoff has real slots to drain. */
static void worker_churn(int w) {
    for (uint32_t r = 0; r < ROUNDS; r++) {
        for (int i = 0; i < NWORKERS; i++)
            if (worker_fail[i]) return;

        int slot = (int)(r % WINDOW);
        uint64_t old = regions[w][slot];

        int64_t base = syscall6(SYS_MMAP, 0, REGION_LEN, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (base <= 0) { worker_note_fail(w, 100 + w); return; }

        volatile uint64_t *m = (volatile uint64_t *)base;
        for (uint64_t i = 0; i < REGION_WORDS; i++) m[i] = pat(w, r, i);

        regions[w][slot] = (uint64_t)base;
        region_round[w][slot] = r;

        if (old != 0) {
            /* munmap of a region with swapped pages exercises the §6.49
             * freeSlot teardown; contents are intentionally not read here. */
            if (syscall3(SYS_MUNMAP, old, REGION_LEN, 0) != 0) {
                worker_note_fail(w, 400 + w); return;
            }
        }
        if ((r & 7) == 7) note_freeswap();
    }
    note_freeswap();
}

/* Post-swapoff verification: every page must be resident again with its
 * pattern intact. Each worker checks its own regions and its sibling's —
 * the drain walked the shared page table once, both views must agree. */
static int verify_all(int w) {
    for (int other = 0; other < NWORKERS; other++) {
        for (int s = 0; s < WINDOW; s++) {
            uint64_t base = regions[other][s];
            if (base == 0) continue;
            volatile const uint64_t *m = (volatile const uint64_t *)base;
            uint32_t r = region_round[other][s];
            for (uint64_t i = 0; i < REGION_WORDS; i++)
                if (m[i] != pat(other, r, i)) {
                    print("hello101: DEBUG mismatch verifier=");
                    print_dec(w);
                    print(" owner=");
                    print_dec(other);
                    print(" slot=");
                    print_dec(s);
                    print(" idx=");
                    print_dec((int64_t)i);
                    print(" got=");
                    print_dec((int64_t)m[i]);
                    print(" want=");
                    print_dec((int64_t)pat(other, r, i));
                    print("\n");
                    return 0;
                }
        }
    }
    return 1;
}

static void worker_run(int w) {
    worker_churn(w);
    worker_done[w] = 1;
    if (w != 0) {
        /* Wait for main to complete swapoff, then verify. */
        int64_t spins = 0;
        while (!verify_go) {
            if (++spins > 2000000000LL) { worker_note_fail(w, 900 + w); break; }
            syscall1(SYS_SCHED_YIELD, 0);
        }
        if (!worker_fail[w] && !verify_all(w)) worker_note_fail(w, 500 + w);
        worker_verified[w] = 1;
        syscall1(SYS_EXIT, 0);
        for (;;) {}
    }
}

static int64_t saved_floor = -1;

static void restore_floor(void) {
    if (saved_floor >= 0) {
        syscall1(SYS_PMM_SET_RECLAIM_FLOOR, (uint64_t)saved_floor);
        saved_floor = -1;
    }
}

__attribute__((noreturn)) static void fail_exit(const char *tag) {
    print("hello101: FAIL ");
    print(tag);
    print("\n");
    restore_floor();
    print("hello101 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    print("hello101: real swapoff drain acceptance\n");

    /* ── Phase A: error gates while swap is disarmed ─────────────────── */
    int64_t r = syscall3(SYS_SWAPOFF, (uint64_t)"/dev/sda", 0, 0);
    if (r != -EINVAL) { print_dec(r); fail_exit(" swapoff never-armed not EINVAL"); }
    int64_t bad = syscall6(SYS_MMAP, 0, 4096, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (bad <= 0) fail_exit("mmap for bad pointer");
    if (syscall3(SYS_MUNMAP, (uint64_t)bad, 4096, 0) != 0) fail_exit("munmap bad pointer");
    r = syscall3(SYS_SWAPOFF, (uint64_t)bad, 0, 0);
    if (r != -EFAULT) fail_exit("swapoff unmapped path not EFAULT");
    r = syscall3(SYS_SWAPOFF, (uint64_t)"/dev/nope0", 0, 0);
    if (r != -ENODEV) fail_exit("swapoff unknown device not ENODEV");
    print("hello101:   A error gates ok (never-armed EINVAL, EFAULT, ENODEV)\n");

    /* ── Phase B: arm, churn under the reclaim floor, drain via swapoff ── */
    r = syscall3(SYS_SWAPON, (uint64_t)"/dev/sda", 0, 0);
    if (r != 0) { print_dec(r); fail_exit(" swapon scratch device failed"); }
    const uint64_t cap = totalswap_pages();
    if (cap == 0) fail_exit("totalswap zero while armed");
    if (freeswap_pages() != cap) fail_exit("freeswap != totalswap on fresh area");
    r = syscall3(SYS_SWAPOFF, (uint64_t)"/dev/vblk0", 0, 0);
    if (r != -EINVAL) fail_exit("swapoff wrong device not EINVAL");
    print("hello101:   B armed (capacity pages=");
    print_dec((int64_t)cap);
    print(", wrong-device swapoff EINVAL)\n");

    const uint64_t freeram = freeram_pages();
    if (freeram < MARGIN_PAGES * 3) fail_exit("not enough free RAM");
    saved_floor = syscall1(SYS_PMM_SET_RECLAIM_FLOOR, freeram - MARGIN_PAGES);
    min_freeswap = freeswap_pages();

    for (int i = 0; i < NWORKERS; i++) {
        worker_done[i] = 0;
        worker_fail[i] = 0;
        worker_verified[i] = 0;
        for (int j = 0; j < WINDOW; j++) { regions[i][j] = 0; region_round[i][j] = 0; }
    }

    for (int t = 0; t < NTHREADS; t++) {
        int64_t stack = syscall6(SYS_MMAP, 0, THREAD_STACK, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (stack <= 0) fail_exit("thread stack mmap");
        int64_t tid = syscall5(SYS_CLONE,
                               CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_THREAD,
                               (uint64_t)(stack + THREAD_STACK - 16), 0, 0, 0);
        if (tid == 0) {
            const int w = (int)__sync_fetch_and_add(&next_worker_id, 1);
            worker_run(w);
            for (;;) {}
        }
        if (tid < 0) fail_exit("clone worker");
    }

    worker_run(0);

    int64_t spins = 0;
    for (;;) {
        int done_count = 0;
        for (int i = 0; i < NWORKERS; i++)
            if (worker_done[i]) done_count++;
        if (done_count == NWORKERS) break;
        if (++spins > 20000000) fail_exit("worker churn timeout");
        syscall1(SYS_SCHED_YIELD, 0);
    }
    for (int i = 0; i < NWORKERS; i++)
        if (worker_fail[i]) fail_exit("worker churn failure");

    /* Anti-vacuity: swap must genuinely have engaged, otherwise the drain
     * below proves nothing. */
    if (min_freeswap >= cap) {
        print("hello101: DEBUG min_freeswap=");
        print_dec((int64_t)min_freeswap);
        print(" cap=");
        print_dec((int64_t)cap);
        print("\n");
        fail_exit("swap never engaged (vacuous test)");
    }
    print("hello101:   B churn done, swap engaged (used pages>=");
    print_dec((int64_t)(cap - min_freeswap));
    print(" at peak)\n");

    /* Restore the floor so the drain's frame allocations behave normally,
     * then drain: every swapped page migrates back to RAM. The CLONE_VM
     * sibling is still spinning on verify_go — its faults during the drain
     * exercise "swapIn keeps working while draining". */
    restore_floor();
    r = syscall3(SYS_SWAPOFF, (uint64_t)"/dev/sda", 0, 0);
    if (r != 0) { print_dec(r); fail_exit(" swapoff drain failed"); }
    print("hello101:   B swapoff drained\n");

    /* ── Phase C: commit semantics ───────────────────────────────────── */
    if (totalswap_pages() != 0 || freeswap_pages() != 0)
        fail_exit("sysinfo swap fields not zero after swapoff");
    r = syscall3(SYS_SWAPOFF, (uint64_t)"/dev/sda", 0, 0);
    if (r != -EINVAL) fail_exit("second swapoff not EINVAL");
    print("hello101:   C device disabled (sysinfo 0, swapoff-again EINVAL)\n");

    /* Only now verify: both threads read every region of the shared space. */
    verify_go = 1;
    spins = 0;
    for (;;) {
        int vcount = 0;
        for (int i = 1; i < NWORKERS; i++)
            if (worker_verified[i]) vcount++;
        if (vcount == NTHREADS) break;
        if (++spins > 20000000) fail_exit("worker verify timeout");
        syscall1(SYS_SCHED_YIELD, 0);
    }
    if (!verify_all(0)) fail_exit("post-swapoff content mismatch (main)");
    for (int i = 0; i < NWORKERS; i++)
        if (worker_fail[i]) {
            print("hello101: FAIL worker ");
            print_dec(i);
            print(" code ");
            print_dec(worker_fail[i]);
            print("\n");
            fail_exit("worker verify failure");
        }
    print("hello101:   C all drained pages verified intact (both threads)\n");

    /* Re-arm and cleanly disable with zero usage. */
    r = syscall3(SYS_SWAPON, (uint64_t)"/dev/sda", 0, 0);
    if (r != 0) fail_exit("re-swapon failed");
    if (totalswap_pages() == 0) fail_exit("totalswap zero after re-swapon");
    r = syscall3(SYS_SWAPOFF, (uint64_t)"/dev/sda", 0, 0);
    if (r != 0) fail_exit("clean swapoff after re-swapon failed");
    if (totalswap_pages() != 0 || freeswap_pages() != 0)
        fail_exit("sysinfo swap fields not zero after final swapoff");
    print("hello101:   C re-swapon + clean swapoff ok\n");

    print("hello101: PASS (swapoff drain: gates + content intact + disable + re-arm)\n");
    print("hello101 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
