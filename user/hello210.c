/* hello210: mappings belong to the address space, not to a thread. A region mapped by one CLONE_VM thread must be
 * visible to, and changeable by, every other thread of the process: munmap, mprotect, mremap, madvise and mlock from a
 * thread other than the one that mapped it. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/mman.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello210:   ok   " : "hello210:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

#define PG 4096
static void *volatile region;
static volatile long region_pages = 4;
static volatile long result;
static volatile int err;

static void *map_thread(void *arg) {
    (void)arg;
    region_pages = 4;
    region = mmap(0, 4 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region != MAP_FAILED) memset(region, 0x41, 4 * PG);
    return (void *)0;
}
static void *unmap_thread(void *arg) {
    (void)arg;
    errno = 0;
    result = munmap(region, region_pages * PG);
    err = errno;
    return (void *)0;
}
static void *protect_thread(void *arg) {
    errno = 0;
    result = mprotect(region, 4 * PG, PROT_READ);
    err = errno;
    return (void *)0;
}
static void *remap_thread(void *arg) {
    (void)arg;
    errno = 0;
    region = mremap(region, 4 * PG, 8 * PG, MREMAP_MAYMOVE);
    err = errno;
    if (region != MAP_FAILED) region_pages = 8;
    return (void *)0;
}
static void *lock_thread(void *arg) {
    (void)arg;
    errno = 0;
    result = mlock(region, 4 * PG);
    err = errno;
    return (void *)0;
}

/* Thread slots are reclaimed asynchronously, so a burst of short-lived threads can find the table momentarily full;
 * creating one then fails with an error. Retry until a slot frees up instead of joining a thread that never started. */
static int create_failures;
static void run(void *(*fn)(void *)) {
    pthread_t t;
    for (int tries = 0; tries < 100000; tries++) {
        if (pthread_create(&t, (void *)0, fn, (void *)0) == 0) {
            pthread_join(t, (void **)0);
            return;
        }
        create_failures++;
        yield();
    }
    print("hello210: could not start a thread\n");
    failures++;
}

static void *madvise_thread(void *arg) {
    (void)arg;
    errno = 0;
    result = madvise(region, 4 * PG, MADV_DONTNEED);
    err = errno;
    return (void *)0;
}
static void *mincore_thread(void *arg) {
    (void)arg;
    unsigned char vec[4];
    errno = 0;
    result = mincore(region, 4 * PG, vec);
    err = errno;
    return (void *)0;
}
static void *overlap_thread(void *arg) {
    (void)arg;
    errno = 0;
    void *p = mmap(region, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    result = (p == MAP_FAILED) ? -1 : 0;
    err = errno;
    if (p != MAP_FAILED) munmap(p, PG);
    return (void *)0;
}
static void *mapper_reuse_thread(void *arg) {
    (void)arg;
    /* The mapper thread's own view after another thread unmapped: a fresh mapping must not collide. */
    void *p = mmap(0, 4 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    result = (p == MAP_FAILED) ? -1 : (long)p;
    return (void *)0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello210: mappings shared by CLONE_VM threads\n");

    run(map_thread);
    check(region != MAP_FAILED && region != (void *)0, "A: a thread maps 4 pages");
    check(((unsigned char *)region)[0] == 0x41 && ((unsigned char *)region)[4 * PG - 1] == 0x41, "A: and the creator can read what it wrote");

    run(protect_thread);
    check(result == 0, "B: a thread other than the mapper can mprotect it");
    run(lock_thread);
    check(result == 0, "B: and mlock it");
    munlock(region, 4 * PG);
    mprotect(region, 4 * PG, PROT_READ | PROT_WRITE);
    run(mincore_thread);
    check(result == 0, "B: and mincore it");
    run(overlap_thread);
    check(result == -1 && err == EEXIST, "B: a MAP_FIXED_NOREPLACE over it from another thread is EEXIST");
    run(madvise_thread);
    check(result == 0, "B: and madvise(MADV_DONTNEED) it");
    memset(region, 0x41, 4 * PG);

    void *keep = region;
    void *mid = region;
    run(remap_thread);
    check(region != MAP_FAILED, "C: mremap grows it to 8 pages from another thread");
    check(region != MAP_FAILED && ((unsigned char *)region)[0] == 0x41 && ((unsigned char *)region)[4 * PG - 1] == 0x41, "C: keeping the contents");
    (void)mid;
    if (region == MAP_FAILED) region = keep;

    void *mine = mmap(0, 2 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(mine != MAP_FAILED, "D: the creator maps 2 pages of its own");

    long size = (region != MAP_FAILED && region != keep) ? 8 * PG : 4 * PG;
    (void)size;
    run(unmap_thread);
    check(result == 0, "E: a thread other than the mapper can munmap it");
    errno = 0;
    run(overlap_thread);
    check(result == 0, "E: and the address is free again for a thread that did not map it");
    run(mapper_reuse_thread);
    check(result != -1, "E: a mapping made afterwards does not collide with the stale view");

    /* The creator's own view must follow another thread's munmap: its table may not keep a stale entry. */
    void *own = mmap(0, 4 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    region = own;
    region_pages = 4;
    run(unmap_thread);
    check(result == 0, "G: another thread unmaps a region the creator mapped");
    errno = 0;
    void *back = mmap(own, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    check(back == own, "G: and the creator can map there again (no stale entry in its own view)");
    if (back != MAP_FAILED) munmap(back, PG);
    errno = 0;
    check(munmap(own, 4 * PG) == 0, "G: munmap of an already-unmapped range is fine");

    long ok = 1;
    for (int i = 0; i < 20; i++) {
        run(map_thread);
        if (region == MAP_FAILED) { ok = 0; break; }
        run(unmap_thread);
        if (result != 0) { ok = 0; break; }
    }
    check(ok, "F: twenty rounds of map in one thread, unmap in another");
    check(munmap(mine, 2 * PG) == 0, "F: the creator's own mapping is still unmappable");

    { char m[64]; snprintf(m, sizeof m, "hello210: create retries=%d\n", create_failures); print(m); }
    print(failures == 0 ? "hello210: PASS\n" : "hello210: FAIL\n");
    return failures;
}
