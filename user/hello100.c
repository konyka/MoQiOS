/// hello100: munmap/exit must reclaim non-present PTE resources (§6.49) +
/// PROT_NONE first-access SIGSEGV for never-faulted file pages (§6.48 residual).
///
/// Pre-fix, unmapPage returned null for every non-present leaf, so:
///   (a) a PROT_NONE reservation's retained FRAME leaked on munmap/exit
///       (unmapRange skipped it; destroyUserSpace only walked present leaves);
///   (b) a swapped-out page's SWAP SLOT leaked on munmap/exit (the swap entry
///       even stayed in the page table — never zeroed, never freeSlot'ed).
/// The fix classifies every torn-down PTE with mm/pte_kind.zig's
/// teardownAction: present/prot_none → drop the frame reference, swap →
/// freeSlot, free/unknown → nothing.
///
/// Phases:
///   A1. loop {mmap 1 MiB, touch, mprotect PROT_NONE, munmap} — freeram must
///       return to baseline (pre-fix: -256 frames per iteration).
///   A2. same but the reservation is destroyed by process EXIT (fork child
///       exits without munmap) — destroyUserSpace must reclaim the frames.
///   B.  a never-faulted file-backed page under PROT_NONE must SIGSEGV on
///       first access (zero PTE + region prot=0), then demand-fill correctly
///       once the handler repairs with mprotect(PROT_RW); a full-range
///       mprotect to RW without any access must serve the file's contents
///       and keep writes private (COW).
///   A3. under armed swap + reclaim floor: sliding-window churn whose regions
///       are munmap'ed WITHOUT swap-in — freeswap (sysinfo, wired in §6.49)
///       must return to baseline (pre-fix: every evicted-then-unmapped page
///       leaked its slot).
///   A4. same through process exit: children churn under the floor and exit
///       without munmap — destroyUserSpace must free their swap slots.

#include <stdint.h>

typedef int64_t s64;
typedef uint64_t u64;
typedef uint8_t u8;

