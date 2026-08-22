// hello73 - expanded VMA telemetry acceptance based on hello67.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
#define CHECK(c, n) do { if (!(c)) { print("hello73: FAIL " n "\n"); failures++; } } while (0)
#define PAGE_SIZE 4096
#define PROT_RW 3
#define MAP_PRIVATE 0x02
#define MAP_ANONYMOUS 0x20
#define MAP_PRIV_ANON (MAP_PRIVATE | MAP_ANONYMOUS)
#define N_MAPS 40
#define N_KEEP 20
#define N_REMAP 10

static long maps[N_MAPS];
static long remaps[N_REMAP];

static long mmap_anon(void) { return syscall6(SYS_mmap, 0, PAGE_SIZE, PROT_RW, MAP_PRIV_ANON, -1, 0); }
static long munmap_raw(long addr) { return syscall2(SYS_munmap, addr, PAGE_SIZE); }
static int digit(char c) { return c >= '0' && c <= '9'; }

static int parse_u64(const char **line, const char *name, unsigned long *value) {
    const char *p = *line;
    while (*name) { if (*p++ != *name++) return 0; }
    if (*p++ != '=' || !digit(*p)) return 0;
    unsigned long v = 0;
    while (digit(*p)) v = v * 10 + (unsigned long)(*p++ - '0');
    *line = p; *value = v; return 1;
}

static int parse_stats(const char *line, unsigned long *events,
                       unsigned long *modeled, unsigned long *avg_modeled,
                       unsigned long *visited, unsigned long *avg_visited) {
    if (!parse_u64(&line, "events", events) || *line++ != ' ') return 0;
    if (!parse_u64(&line, "modeled_slots", modeled) || *line++ != ' ') return 0;
    if (!parse_u64(&line, "avg_modeled_slots", avg_modeled) || *line++ != ' ') return 0;
    if (!parse_u64(&line, "visited_slots", visited) || *line++ != ' ') return 0;
    if (!parse_u64(&line, "avg_visited_slots", avg_visited)) return 0;
    return *line == '\n' || *line == '\0';
}

static int disjoint_maps(void) {
    for (int i = 0; i < N_MAPS; i++) {
        if (maps[i] <= 0 || (maps[i] & (PAGE_SIZE - 1)) != 0) return 0;
        for (int j = i + 1; j < N_MAPS; j++) {
            long d = maps[i] - maps[j]; if (d < 0) d = -d;
            if (d < PAGE_SIZE) return 0;
        }
    }
    return 1;
}

static int remap_distinct(long page, int count) {
    if (page <= 0 || (page & (PAGE_SIZE - 1)) != 0) return 0;
    for (int i = 0; i < N_MAPS; i++) if (maps[i] != 0) {
        long d = page - maps[i]; if (d < 0) d = -d;
        if (d < PAGE_SIZE) return 0;
    }
    for (int i = 0; i < count; i++) {
        long d = page - remaps[i]; if (d < 0) d = -d;
        if (d < PAGE_SIZE) return 0;
    }
    return 1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello73: start\n");
    for (int i = 0; i < N_MAPS; i++) { maps[i] = mmap_anon(); CHECK(maps[i] > 0, "anonymous page mapped"); }
    CHECK(disjoint_maps(), "maps page-aligned and disjoint");
    int unmapped = 0;
    for (int i = 1; i < N_MAPS; i += 2) if (munmap_raw(maps[i]) == 0) { maps[i] = 0; unmapped++; }
    CHECK(unmapped == N_KEEP, "unmapped every other region");
    int remapped = 0;
    for (int i = 0; i < N_REMAP; i++) { long p = mmap_anon(); if (p > 0) { CHECK(remap_distinct(p, remapped), "remap page distinct"); remaps[remapped++] = p; } }
    CHECK(remapped == N_REMAP, "re-mapped pages into fragmented table");

    char buf[160]; long fd = open("/proc/vma_stats", O_RDONLY, 0);
    CHECK(fd >= 0, "open /proc/vma_stats");
    if (fd >= 0) {
        long nread = read((int)fd, buf, sizeof(buf) - 1); CHECK(nread > 0, "read /proc/vma_stats");
        if (nread > 0) {
            buf[nread] = '\0';
            unsigned long events = 0, modeled = 0, avg_modeled = 0, visited = 0, avg_visited = 0;
            CHECK(parse_stats(buf, &events, &modeled, &avg_modeled, &visited, &avg_visited), "parse /proc/vma_stats");
            CHECK(events > 0, "vma events recorded");
            CHECK(modeled >= events * 64, "modeled slots cover events");
            CHECK(avg_modeled == 64, "average modeled slots is 64");
            CHECK(visited > 0, "visited slots recorded");
            CHECK(visited <= modeled, "visited slots do not exceed modeled slots");
            CHECK(avg_visited <= 64, "average visited slots is bounded");
            printf("hello73: vma fragments=20 events=%lu modeled_slots=%lu avg_modeled_slots=%lu visited_slots=%lu avg_visited_slots=%lu\n", events, modeled, avg_modeled, visited, avg_visited);
        }
        CHECK(close((int)fd) == 0, "close /proc/vma_stats");
    }
    for (int i = 0; i < N_MAPS; i++) if (maps[i] != 0) munmap_raw(maps[i]);
    for (int i = 0; i < remapped; i++) munmap_raw(remaps[i]);
    if (failures == 0) { print("hello73: PASS\nhello73 done\n"); _exit(0); }
    print("hello73: FAIL\nhello73 done\n"); _exit(1);
}
