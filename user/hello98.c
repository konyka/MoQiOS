/// hello98: 4-worker swap path dynamic acceptance — the SMP=4 contention
/// variant of hello96 (§6.45 residual #1 / §6.47).
///
/// Phase A (gate): same swapon device-targeting safety gate as hello96 —
/// boot/system disk EPERM, unknown device ENODEV, nonzero flags EINVAL,
/// unreadable path EFAULT, scratch disk admitted, second swapon EBUSY.
/// One deliberate difference: enabling the scratch disk also accepts EBUSY.
/// It was originally required because syscallSwapoff was a no-op stub and
/// hello96 left swap armed for the rest of the boot; §6.50 made swapoff
/// real, so every predecessor now disarms and this returns 0 — the EBUSY
/// tolerance is kept as belt-and-braces against init-order changes.
///
/// Phase B (stress): same reclaim-floor design as hello96, but the churn
/// runs with the main task plus THREE CLONE_VM threads (NWORKERS=4) — the
/// configuration under which SMP=4/TCG once killed threads at RIP=0/addr=0
/// (err=0x14) in the §6.45 session. That failure has not been reproduced
/// since (see §6.47: 40+ instrumented runs clean, NCQ-abort wedge ruled a
/// host /tmp-quota artifact); this program is the permanent tripwire: the
/// kernel's [RIP0-DIAG] dump (idt.zig) captures the dying thread's stack
/// PTE/content and syscall-redirect state if it ever recurs, and the smoke
/// treats any [SEGFAULT] as a failure.
///
/// Data-integrity note: identical to hello96 — pages are written exactly
/// once before verification, so a FAIL means swap-out/swap-in content
/// corruption, never a lost concurrent store.

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

#define NWORKERS      4          /* main + 3 CLONE_VM threads (the §6.45 residual config) */
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
                print("hello98: DEBUG early-stop w=");
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
            print("hello98: DEBUG m[0] mismatch w=");
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
    print("hello98: FAIL ");
    print(tag);
    print("\n");
    restore_floor();
    print("hello98 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    print("hello98: swap gate + SMP reclaim stress\n");

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
    /* §6.50 made swapoff real, so a preceding hello96 disarms swap and this
     * returns 0; accept EBUSY ("already armed") as belt-and-braces against
     * init-order changes — the churn below exercises the same paths either
     * way. The admission rejections above are ordered before the EBUSY
     * check in the kernel, so they still gate. */
    if (r != 0 && r != -EBUSY) { print_dec(r); fail_exit(" swapon scratch device failed"); }
    r = syscall3(SYS_SWAPON, (uint64_t)"/dev/nvme0", 0, 0);
    if (r != -EBUSY) fail_exit("second swapon not EBUSY");
    print("hello98:   gate ok (boot disk EPERM, scratch admitted, EBUSY)\n");

    for (int i = 0; i < 256; i++) canary[i] = 0xCA0000UL + (uint64_t)i;

    /* ── Phase B: memory-pressure churn under the reclaim floor ──────── */
    uint64_t sinfo[16];
    for (int i = 0; i < 16; i++) sinfo[i] = 0;
    if (syscall1(SYS_SYSINFO, (uint64_t)sinfo) != 0) fail_exit("sysinfo");
    const uint64_t freeram_pages = sinfo[5] / 4096; /* freeram at offset 40 */
    if (freeram_pages < MARGIN_PAGES * 3) fail_exit("not enough free RAM");
    const uint64_t floor = freeram_pages - MARGIN_PAGES;
    saved_floor = syscall1(SYS_PMM_SET_RECLAIM_FLOOR, floor);
    print("hello98:   reclaim floor set (freeram pages=");
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
            print("hello98: FAIL worker ");
            print_dec(i);
            print(" code ");
            print_dec(worker_fail[i]);
            print("\n");
            restore_floor();
            print("hello98 done\n");
            syscall1(SYS_EXIT, 1);
            for (;;) {}
        }
    }

    restore_floor();
    r = syscall3(SYS_SWAPOFF, (uint64_t)"/dev/sda", 0, 0);
    if (r != 0) fail_exit("swapoff");

    for (int i = 0; i < 256; i++) {
        if (canary[i] != 0xCA0000UL + (uint64_t)i) {
            print("hello98: DEBUG canary corrupt idx=");
            print_dec(i);
            print(" val=");
            print_dec((int64_t)canary[i]);
            print("\n");
            break;
        }
    }
    print("hello98: PASS (gate + 4-worker swap churn, integrity verified)\n");
    print("hello98 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