static inline s64 syscall1(u64 nr, u64 a1) {
    s64 ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall3(u64 nr, u64 a1, u64 a2, u64 a3) {
    s64 ret;
    register u64 rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline s64 syscall4(u64 nr, u64 a1, u64 a2, u64 a3, u64 a4) {
    s64 ret;
    register u64 rdx __asm__("rdx") = a3;
    register u64 r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
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
#define SYS_OPEN      9
#define SYS_READ      10
#define SYS_CLOSE     11
#define SYS_MUNMAP    12
#define SYS_SIGACTION 13
#define SYS_PREAD     17
#define SYS_PIPE      22
#define SYS_FORK      57
#define SYS_SYSINFO   99
#define SYS_MPROTECT  164
#define SYS_SWAPON    318
#define SYS_SWAPOFF   319
#define SYS_PMM_SET_RECLAIM_FLOOR 485

#define SIGSEGV 11

#define PROT_READ     0x1
#define PROT_WRITE    0x2
#define PROT_RW       (PROT_READ | PROT_WRITE)
#define PROT_NONE     0x0
#define MAP_PRIVATE   0x02
#define MAP_ANONYMOUS 0x20
#define O_RDWR_CREAT_TRUNC 0x242
#define O_RDONLY      0x0

#define PAGE          4096UL
#define REGION_LEN    (1024 * 1024)   /* < 2 MiB: stays 4K-page backed */
#define REGION_PAGES  (REGION_LEN / PAGE)
#define A1_ITERS      24              /* pre-fix drift: 24*256 = 6144 frames */
#define A2_ITERS      8               /* pre-fix drift: 8*256 = 2048 frames */
#define RAM_SLACK     32              /* pages of measurement slack */
#define SWAP_SLACK    4               /* slots of measurement slack */
#define MARGIN_PAGES  12288           /* 48 MiB reclaim floor margin */
#define WINDOW        56              /* 56 MiB live > 48 MiB margin */
#define A3_ROUNDS     80
#define A4_CHILDREN   3
#define A4_ROUNDS     16

static void print(const char *s) {
    u64 n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (u64)s, n);
}

static void print_dec(s64 v) {
    char buf[24];
    int pos = 0;
    if (v < 0) { print("-"); v = -v; }
    if (v == 0) { print("0"); return; }
    while (v > 0) { buf[pos++] = '0' + (v % 10); v /= 10; }
    for (int i = 0; i < pos / 2; i++) { char t = buf[i]; buf[i] = buf[pos - 1 - i]; buf[pos - 1 - i] = t; }
    syscall3(SYS_WRITE, 1, (u64)buf, pos);
}

__attribute__((noreturn)) static void fail_exit(const char *tag) {
    print("hello100: FAIL ");
    print(tag);
    print("\nhello100 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

/* ── sysinfo readout (offsets per Linux: freeram@40, totalswap@64,
   freeswap@72; §6.49 wired the swap fields) ── */
static u64 sinfo_buf[16];

static u64 freeram_pages(void) {
    for (int i = 0; i < 16; i++) sinfo_buf[i] = 0;
    if (syscall1(SYS_SYSINFO, (u64)sinfo_buf) != 0) fail_exit("sysinfo");
    return sinfo_buf[5] / PAGE;
}

static u64 freeswap_pages(void) {
    for (int i = 0; i < 16; i++) sinfo_buf[i] = 0;
    if (syscall1(SYS_SYSINFO, (u64)sinfo_buf) != 0) fail_exit("sysinfo");
    return sinfo_buf[9] / PAGE;
}

static s64 mmap_anon(u64 len) {
    return syscall6(SYS_MMAP, 0, len, PROT_RW, MAP_PRIVATE | MAP_ANONYMOUS, (u64)-1, 0);
}

static void touch_all(u64 base, u64 pages, u64 tag) {
    volatile u64 *m = (volatile u64 *)base;
    for (u64 pg = 0; pg < pages; pg++) m[pg * 512] = tag ^ (pg * 0x9E3779B97F4A7C15UL);
}

/* ── A1: PROT_NONE reservation frames reclaimed by munmap ── */
static void phase_a1(void) {
    const u64 base_free = freeram_pages();
    for (u64 i = 0; i < A1_ITERS; i++) {
        const s64 a = mmap_anon(REGION_LEN);
        if (a <= 0) fail_exit("A1 mmap");
        touch_all((u64)a, REGION_PAGES, i);
        if (syscall3(SYS_MPROTECT, (u64)a, REGION_LEN, PROT_NONE) != 0)
            fail_exit("A1 mprotect NONE");
        if (syscall3(SYS_MUNMAP, (u64)a, REGION_LEN, 0) != 0)
            fail_exit("A1 munmap");
    }
    const s64 leaked = (s64)base_free - (s64)freeram_pages();
    if (leaked > RAM_SLACK) {
        print("hello100: A1 leaked frames=");
        print_dec(leaked);
        print("\n");
        fail_exit("A1 reservation frames not reclaimed by munmap");
    }
    print("hello100:   A1 reservation-munmap reclaim ok\n");
}

/* ── A2: PROT_NONE reservation frames reclaimed by process exit ── */
static void phase_a2(void) {
    const u64 base_free = freeram_pages();
    for (u64 i = 0; i < A2_ITERS; i++) {
        const s64 child = syscall1(SYS_FORK, 0);
        if (child < 0) fail_exit("A2 fork");
        if (child == 0) {
            const s64 a = mmap_anon(REGION_LEN);
            if (a > 0) {
                touch_all((u64)a, REGION_PAGES, i);
                syscall3(SYS_MPROTECT, (u64)a, REGION_LEN, PROT_NONE);
            }
            syscall1(SYS_EXIT, 0); /* no munmap — destroyUserSpace must reclaim */
            for (;;) {}
        }
        s64 status = 0;
        syscall3(SYS_WAITPID, (u64)-1, (u64)&status, 0);
        if (status != 0) fail_exit("A2 child status");
    }
    const s64 leaked = (s64)base_free - (s64)freeram_pages();
    if (leaked > RAM_SLACK) {
        print("hello100: A2 leaked frames=");
        print_dec(leaked);
        print("\n");
        fail_exit("A2 reservation frames not reclaimed by exit");
    }
    print("hello100:   A2 reservation-exit reclaim ok\n");
}

/* ── A2b: a COW-shared reservation frame must be decRef'ed, not freed ──
 * fork while the page is present (frame refcount 2, both sides COW), then
 * mprotect(PROT_NONE) + munmap in the parent: the child's reference must
 * keep the frame alive and intact. An unconditional free would recycle the
 * frame under the child — the parent's allocation storm below makes such a
 * reuse virtually certain to surface. */

static void phase_a2b(void) {
    const u64 base_free = freeram_pages();
    for (u64 i = 0; i < A2_ITERS; i++) {
        const s64 a = mmap_anon(PAGE);
        if (a <= 0) fail_exit("A2b mmap");
        *(volatile u64 *)a = 0xC0A00000UL + i;

        int p[2] = { -1, -1 };
        if (syscall1(SYS_PIPE, (u64)p) != 0) fail_exit("A2b pipe");
        const s64 child = syscall1(SYS_FORK, 0);
        if (child < 0) fail_exit("A2b fork");
        if (child == 0) {
            char c;
            if (syscall3(SYS_READ, (u64)p[0], (u64)&c, 1) != 1)
                syscall1(SYS_EXIT, 1);
            /* Parent has munmap'ed its reservation by now; the frame must
             * still be ours, contents intact. */
            syscall1(SYS_EXIT, *(volatile u64 *)a == 0xC0A00000UL + i ? 0 : 3);
            for (;;) {}
        }
        if (syscall3(SYS_MPROTECT, (u64)a, PAGE, PROT_NONE) != 0)
            fail_exit("A2b mprotect NONE");
        if (syscall3(SYS_MUNMAP, (u64)a, PAGE, 0) != 0)
            fail_exit("A2b munmap");
        /* Encourage the PMM to recycle any wrongly-freed frame. */
        for (int j = 0; j < 8; j++) {
            const s64 s = mmap_anon(PAGE);
            if (s > 0) {
                *(volatile u64 *)s = 0xDEADDEAD0000UL + (u64)j;
                syscall3(SYS_MUNMAP, (u64)s, PAGE, 0);
            }
        }
        char x = 0x58;
        syscall3(SYS_WRITE, (u64)p[1], (u64)&x, 1);
        s64 status = 0;
        syscall3(SYS_WAITPID, (u64)-1, (u64)&status, 0);
        if (status == 3) fail_exit("A2b COW-shared reservation frame corrupted by munmap");
        if (status != 0) fail_exit("A2b child status");
    }
    const s64 leaked = (s64)base_free - (s64)freeram_pages();
    if (leaked > RAM_SLACK) {
        print("hello100: A2b leaked frames=");
        print_dec(leaked);
        print("\n");
        fail_exit("A2b reservation frames not reclaimed");
    }
    print("hello100:   A2b COW-shared reservation decRef ok\n");
}

/* ── B: PROT_NONE first access on a never-faulted file page ── */
struct ksigaction {
    void (*handler)(int);
    unsigned long mask;
    unsigned long flags;
    void *restorer;
};

static volatile int expect_segv;
static volatile int segv_seen;
static volatile u64 repair_page;
static volatile u64 repair_len;

static void segv_handler(int sig) {
    (void)sig;
    if (expect_segv) {
        segv_seen = 1;
        syscall3(SYS_MPROTECT, repair_page, repair_len, PROT_RW);
        return;
    }
    fail_exit("B: unexpected SIGSEGV");
}

static u8 fpattern(u64 i) {
    return (u8)((i * 31 + 7) & 0xFF);
}

static void phase_b(void) {
    /* 2 full pages of pattern, written before any baseline was taken. */
    static u8 buf[PAGE];
    s64 fd = syscall3(SYS_OPEN, (u64)"/tmp/h100.dat", O_RDWR_CREAT_TRUNC, 0666);
    if (fd < 0) fail_exit("B open for write");
    for (u64 off = 0; off < 2 * PAGE; off += PAGE) {
        for (u64 i = 0; i < PAGE; i++) buf[i] = fpattern(off + i);
        if (syscall3(SYS_WRITE, (u64)fd, (u64)buf, PAGE) != (s64)PAGE)
            fail_exit("B write pattern");
    }
    syscall1(SYS_CLOSE, (u64)fd);

    struct ksigaction act = { segv_handler, 0, 0, 0 };
    if (syscall3(SYS_SIGACTION, SIGSEGV, (u64)&act, 0) != 0)
        fail_exit("B sigaction");

    fd = syscall3(SYS_OPEN, (u64)"/tmp/h100.dat", O_RDONLY, 0);
    if (fd < 0) fail_exit("B open for mmap");
    /* PROT_NONE from the start: no page is ever faulted, every leaf PTE of
     * the region stays zero — only the region metadata records prot=0. */
    const s64 base = syscall6(SYS_MMAP, 0, 2 * PAGE, PROT_NONE, MAP_PRIVATE, (u64)fd, 0);
    if (base <= 0) fail_exit("B mmap PROT_NONE");
    syscall1(SYS_CLOSE, (u64)fd);
    volatile u8 *p = (volatile u8 *)base;

    /* B1: first access (read) must SIGSEGV, not demand-fill read-only.
     * The handler repairs page 0; the retry must serve the file's bytes. */
    expect_segv = 1;
    segv_seen = 0;
    repair_page = (u64)base;
    repair_len = PAGE;
    volatile u8 v0 = p[0];
    expect_segv = 0;
    if (!segv_seen) fail_exit("B1: PROT_NONE first access did not SIGSEGV");
    if (v0 != fpattern(0)) fail_exit("B1: repaired page serves wrong contents");

    /* Page 1 was never repaired: still PROT_NONE, still a zero PTE. */
    expect_segv = 1;
    segv_seen = 0;
    repair_page = (u64)base + PAGE;
    repair_len = PAGE;
    volatile u8 v1 = p[PAGE];
    expect_segv = 0;
    if (!segv_seen) fail_exit("B1: second PROT_NONE page did not SIGSEGV");
    if (v1 != fpattern(PAGE)) fail_exit("B1: repaired page 1 serves wrong contents");

    /* B2: mprotect RW without an intervening access — demand fill follows
     * the new prot; a write stays private (COW), the file is unchanged. */
    if (syscall3(SYS_MPROTECT, (u64)base, 2 * PAGE, PROT_RW) != 0)
        fail_exit("B2 mprotect RW");
    expect_segv = 0;
    p[123] = 0xAA;
    if (p[123] != 0xAA) fail_exit("B2 write not visible");
    if (p[4097] != fpattern(4097)) fail_exit("B2 page 1 contents");
    const s64 vfd = syscall3(SYS_OPEN, (u64)"/tmp/h100.dat", O_RDONLY, 0);
    if (vfd < 0) fail_exit("B2 reopen");
    u8 one = 0;
    if (syscall4(SYS_PREAD, (u64)vfd, (u64)&one, 1, 123) != 1)
        fail_exit("B2 pread");
    if (one != fpattern(123)) fail_exit("B2 file changed by MAP_PRIVATE write");
    syscall1(SYS_CLOSE, (u64)vfd);

    if (syscall3(SYS_MUNMAP, (u64)base, 2 * PAGE, 0) != 0) fail_exit("B munmap");
    print("hello100:   B PROT_NONE first-access SIGSEGV ok\n");
}

/* ── A3: swap slots reclaimed by munmap of evicted regions ── */
static u64 window[WINDOW];
static s64 saved_floor = -1;
static u64 min_freeswap;

static void note_freeswap(void) {
    const u64 fs = freeswap_pages();
    if (fs < min_freeswap) min_freeswap = fs;
}

static void churn_rounds(u64 rounds) {
    for (u64 r = 0; r < rounds; r++) {
        const int slot = (int)(r % WINDOW);
        const s64 a = mmap_anon(REGION_LEN);
        if (a <= 0) fail_exit("A3/A4 churn mmap");
        touch_all((u64)a, REGION_PAGES, r);
        /* Evict the oldest region WITHOUT touching it again: any of its
         * pages that reclaim swapped out are destroyed as swap entries —
         * the slot must be freed (pre-fix: leaked, and the entry even
         * stayed behind in the page table). */
        if (window[slot] != 0) {
            if (syscall3(SYS_MUNMAP, window[slot], REGION_LEN, 0) != 0)
                fail_exit("A3/A4 churn munmap");
        }
        window[slot] = (u64)a;
        if ((r & 7) == 7) note_freeswap();
    }
    for (int i = 0; i < WINDOW; i++) {
        if (window[i] != 0) {
            if (syscall3(SYS_MUNMAP, window[i], REGION_LEN, 0) != 0)
                fail_exit("A3/A4 drain munmap");
            window[i] = 0;
        }
    }
}

static void phase_a3(void) {
    /* hello98/hello99 leave swap armed (syscallSwapoff is an intentional
     * no-op, §6.47): tolerate EBUSY like hello99 does. */
    const s64 sw = syscall3(SYS_SWAPON, (u64)"/dev/sda", 0, 0);
    if (sw != 0 && sw != -16 /* EBUSY */) fail_exit("A3 swapon scratch");

    const u64 freeram = freeram_pages();
    if (freeram < MARGIN_PAGES * 3) fail_exit("A3 not enough free RAM");
    saved_floor = syscall1(SYS_PMM_SET_RECLAIM_FLOOR, freeram - MARGIN_PAGES);

    const u64 base_swap = freeswap_pages();
    min_freeswap = base_swap;
    for (int i = 0; i < WINDOW; i++) window[i] = 0;

    churn_rounds(A3_ROUNDS);
    note_freeswap();

    if (min_freeswap >= base_swap)
        fail_exit("A3 swap never engaged (vacuous test)");
    const s64 leaked = (s64)base_swap - (s64)freeswap_pages();
    if (leaked > SWAP_SLACK) {
        print("hello100: A3 leaked slots=");
        print_dec(leaked);
        print("\n");
        fail_exit("A3 swap slots not reclaimed by munmap");
    }
    if (saved_floor >= 0) {
        syscall1(SYS_PMM_SET_RECLAIM_FLOOR, (u64)saved_floor);
        saved_floor = -1;
    }
    print("hello100:   A3 swap-slot munmap reclaim ok\n");
}

/* ── A4: swap slots reclaimed by process exit ── */
static u64 a4_base_swap; /* handed to the child through fork */

static void phase_a4(void) {
    const u64 freeram = freeram_pages();
    if (freeram < MARGIN_PAGES * 3) fail_exit("A4 not enough free RAM");
    saved_floor = syscall1(SYS_PMM_SET_RECLAIM_FLOOR, freeram - MARGIN_PAGES);

    const u64 base_swap = freeswap_pages();
    a4_base_swap = base_swap;

    for (u64 c = 0; c < A4_CHILDREN; c++) {
        const s64 child = syscall1(SYS_FORK, 0);
        if (child < 0) fail_exit("A4 fork");
        if (child == 0) {
            /* The child must observe swap engagement itself — its sysinfo
             * reads see the global bitmap, but its min_freeswap copy dies
             * with it, so report engagement through the exit status. */
            min_freeswap = a4_base_swap;
            for (int i = 0; i < WINDOW; i++) window[i] = 0;
            churn_rounds(A4_ROUNDS);
            /* window drained above; keep a final live, half-evicted set so
             * destroyUserSpace — not munmap — does the slot teardown. */
            for (u64 r = 0; r < WINDOW; r++) {
                const s64 a = mmap_anon(REGION_LEN);
                if (a <= 0) break;
                touch_all((u64)a, REGION_PAGES, r);
                if ((r & 7) == 7) note_freeswap();
            }
            note_freeswap();
            syscall1(SYS_EXIT, min_freeswap < a4_base_swap ? 0 : 2);
            for (;;) {}
        }
        s64 status = 0;
        syscall3(SYS_WAITPID, (u64)-1, (u64)&status, 0);
        if (status == 2) fail_exit("A4 swap never engaged in child (vacuous test)");
        if (status != 0) fail_exit("A4 child status");
    }

    const s64 leaked = (s64)base_swap - (s64)freeswap_pages();
    if (leaked > SWAP_SLACK) {
        print("hello100: A4 leaked slots=");
        print_dec(leaked);
        print("\n");
        fail_exit("A4 swap slots not reclaimed by exit");
    }
    if (saved_floor >= 0) {
        syscall1(SYS_PMM_SET_RECLAIM_FLOOR, (u64)saved_floor);
        saved_floor = -1;
    }
    print("hello100:   A4 swap-slot exit reclaim ok\n");
}

void _start(void) {
    print("hello100: non-present PTE teardown reclaim + PROT_NONE first access\n");

    phase_a1();
    phase_a2();
    phase_a2b();
    phase_b();
    phase_a3();
    phase_a4();

    syscall3(SYS_SWAPOFF, (u64)"/dev/sda", 0, 0); /* intentional no-op (§6.47) */
    print("hello100: PASS (reservation frames + swap slots reclaimed; PROT_NONE SIGSEGV)\n");
    print("hello100 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
