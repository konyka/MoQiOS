/* test_malloc.c — host unit tests for the moqi_libc free-list allocator.
 *
 * The allocator core (src/malloc.c) grows its heap through the weak hook
 * __moqi_heap_grow(); this test overrides it with a static buffer, so the
 * alloc/free/reuse logic runs on the host without the brk syscall.
 */
#include <stdio.h>
#include <string.h>

#include "../include/errno.h"

/* Test heap: 1 MiB static buffer standing in for brk (page-aligned, like
 * the kernel's brk). */
static char test_heap[1 << 20] __attribute__((aligned(4096)));
static unsigned long test_heap_off;
static unsigned long test_grow_pad; /* bytes skipped before the next grown region, to pick its alignment */

/* Test hook: a fixed per-"thread" identity instead of the freestanding
 * %fs:0 / arch_prctl lookup, so the reentry tests can stage owner == self
 * deterministically on the host. */
static char test_self_token;
static int test_self_early; /* 1 = behave as before crt0 installed the thread pointer (identity 1) */
#define MOQI_MALLOC_SELF() (test_self_early ? (void *)1 : (void *)&test_self_token)

/* The size of the most recent memcpy made by the allocator, to catch a copy longer than the block it reads. */
static unsigned long last_copy_n;
static void *test_memcpy(void *d, const void *src, unsigned long n) { last_copy_n = n; return memcpy(d, src, n); }
#define memcpy test_memcpy

#define malloc moqi_malloc
#define free   moqi_free
#define calloc moqi_calloc
#define realloc moqi_realloc
#define reallocarray moqi_reallocarray
#define posix_memalign moqi_posix_memalign
#define aligned_alloc moqi_aligned_alloc
#define memalign moqi_memalign
#include "../src/malloc.c"
#undef memcpy

/* The allocator reports failure through errno; the test keeps one slot. */
static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

/* Strong override of the weak hook (declared in malloc.c above, so the
 * weak attribute is already visible here). */
void *__moqi_heap_grow(unsigned long bytes) {
    /* Subtraction form: test_heap_off + bytes would wrap for near-SIZE_MAX
     * requests, which the overflow tests above deliberately issue. */
    if (test_grow_pad <= sizeof(test_heap) - test_heap_off) { test_heap_off += test_grow_pad; }
    test_grow_pad = 0;
    if (bytes > sizeof(test_heap) - test_heap_off) return (void *)0;
    void *p = test_heap + test_heap_off;
    test_heap_off += bytes;
    return p;
}

static int failures;
static int checks;

/* Heap invariants: every linked header has its magic, the list is in address order and blocks do not overlap. */
static int heap_walk_ok(void) {
    for (struct block *b = heap_head; b; b = b->next) {
        if (b->magic != BLOCK_MAGIC) return 0;
        if ((char *)b < test_heap || (char *)(b + 1) + b->size > test_heap + sizeof test_heap) return 0;
        if (((unsigned long)(b + 1) & (ALIGN - 1)) != 0) return 0;
        if (b->next && (char *)(b + 1) + b->size > (char *)b->next) return 0;
    }
    return 1;
}

#define CHECK(cond) do { \
    checks++; \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    } \
} while (0)

