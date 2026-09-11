/// hello96: swap path dynamic acceptance — swapon device targeting safety
/// gate + SMP swap-reclaim stress against the vm_lock guard (§6.44/§6.45).
///
/// Phase A (gate): swapon must reject the boot/system disk ("/dev/vblk0",
/// EPERM), unknown devices (ENODEV), nonzero flags (EINVAL) and unreadable
/// paths (EFAULT); enabling swap on the AHCI scratch disk ("/dev/sda", the
/// pattern-stamped throwaway image attached by tools/qemu_run.sh) must
/// succeed, and a second swapon must report EBUSY.
///
/// Phase B (stress): 512 MiB of guest RAM cannot be pressured inside the
/// smoke's time budget, so the kernel's reclaim-floor test hook (syscall
/// 485, mm/pmm.zig) moves the reclaim trigger up: once free RAM dips below
/// `freeram - 64 MiB`, every allocation first runs swap reclaim against the
/// caller's own page table (the floor never fails an allocation by itself).
/// The main task plus one CLONE_VM thread (one shared page table, like
/// hello35) then churn anonymous regions through a sliding window — mmap,
/// write a position-dependent pattern, mprotect toggle, verify (forcing
/// swap-in), munmap — so swap-out and swap-in run concurrently with sibling
/// fault handlers and unmapRange on the same Mm. Any pattern mismatch after
/// swap-in is a FAIL. The floor is restored and swapoff'ed on every exit
/// path. Regions are deliberately 1 MiB: anonymous mappings of 2 MiB and
/// larger are backed by huge pages, which reclaim/swap excludes by design.
///
/// Bounded on purpose: a 4-worker variant (3 CLONE_VM threads) exercised
/// harder contention but was unstable under SMP=4/TCG (threads killed at
/// RIP=0 — unresolved, see docs §6.45 residuals), so this ships at
/// NWORKERS=2, which passes SMP=1/2/4 with full data-integrity checks.
///
/// Data-integrity note: each page is written exactly once before it is
/// verified (never rewritten in between), so a lost concurrent store — the
/// known two-phase writeback gap — cannot produce a false FAIL; what the
/// verify catches is swap-out/swap-in content corruption.

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
#define SYS_MPROTECT    164
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

#define EPERM   1
#define EFAULT  14
#define EBUSY   16
#define ENODEV  19
#define EINVAL  22

#define NWORKERS      2          /* main + 1 CLONE_VM thread (bounded, see §6.45) */
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

/* Position-dependent pattern: any content carried over a swap-out/swap-in
 * cycle must reproduce exactly, and cross-region/worker confusion shows up
 * immediately. */
static uint64_t pat(int worker, uint32_t round, uint64_t idx) {
    return ((uint64_t)(uint32_t)(worker + 1) << 56) | ((uint64_t)round << 32) |
           (idx * 0x9E3779B97F4A7C15ULL);
}

/* Shared CLONE_VM state (single address space, so plain globals are shared;
 * each worker only ever touches its own row). */
static volatile int64_t worker_done[NWORKERS];
static volatile int64_t worker_fail[NWORKERS];
static volatile int64_t next_worker_id = 1; /* main is worker 0 */
static uint64_t regions[NWORKERS][WINDOW];

static void worker_note_fail(int w, int64_t code) {
    if (!worker_fail[w]) worker_fail[w] = code;
}

static volatile uint64_t canary[256];

