// hello67 - fixed 64-entry VMA table fragmentation baseline.
// Maps ~40 disjoint 4KiB anonymous private RW regions through the raw mmap
// ABI (no MAP_FIXED), recording the returned addresses. It then unmaps every
// other one (20 holes -> 20 live regions) and re-maps 10 more, exercising the
// insert/merge scans that a fixed table must keep within its 64 entries.
// The fixed-table scan cost is then confirmed against the live kernel
// counters published at /proc/vma_stats (events / modeled_slots /
// avg_modeled_slots),
// parsed here with a small local decimal parser.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello67: FAIL " name "\n"); failures++; } } while (0)

#define PAGE_SIZE 4096
#define PROT_RW 3
#define MAP_PRIVATE 0x02
#define MAP_ANONYMOUS 0x20
#define MAP_PRIV_ANON (MAP_PRIVATE | MAP_ANONYMOUS)

#define N_MAPS 40      /* initial disjoint 4KiB regions */
#define N_KEEP 20      /* live regions after unmap-every-other */
#define N_REMAP 10     /* extra regions mapped back after fragmentation */

static long maps[N_MAPS];
static long remaps[N_REMAP];

static long mmap_anon(void) {
    return syscall6(SYS_mmap, 0, PAGE_SIZE, PROT_RW, MAP_PRIV_ANON, -1, 0);
}

static long munmap_raw(long addr, long len) {
    return syscall2(SYS_munmap, addr, len);
}

/* Minimal decimal parsing helpers (no libc number formatting needed). */
static int is_digit(char c) {
    return c >= '0' && c <= '9';
}

/* Parse `name=<digits>` at the start of `line`, advancing past the number. */
static int parse_u64_after(const char **line, const char *name, unsigned long *value) {
    const char *p = *line;
    while (*name) {
        if (*p != *name) return 0;
        p++;
        name++;
    }
    if (*p != '=') return 0;
    p++;
    if (!is_digit(*p)) return 0;
    unsigned long v = 0;
    while (is_digit(*p)) {
        v = v * 10 + (unsigned long)(*p - '0');
        p++;
    }
    *line = p;
    *value = v;
    return 1;
}

static int parse_vma_stats(const char *line, unsigned long *events,
                           unsigned long *modeled_slots,
                           unsigned long *avg_modeled_slots) {
    if (!parse_u64_after(&line, "events", events) || *line++ != ' ') return 0;
    if (!parse_u64_after(&line, "modeled_slots", modeled_slots) || *line++ != ' ') return 0;
    if (!parse_u64_after(&line, "avg_modeled_slots", avg_modeled_slots)) return 0;
    /* Newer kernels append visited-slot fields; the legacy contract only
     * requires the three baseline fields and accepts that extension. */
    return *line == '\n' || *line == '\0' || *line == ' ';
}

/* All entries between lo and hi (inclusive) must be page-aligned and
 * mutually disjoint: |a_i - a_j| >= PAGE_SIZE for every i != j. */
static int pages_disjoint(int lo, int hi) {
    for (int i = lo; i <= hi; i++) {
        if (maps[i] <= 0 || (maps[i] & (PAGE_SIZE - 1)) != 0) return 0;
        for (int j = i + 1; j <= hi; j++) {
            long d = maps[i] - maps[j];
            if (d < 0) d = -d;
            if (d < PAGE_SIZE) return 0;
        }
    }
    return 1;
}

static int page_valid_and_distinct(long page, int prior_remaps) {
    if (page <= 0 || (page & (PAGE_SIZE - 1)) != 0) return 0;
    for (int i = 0; i < N_MAPS; i++) {
        if (maps[i] == 0) continue;
        long d = page - maps[i];
        if (d < 0) d = -d;
        if (d < PAGE_SIZE) return 0;
    }
    for (int i = 0; i < prior_remaps; i++) {
        long d = page - remaps[i];
        if (d < 0) d = -d;
        if (d < PAGE_SIZE) return 0;
    }
    return 1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    print("hello67: start\n");

    /* 1. Map N_MAPS disjoint anonymous private RW pages. */
    for (int i = 0; i < N_MAPS; i++) {
        maps[i] = mmap_anon();
        CHECK(maps[i] > 0, "anonymous page mapped");
    }
    CHECK(pages_disjoint(0, N_MAPS - 1), "all 40 maps page-aligned and disjoint");

    /* 2. Fragmentation: unmap every other region -> 20 live, 20 holes. */
    int unmapped = 0;
    for (int i = 1; i < N_MAPS; i += 2) {
        if (munmap_raw(maps[i], PAGE_SIZE) == 0) {
            maps[i] = 0;
            unmapped++;
        }
    }
    CHECK(unmapped == N_KEEP, "unmapped every other region");

    /* 3. Re-map N_REMAP pages to exercise insert/merge scans over the holes. */
    int remapped = 0;
    for (int i = 0; i < N_REMAP; i++) {
        long p = mmap_anon();
        if (p > 0) {
            CHECK(page_valid_and_distinct(p, remapped), "remap page-aligned and distinct");
            remaps[remapped] = p;
            remapped++;
        }
    }
    CHECK(remapped == N_REMAP, "re-mapped 10 pages into fragmented table");

    /* 4. Count live regions after unmap+remap. */
    int live = remapped;
    for (int i = 0; i < N_MAPS; i++) {
        if (maps[i] != 0) live++;
    }
    CHECK(live <= N_MAPS, "live regions stay within 40");

    /* 5. Read the runtime scan statistics produced by this workload. */
    char stats_buf[128];
    long stats_fd = open("/proc/vma_stats", O_RDONLY, 0);
    CHECK(stats_fd >= 0, "open /proc/vma_stats");
    if (stats_fd >= 0) {
        long nread = read((int)stats_fd, stats_buf, sizeof(stats_buf) - 1);
        CHECK(nread > 0, "read /proc/vma_stats");
        if (nread > 0) {
            stats_buf[nread] = '\0';
            unsigned long events = 0;
            unsigned long modeled_slots = 0;
            unsigned long avg_modeled_slots = 0;
            CHECK(parse_vma_stats(stats_buf, &events, &modeled_slots,
                                  &avg_modeled_slots),
                  "parse /proc/vma_stats");
            CHECK(events > 0, "vma events recorded");
            CHECK(modeled_slots >= events, "modeled slots cover event count");
            CHECK(avg_modeled_slots == 64, "fixed table model is 64 slots");
            printf("hello67: vma fragments=20 events=%lu modeled_slots=%lu avg_modeled_slots=%lu\n",
                   events, modeled_slots, avg_modeled_slots);
        }
        CHECK(close((int)stats_fd) == 0, "close /proc/vma_stats");
    }

    /* 6. Clean up everything so later tests start with a clear table. */
    for (int i = 0; i < N_MAPS; i++) {
        if (maps[i] != 0) munmap_raw(maps[i], PAGE_SIZE);
    }
    for (int i = 0; i < remapped; i++) munmap_raw(remaps[i], PAGE_SIZE);

    if (failures == 0) {
        print("hello67: PASS\nhello67 done\n");
        _exit(0);
    }
    print("hello67: FAIL\nhello67 done\n");
    _exit(1);
}