int main(void) {
    /* Basic alloc: non-NULL, 16-byte aligned, writable */
    void *a = moqi_malloc(24);
    CHECK(a != 0);
    CHECK(((unsigned long)a & 15) == 0);
    memset(a, 0x5A, 24);

    /* Distinct live allocations don't overlap */
    void *b = moqi_malloc(24);
    CHECK(b != 0);
    CHECK(b != a);
    memset(b, 0xA5, 24);
    CHECK(((unsigned char *)a)[0] == 0x5A); /* a untouched by writing b */

    /* malloc(0) is legal and freeable */
    void *z = moqi_malloc(0);
    CHECK(z != 0);
    moqi_free(z);

    /* free + realloc same size reuses the freed block */
    moqi_free(a);
    void *c = moqi_malloc(24);
    CHECK(c == a);

    /* Smaller request may split the free block; must still not overlap b */
    moqi_free(c);
    void *d = moqi_malloc(8);
    CHECK(d == c);
    memset(d, 1, 8);
    CHECK(((unsigned char *)b)[0] == 0xA5);

    /* Coalescing: free neighbors, then a big alloc fits in the merged hole */
    void *e = moqi_malloc(8);
    moqi_free(d);
    moqi_free(e);
    void *f = moqi_malloc(40);
    CHECK(f == e); /* merged hole starts where e did (a's 32-byte block is too small) */

    /* calloc zeroes */
    int *arr = moqi_calloc(16, sizeof(int));
    CHECK(arr != 0);
    int sum = 0;
    for (int i = 0; i < 16; i++) sum |= arr[i];
    CHECK(sum == 0);

    /* free(NULL) is a no-op */
    moqi_free(0);
    CHECK(1);

    /* Large allocation still works (fresh grow) */
    void *big = moqi_malloc(100 * 1024);
    CHECK(big != 0);
    memset(big, 7, 100 * 1024);
    moqi_free(big);

    /* Exhaustion returns NULL rather than corrupting the heap */
    void *g = moqi_malloc(4UL << 20);
    CHECK(g == 0);
    void *h = moqi_malloc(16);
    CHECK(h != 0);

    /* Huge sizes must fail cleanly, not wrap align_up/grow into a tiny
     * block the caller believes is huge (heap-overflow primitive). */
    CHECK(moqi_malloc((size_t)-1) == 0);       /* SIZE_MAX */
    CHECK(moqi_malloc((size_t)-1 - 8) == 0);   /* wraps align_up to 0 */
    /* Largest non-rejected size still fails gracefully via grow's hook */
    CHECK(moqi_malloc((size_t)-1 - 15 - 32) == 0);
    /* Heap still healthy after the rejected huge requests */
    void *k = moqi_malloc(16);
    CHECK(k != 0);

    /* Header layout: the magic reuses padding, payloads stay 16-aligned */
    CHECK(sizeof(struct block) == 32);

    /* Double free is rejected and leaves the heap intact: the block is
     * reused exactly once, never handed out to two live owners. */
    unsigned long rej0 = free_rejected;
    void *df = moqi_malloc(48);
    void *df_guard = moqi_malloc(48); /* keeps df from merging forward */
    CHECK(df != 0 && df_guard != 0);
    moqi_free(df);
    moqi_free(df);
    CHECK(free_rejected == rej0 + 1);
    void *df1 = moqi_malloc(48);
    void *df2 = moqi_malloc(48);
    CHECK(df1 == df);
    CHECK(df2 != df1);
    memset(df1, 0x11, 48);
    memset(df2, 0x22, 48);
    CHECK(((unsigned char *)df1)[47] == 0x11);

    /* Free of a pointer whose header was swallowed by coalesce is rejected
     * and must not flip a flag inside the merged block's payload. */
    void *m1 = moqi_malloc(32);
    void *m2 = moqi_malloc(32);
    void *m_guard = moqi_malloc(32);
    CHECK(m1 && m2 && m_guard);
    moqi_free(m2);
    moqi_free(m1);              /* m1 absorbs m2's header */
    void *merged = moqi_malloc(64 + 32);
    CHECK(merged == m1);        /* the merged hole is live again */
    memset(merged, 0x33, 96);
    unsigned long rej1 = free_rejected;
    moqi_free(m2);              /* stale pointer into merged's payload */
    CHECK(free_rejected == rej1 + 1);
    int intact = 1;
    for (int i = 0; i < 96; i++) intact &= ((unsigned char *)merged)[i] == 0x33;
    CHECK(intact);
    /* merged is still in use: a fresh request must not land on it */
    void *after = moqi_malloc(32);
    CHECK(after != 0);
    CHECK((char *)after < (char *)merged || (char *)after >= (char *)merged + 96);

    /* Wild pointers: stack, misaligned payload, interior pointer */
    unsigned long rej2 = free_rejected;
    int on_stack[16] = {0};
    moqi_free(&on_stack[8]);
    moqi_free((char *)after + 1);
    moqi_free((char *)after + 16);
    CHECK(free_rejected == rej2 + 3);
    CHECK(on_stack[0] == 0 && on_stack[7] == 0);
    moqi_free(after);           /* the real pointer still frees */
    CHECK(free_rejected == rej2 + 3);
    CHECK(moqi_malloc(32) == after);

    /* A linked block whose header magic was clobbered (overflow from the
     * previous payload) is refused rather than trusted. */
    void *cl = moqi_malloc(32);
    CHECK(cl != 0);
    unsigned int saved_magic = ((struct block *)cl - 1)->magic;
    ((struct block *)cl - 1)->magic = 0x41414141U;
    unsigned long rej3 = free_rejected;
    moqi_free(cl);
    CHECK(free_rejected == rej3 + 1);
    CHECK(((struct block *)cl - 1)->free == 0);
    ((struct block *)cl - 1)->magic = saved_magic;
    moqi_free(cl);
    CHECK(free_rejected == rej3 + 1);

    /* Reentry (signal handler interrupting its own thread inside the
     * allocator): stage heap_owner == self as the interrupted holder. */
    void *r1 = moqi_malloc(32);
    void *r_guard = moqi_malloc(32);
    CHECK(r1 && r_guard);
    heap_owner = heap_self();
    CHECK(moqi_malloc(16) == 0);      /* malloc refuses, no deadlock */
    CHECK(moqi_calloc(2, 8) == 0);
    moqi_free(r1);                    /* free is parked, not applied */
    CHECK(deferred[0] == r1);
    CHECK(((struct block *)r1 - 1)->free == 0);
    heap_release();                   /* the owner's release drains it */
    CHECK(heap_owner == 0);
    CHECK(deferred[0] == 0);
    CHECK(((struct block *)r1 - 1)->free == 1);
    CHECK(moqi_malloc(32) == r1);

    /* More than DEFERRED_MAX reentrant frees: the excess leaks, counted */
    void *rs[DEFERRED_MAX + 2];
    for (int i = 0; i < DEFERRED_MAX + 2; i++) {
        rs[i] = moqi_malloc(16);
        CHECK(rs[i] != 0);
    }
    void *rs_guard = moqi_malloc(16);
    CHECK(rs_guard != 0);
    unsigned long leak0 = deferred_leaked;
    heap_owner = heap_self();
    for (int i = 0; i < DEFERRED_MAX + 2; i++) moqi_free(rs[i]);
    CHECK(deferred_leaked == leak0 + 2);
    heap_release();
    CHECK(heap_owner == 0);
    int drained = 1;
    for (int i = 0; i < DEFERRED_MAX; i++) drained &= deferred[i] == 0;
    CHECK(drained);
    CHECK(((struct block *)rs[0] - 1)->free == 1);
    CHECK(((struct block *)rs[DEFERRED_MAX] - 1)->free == 0); /* leaked */

    /* Heap still healthy after the reentry paths */
    void *post = moqi_malloc(16);
    CHECK(post != 0);
    moqi_free(post);

    /* ---- failure sets ENOMEM (glibc: malloc/calloc/realloc/reallocarray) ---- */
    errno_slot = 0;
    CHECK(moqi_malloc((size_t)-1) == 0 && errno_slot == ENOMEM);
    errno_slot = 0;
    CHECK(moqi_malloc((size_t)1 << 62) == 0 && errno_slot == ENOMEM);
    errno_slot = 0;
    CHECK(moqi_malloc(1 << 22) == 0 && errno_slot == ENOMEM); /* more than the test heap holds */
    errno_slot = 0;
    CHECK(moqi_calloc((size_t)1 << 40, (size_t)1 << 40) == 0 && errno_slot == ENOMEM);
    errno_slot = 1234;
    void *ok = moqi_malloc(10);
    CHECK(ok != 0 && errno_slot == 1234); /* success leaves errno alone */
    errno_slot = 1234;
    CHECK(moqi_calloc(3, 0) != 0 && errno_slot == 1234);
    moqi_free(ok);
    heap_owner = heap_self();
    errno_slot = 0;
    CHECK(moqi_malloc(16) == 0 && errno_slot == ENOMEM); /* signal-handler reentry */
    heap_release();

    /* Before crt0 has installed the thread pointer there is no errno to write; failing must not touch it. */
    test_self_early = 1;
    errno_slot = 777;
    CHECK(moqi_malloc((size_t)-1) == 0 && errno_slot == 777);
    CHECK(moqi_calloc((size_t)1 << 40, (size_t)1 << 40) == 0 && errno_slot == 777);
    test_self_early = 0;

    /* ---- realloc ---- */
    errno_slot = 1234;
    unsigned char *r = moqi_realloc((void *)0, 10);
    CHECK(r != 0 && errno_slot == 1234);
    for (int i = 0; i < 10; i++) r[i] = (unsigned char)(i + 1);
    CHECK(moqi_realloc(r, 0) == 0);              /* frees, returns NULL, as glibc */
    CHECK(((struct block *)r - 1)->free == 1);   /* ...and really released the block */
    {
        unsigned long rj = free_rejected;
        errno_slot = 0;
        CHECK(moqi_realloc(r, 64) == 0 && errno_slot == EINVAL && free_rejected == rj + 1); /* a freed pointer is not resizable */
    }
    unsigned char *z0 = moqi_realloc((void *)0, 0);
    CHECK(z0 != 0);                              /* realloc(NULL, 0) is malloc(0) */
    moqi_free(z0);

    unsigned char *rg = moqi_malloc(100);
    unsigned char *rg_guard = moqi_malloc(100);
    CHECK(rg && rg_guard);
    memset(rg, 0x33, 100);
    CHECK(moqi_realloc(rg, 100) == rg);            /* same size: same block */
    CHECK(moqi_realloc(rg, 40) == rg);             /* shrink: same block */
    CHECK(rg[0] == 0x33 && rg[39] == 0x33);
    struct block *hole = ((struct block *)rg - 1)->next;
    CHECK(((struct block *)rg - 1)->size == 48 && hole->free && hole->size == 32 && (unsigned char *)(hole + 1) < rg_guard);
    unsigned char *rg2 = moqi_realloc(rg, 100);    /* grows back into the free hole, in place */
    CHECK(rg2 == rg && rg[0] == 0x33 && rg[39] == 0x33);
    /* Shrinking next to a free block merges the cut-off tail into it instead of leaving two free neighbors. */
    {
        unsigned char *sa = moqi_malloc(200);
        unsigned char *sb = moqi_malloc(200);
        unsigned char *sc = moqi_malloc(200);
        CHECK(sa && sb && sc);
        moqi_free(sb);
        struct block *ba = (struct block *)sa - 1;
        CHECK(ba->next == (struct block *)sb - 1 && ba->next->free);
        size_t sb_size = ba->next->size;
        CHECK(moqi_realloc(sa, 64) == sa);
        CHECK(ba->size == 64 && ba->next->free && ba->next->size == sb_size + (208 - 64));
        CHECK(ba->next->next == (struct block *)sc - 1);
        moqi_free(sa);
        moqi_free(sc);
    }
    unsigned char *rg3 = moqi_realloc(rg, 500);    /* neighbor is in use: must move, data kept */
    CHECK(rg3 != 0 && rg3 != rg);
    CHECK(last_copy_n == 112);                     /* it copied the old block's 112 bytes, not the new size */
    int kept = 1;
    for (int i = 0; i < 40; i++) kept &= rg3[i] == 0x33;
    CHECK(kept);
    memset(rg3, 0x44, 500);
    CHECK(((struct block *)rg_guard - 1)->free == 0);
    CHECK(((struct block *)rg - 1)->free == 1);   /* the old block was released */
    errno_slot = 0;
    CHECK(moqi_realloc(rg3, (size_t)-1) == 0 && errno_slot == ENOMEM);
    CHECK(rg3[0] == 0x44 && rg3[499] == 0x44);     /* failure leaves the original intact */
    errno_slot = 0;
    CHECK(moqi_realloc(rg3, 1 << 22) == 0 && errno_slot == ENOMEM);
    CHECK(rg3[0] == 0x44 && rg3[499] == 0x44);
    CHECK(moqi_realloc(rg3, 600) != 0);
    moqi_free(moqi_realloc(rg3, 600));
    unsigned long rej_before = free_rejected;
    errno_slot = 0;
    char stack_obj[64];
    CHECK(moqi_realloc(stack_obj, 128) == 0 && errno_slot == EINVAL && free_rejected == rej_before + 1);
    moqi_free(rg_guard);
    heap_owner = heap_self();
    void *held = test_heap + 4096; /* any pointer; reentry must refuse before touching it */
    errno_slot = 0;
    CHECK(moqi_realloc(held, 16) == 0 && errno_slot == ENOMEM);
    heap_release();

    /* The last block of the heap grows in place by asking the system for more, when that memory is contiguous. */
    {
        struct block *tail = heap_head;
        while (tail->next) tail = tail->next;
        unsigned char *tp = tail->free ? moqi_malloc(tail->size) : (unsigned char *)(tail + 1);
        CHECK(tp == (unsigned char *)(tail + 1));
        memset(tp, 0x5C, tail->size);
        size_t old_size = tail->size;
        unsigned long off0 = test_heap_off;
        unsigned char *tp2 = moqi_realloc(tp, old_size + 6000);
        CHECK(tp2 == tp && test_heap_off > off0);
        int tkeep = 1;
        for (size_t k = 0; k < old_size; k++) tkeep &= tp2[k] == 0x5C;
        CHECK(tkeep && ((struct block *)tp2 - 1)->size >= old_size + 6000);
        moqi_free(tp2);
    }

    /* A request that no existing free block can hold makes aligned allocation grow the heap. */
    {
        size_t biggest = 0;
        for (struct block *b = heap_head; b; b = b->next)
            if (b->free && b->size > biggest) biggest = b->size;
        size_t ask = biggest + 9000; /* beyond the minimum growth chunk, so the size of the grown region is exactly what aligned_locked asked for */
        /* The grown region's payload starts 32 bytes after the region; place it 16 bytes before a 512 boundary, the
         * worst case, where the room in front of the aligned address is more than an alignment's worth. */
        test_grow_pad = (unsigned long)((512 + 512 - 48 - (long)(test_heap_off % 512)) % 512);
        unsigned long off0 = test_heap_off;
        unsigned char *big = moqi_memalign(512, ask);
        CHECK(big != 0 && ((unsigned long)big & 511) == 0 && test_heap_off > off0);
        memset(big, 0x21, ask);
        CHECK(heap_walk_ok());
        moqi_free(big);
    }

    /* Size + alignment must not wrap around: nothing is asked of the system, and the heap stays as it was. */
    {
        void *wm = (void *)5;
        unsigned long off0 = test_heap_off;
        size_t near_limit = SIZE_LIMIT - 10;
        CHECK(moqi_posix_memalign(&wm, 64, near_limit) == ENOMEM && wm == (void *)5);
        errno_slot = 0;
        CHECK(moqi_memalign(4096, near_limit) == 0 && errno_slot == ENOMEM);
        errno_slot = 0;
        CHECK(moqi_aligned_alloc(32, SIZE_LIMIT) == 0 && errno_slot == ENOMEM);
        CHECK(moqi_posix_memalign(&wm, 64, SIZE_LIMIT - 64 - 1) == ENOMEM);
        CHECK(test_heap_off == off0);
    }

    /* ---- reallocarray ---- */
    errno_slot = 0;
    CHECK(moqi_reallocarray((void *)0, (size_t)1 << 40, (size_t)1 << 40) == 0 && errno_slot == ENOMEM);
    void *ra = moqi_malloc(16);
    memset(ra, 9, 16);
    errno_slot = 0;
    CHECK(moqi_reallocarray(ra, (size_t)1 << 63, 4) == 0 && errno_slot == ENOMEM && ((unsigned char *)ra)[15] == 9);
    unsigned char *ra2 = moqi_reallocarray(ra, 4, 16);
    CHECK(ra2 != 0 && ra2[0] == 9 && ra2[15] == 9);
    moqi_free(ra2);

    /* ---- aligned allocation: glibc's return codes and errno ---- */
    static const struct { size_t align; int posix_rc; int aa_ok; int aa_errno; } arows[] = {
        {0, EINVAL, 0, EINVAL}, {1, EINVAL, 1, 0}, {2, EINVAL, 1, 0}, {3, EINVAL, 0, EINVAL}, {4, EINVAL, 1, 0},
        {8, 0, 1, 0}, {12, EINVAL, 0, EINVAL}, {16, 0, 1, 0}, {24, EINVAL, 0, EINVAL}, {32, 0, 1, 0}, {64, 0, 1, 0},
        {4096, 0, 1, 0}, {65536, 0, 1, 0},
        {((size_t)1 << 63) + 1, EINVAL, 0, EINVAL}, {(size_t)-1, EINVAL, 0, EINVAL},
        {(size_t)1 << 63, ENOMEM, 0, ENOMEM}, {(size_t)1 << 62, ENOMEM, 0, ENOMEM}, {(size_t)1 << 40, ENOMEM, 0, ENOMEM},
    };
    for (unsigned i = 0; i < sizeof arows / sizeof arows[0]; i++) {
        void *m = (void *)5;
        int rc = moqi_posix_memalign(&m, arows[i].align, 10);
        if (rc != arows[i].posix_rc) { printf("posix_memalign(%zu): rc %d want %d\n", arows[i].align, rc, arows[i].posix_rc); failures++; }
        checks++;
        if (rc == 0) {
            CHECK(m != 0 && ((unsigned long)m & (arows[i].align - 1)) == 0);
            moqi_free(m);
        } else {
            CHECK(m == (void *)5);               /* *memptr is not touched on failure */
        }
        errno_slot = 1234;
        void *a = moqi_aligned_alloc(arows[i].align, 64);
        if ((a != 0) != arows[i].aa_ok) { printf("aligned_alloc(%zu): ok %d want %d\n", arows[i].align, a != 0, arows[i].aa_ok); failures++; }
        checks++;
        if (a) {
            CHECK(arows[i].align == 0 || ((unsigned long)a & (arows[i].align - 1)) == 0);
            CHECK(errno_slot == 1234);
            moqi_free(a);
        } else {
            CHECK(errno_slot == arows[i].aa_errno);
        }
    }
    void *zm = (void *)5;
    CHECK(moqi_posix_memalign(&zm, 64, 0) == 0 && zm != 0 && ((unsigned long)zm & 63) == 0);
    moqi_free(zm);
    zm = (void *)5;
    CHECK(moqi_posix_memalign(&zm, 64, (size_t)-1) == ENOMEM && zm == (void *)5);
    errno_slot = 0;
    void *zz = moqi_aligned_alloc(64, 0);
    CHECK(zz != 0 && ((unsigned long)zz & 63) == 0);
    moqi_free(zz);

    /* memalign: alignment 0 is 1, a non-power of two is rounded up to the next power of two, a huge one is EINVAL/ENOMEM */
    static const size_t mal[] = {0, 1, 3, 5, 24, 48, 100, 4096};
    for (unsigned i = 0; i < sizeof mal / sizeof mal[0]; i++) {
        void *m = moqi_memalign(mal[i], 32);
        CHECK(m != 0);
        size_t want = mal[i] <= 16 ? 1 : 1;
        while (want < mal[i]) want <<= 1;
        CHECK(((unsigned long)m & (want - 1)) == 0);
        moqi_free(m);
    }
    errno_slot = 0;
    CHECK(moqi_memalign(((size_t)1 << 63) + 1, 16) == 0 && errno_slot == EINVAL);
    errno_slot = 0;
    CHECK(moqi_memalign((size_t)-1, 16) == 0 && errno_slot == EINVAL);
    errno_slot = 0;
    CHECK(moqi_memalign((size_t)1 << 62, 16) == 0 && errno_slot == ENOMEM);
    errno_slot = 0;
    CHECK(moqi_memalign(64, (size_t)-1) == 0 && errno_slot == ENOMEM);
    errno_slot = 0;
    CHECK(moqi_aligned_alloc(64, (size_t)-1) == 0 && errno_slot == ENOMEM);

    /* Aligned blocks are ordinary blocks: usable, freeable, and what is left around them is reusable. */
    void *al1 = moqi_malloc(24);
    unsigned char *al2 = moqi_memalign(256, 100);
    void *al3 = moqi_malloc(24);
    CHECK(al1 && al2 && al3 && ((unsigned long)al2 & 255) == 0);
    memset(al2, 0x77, 100);
    moqi_free(al1);
    moqi_free(al3);
    CHECK(al2[0] == 0x77 && al2[99] == 0x77);
    moqi_free(al2);
    CHECK(heap_walk_ok());

    /* ---- randomized: malloc / realloc / memalign / free against a content model, heap invariants after every step ---- */
    enum { SLOTS = 48 };
    struct slot { unsigned char *p; size_t n; unsigned char tag; } sl[SLOTS];
    memset(sl, 0, sizeof sl);
    unsigned long long rng = 88172645463325252ULL;
    int bad = 0;
    for (int step = 0; step < 6000 && !bad; step++) {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
        unsigned op = (unsigned)(rng % 10);
        int i = (int)((rng >> 8) % SLOTS);
        size_t n = (size_t)((rng >> 20) % 700);
        struct slot *s = &sl[i];
        if (op <= 2) {                               /* malloc */
            if (s->p) moqi_free(s->p);
            s->p = moqi_malloc(n); s->n = s->p ? n : 0;
        } else if (op <= 5) {                        /* realloc */
            unsigned char *np = moqi_realloc(s->p, n);
            if (n == 0) { s->p = 0; s->n = 0; }
            else if (np) { size_t keep = s->n < n ? s->n : n; for (size_t k = 0; k < keep; k++) if (np[k] != s->tag) bad = 1; s->p = np; s->n = n; }
        } else if (op == 6) {                        /* memalign */
            if (s->p) moqi_free(s->p);
            size_t al = (size_t)32 << ((rng >> 40) % 6);
            s->p = moqi_memalign(al, n);
            s->n = s->p ? n : 0;
            if (s->p && ((unsigned long)s->p & (al - 1))) bad = 1;
        } else {                                     /* free */
            if (s->p) moqi_free(s->p);
            s->p = 0; s->n = 0;
        }
        if (s->p) { s->tag = (unsigned char)(step * 31 + 7); memset(s->p, s->tag, s->n); }
        for (int j = 0; j < SLOTS && !bad; j++)
            for (size_t k = 0; k < sl[j].n; k++) if (sl[j].p[k] != sl[j].tag) { bad = 1; break; }
        if (!heap_walk_ok()) bad = 2;
        if (bad) printf("random step %d op %u slot %d size %zu: bad=%d\n", step, op, i, n, bad);
    }
    CHECK(!bad);
    for (int j = 0; j < SLOTS; j++) if (sl[j].p) moqi_free(sl[j].p);
    CHECK(heap_walk_ok());

    printf("test_malloc: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