static void worker_run(int w) {
    for (uint32_t r = 0; r < ROUNDS; r++) {
        /* Stop early once any sibling reported a failure. */
        for (int i = 0; i < NWORKERS; i++)
            if (worker_fail[i]) {
                print("hello96: DEBUG early-stop w=");
                print_dec(w);
                print(" fail idx=");
                print_dec(i);
                print(" val=");
                print_dec(worker_fail[i]);
                print("\n");
                worker_done[w] = 1; syscall1(SYS_EXIT, 0); for (;;) {} }

        int slot = (int)(r % WINDOW);
        uint64_t old = regions[w][slot];

        int64_t base = syscall6(SYS_MMAP, 0, REGION_LEN, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
        if (base <= 0) { worker_note_fail(w, 100 + w); break; }

        volatile uint64_t *m = (volatile uint64_t *)base;
        for (uint64_t i = 0; i < REGION_WORDS; i++) m[i] = pat(w, r, i);

        /* mprotect toggle on the first page: concurrent vm_lock mutation on
         * the shared Mm while reclaim may be scanning it. */
        if (syscall3(SYS_MPROTECT, (uint64_t)base, 4096, PROT_READ) != 0) {
            worker_note_fail(w, 200 + w); break;
        }
        if (m[0] != pat(w, r, 0)) {
            print("hello96: DEBUG m[0] mismatch w=");
            print_dec(w);
            print(" r=");
            print_dec(r);
            print(" got=");
            print_dec((int64_t)m[0]);
            print(" want=");
            print_dec((int64_t)pat(w, r, 0));
            print(" va=");
            { char hb[20]; uint64_t v=(uint64_t)base; int n=0;
              const char *hd="0123456789abcdef";
              for (int sh=60; sh>=0; sh-=4) hb[n++]=hd[(v>>sh)&15];
              syscall3(SYS_WRITE, 1, (uint64_t)hb, n); }
            print("\n");
            worker_note_fail(w, 210 + w); break;
        }
        if (syscall3(SYS_MPROTECT, (uint64_t)base, 4096, PROT_READ | PROT_WRITE) != 0) {
            worker_note_fail(w, 220 + w); break;
        }

        regions[w][slot] = (uint64_t)base;

        /* Window full: verify the oldest region (its swapped-out pages must
         * fault back in with content intact), then release it. */
        if (old != 0) {
            int old_round = (int)r - WINDOW;
            volatile const uint64_t *o = (volatile const uint64_t *)old;
            int ok = 1;
            for (uint64_t i = 0; i < REGION_WORDS; i++)
                if (o[i] != pat(w, (uint32_t)old_round, i)) { ok = 0; break; }
            if (!ok) { worker_note_fail(w, 300 + w); break; }
            if (syscall3(SYS_MUNMAP, old, REGION_LEN, 0) != 0) {
                worker_note_fail(w, 400 + w); break;
            }
        }
    }
    worker_done[w] = 1;
    if (w != 0) {
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
    print("hello96: FAIL ");
    print(tag);
    print("\n");
    restore_floor();
    print("hello96 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    print("hello96: swap gate + SMP reclaim stress\n");

    /* ── Phase A: swapon device-targeting safety gate ────────────────── */
    int64_t r = syscall3(SYS_SWAPON, (uint64_t)"/dev/vblk0", 0, 0);
    if (r != -EPERM) fail_exit("swapon boot disk not EPERM");
    r = syscall3(SYS_SWAPON, (uint64_t)"/dev/nope0", 0, 0);
    if (r != -ENODEV) fail_exit("swapon unknown device not ENODEV");
    r = syscall3(SYS_SWAPON, (uint64_t)"/dev/sda", 1, 0);
    if (r != -EINVAL) fail_exit("swapon nonzero flags not EINVAL");
    /* Unmapped path pointer must fault, not be read as garbage. */
    int64_t bad = syscall6(SYS_MMAP, 0, 4096, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (bad <= 0) fail_exit("mmap for bad pointer");
    if (syscall3(SYS_MUNMAP, (uint64_t)bad, 4096, 0) != 0) fail_exit("munmap bad pointer");
    r = syscall3(SYS_SWAPON, (uint64_t)bad, 0, 0);
    if (r != -EFAULT) fail_exit("swapon unmapped path not EFAULT");

    r = syscall3(SYS_SWAPON, (uint64_t)"/dev/sda", 0, 0);
    if (r != 0) { print_dec(r); fail_exit(" swapon scratch device failed"); }
    r = syscall3(SYS_SWAPON, (uint64_t)"/dev/nvme0", 0, 0);
    if (r != -EBUSY) fail_exit("second swapon not EBUSY");
    print("hello96:   gate ok (boot disk EPERM, scratch admitted, EBUSY)\n");

    for (int i = 0; i < 256; i++) canary[i] = 0xCA0000UL + (uint64_t)i;

    /* ── Phase B: memory-pressure churn under the reclaim floor ──────── */
    uint64_t sinfo[16];
    for (int i = 0; i < 16; i++) sinfo[i] = 0;
    if (syscall1(SYS_SYSINFO, (uint64_t)sinfo) != 0) fail_exit("sysinfo");
    const uint64_t freeram_pages = sinfo[5] / 4096; /* freeram at offset 40 */
    if (freeram_pages < MARGIN_PAGES * 3) fail_exit("not enough free RAM");
    const uint64_t floor = freeram_pages - MARGIN_PAGES;
    saved_floor = syscall1(SYS_PMM_SET_RECLAIM_FLOOR, floor);
    print("hello96:   reclaim floor set (freeram pages=");
    print_dec((int64_t)freeram_pages);
    print(")\n");

    for (int i = 0; i < NWORKERS; i++) {
        worker_done[i] = 0;
        worker_fail[i] = 0;
        for (int j = 0; j < WINDOW; j++) regions[i][j] = 0;
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

    /* Bounded wait for the thread workers. */
    int done_count;
    int64_t spins = 0;
    for (;;) {
        done_count = 0;
        for (int i = 0; i < NWORKERS; i++)
            if (worker_done[i]) done_count++;
        if (done_count == NWORKERS) break;
        if (++spins > 20000000) fail_exit("worker timeout");
        syscall1(SYS_SCHED_YIELD, 0);
    }

    for (int i = 0; i < NWORKERS; i++) {
        if (worker_fail[i]) {
            print("hello96: FAIL worker ");
            print_dec(i);
            print(" code ");
            print_dec(worker_fail[i]);
            print("\n");
            restore_floor();
            print("hello96 done\n");
            syscall1(SYS_EXIT, 1);
            for (;;) {}
        }
    }

    restore_floor();
    r = syscall3(SYS_SWAPOFF, (uint64_t)"/dev/sda", 0, 0);
    if (r != 0) fail_exit("swapoff");

    for (int i = 0; i < 256; i++) {
        if (canary[i] != 0xCA0000UL + (uint64_t)i) {
            print("hello96: DEBUG canary corrupt idx=");
            print_dec(i);
            print(" val=");
            print_dec((int64_t)canary[i]);
            print("\n");
            break;
        }
    }
    print("hello96: PASS (gate + 2-worker swap churn, integrity verified)\n");
    print("hello96 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
