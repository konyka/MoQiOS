/* hello566: mremap with an old_size that runs past the end of the mapping it starts in (POSIX/Linux, measured with glibc). Linux
 * only requires old_addr to fall inside a mapping; old_addr + old_size may extend past the mapping's end into a hole. The kernel
 * used to require the whole [old_addr, old_addr+old_size) range to lie inside one tracked region and returned EINVAL otherwise.
 * To make the page past the mapping a hole (not whatever the allocator put there), a 24-page span is reserved and all but the
 * first 8 pages are unmapped. A: a same-size remap of base+2pg, old_size 9 pages over the 8-page mapping, is a no-op returning
 * base+2pg with the mapping intact; B: a shrink of that oversize range to 3 pages returns base+2pg, keeps base+2..base+5 and
 * unmaps base+5..base+8; C: a far-oversize old_size (20 pages) shrunk to 1 page still only unmaps the pages that were mapped. */
#ifdef HOST
#define _GNU_SOURCE
#include <sys/mman.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
static void print(const char *s){ fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/mman.h"
#endif

static int failures;
static char msg[256];
static void check(int ok, const char *what) {
    print(ok ? "hello566:   ok   " : "hello566:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
#define PG 4096

/* An 8-page mapping with a guaranteed hole for the 16 pages after it: reserve 24, unmap the tail. */
static char *mapping_with_hole(void) {
    char *base = mmap(0, 24 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) return 0;
    munmap(base + 8 * PG, 16 * PG);
    memset(base, 'y', 8 * PG);
    return base;
}

int main(void) {
    print("hello566: mremap with an oversize old_size\n");
    unsigned char vec[1];

    /* A: same-size oversize remap is a no-op. */
    char *a = mapping_with_hole();
    if (!a) { print("hello566: FAIL mmap A\nhello566: FAIL\n"); return 1; }
    void *r = mremap(a + 2 * PG, 9 * PG, 9 * PG, 0);
    int intact = 1;
    for (int i = 0; i < 8 * PG; i++) if (a[i] != 'y') { intact = 0; break; }
    snprintf(msg, sizeof msg, "A: same-size oversize: ret=a+2pg? %d, mapping intact %d (1, 1)", r == a + 2 * PG, intact);
    check(r == a + 2 * PG && intact, msg);
    munmap(a, 8 * PG);

    /* B: shrink an oversize range to 3 pages; base+2..base+5 stay, base+5..base+8 go. */
    char *b = mapping_with_hole();
    if (!b) { print("hello566: FAIL mmap B\nhello566: FAIL\n"); return 1; }
    void *r2 = mremap(b + 2 * PG, 9 * PG, 3 * PG, 0);
    int kept = mincore(b + 2 * PG, PG, vec);
    int kept4 = mincore(b + 4 * PG, PG, vec);
    int gone = mincore(b + 5 * PG, PG, vec);
    snprintf(msg, sizeof msg, "B: shrink oversize: ret=b+2pg? %d, b+2pg mapped %d, b+4pg mapped %d, b+5pg gone %d (1,0,0,-1)",
             r2 == b + 2 * PG, kept, kept4, gone);
    check(r2 == b + 2 * PG && kept == 0 && kept4 == 0 && gone != 0, msg);
    check(b[2 * PG] == 'y' && b[4 * PG] == 'y', "B: the kept pages still hold their data");
    munmap(b, 5 * PG);

    /* C: a far-oversize old_size (20 pages) shrunk to 1 page. */
    char *c = mapping_with_hole();
    if (!c) { print("hello566: FAIL mmap C\nhello566: FAIL\n"); return 1; }
    void *r3 = mremap(c + 1 * PG, 20 * PG, 1 * PG, 0);
    int c_kept = mincore(c + 1 * PG, PG, vec);
    int c_gone = mincore(c + 2 * PG, PG, vec);
    snprintf(msg, sizeof msg, "C: shrink far-oversize to 1pg: ret=c+1pg? %d, c+1pg mapped %d, c+2pg gone %d (1,0,-1)",
             r3 == c + 1 * PG, c_kept, c_gone);
    check(r3 == c + 1 * PG && c_kept == 0 && c_gone != 0, msg);
    munmap(c, 2 * PG);

    print(failures ? "hello566: FAIL\n" : "hello566: PASS\n");
    return failures ? 1 : 0;
}
