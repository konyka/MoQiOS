/* test_malloc.c — host unit tests for the moqi_libc free-list allocator.
 *
 * The allocator core (src/malloc.c) grows its heap through the weak hook
 * __moqi_heap_grow(); this test overrides it with a static buffer, so the
 * alloc/free/reuse logic runs on the host without the brk syscall.
 */
#include <stdio.h>
#include <string.h>

/* Test heap: 1 MiB static buffer standing in for brk (page-aligned, like
 * the kernel's brk). */
static char test_heap[1 << 20] __attribute__((aligned(4096)));
static unsigned long test_heap_off;

/* Test hook: a fixed per-"thread" identity instead of the freestanding
 * %fs:0 / arch_prctl lookup, so the reentry tests can stage owner == self
 * deterministically on the host. */
static char test_self_token;
#define MOQI_MALLOC_SELF() ((void *)&test_self_token)

#define malloc moqi_malloc
#define free   moqi_free
#define calloc moqi_calloc
#include "../src/malloc.c"

/* Strong override of the weak hook (declared in malloc.c above, so the
 * weak attribute is already visible here). */
void *__moqi_heap_grow(unsigned long bytes) {
    /* Subtraction form: test_heap_off + bytes would wrap for near-SIZE_MAX
     * requests, which the overflow tests above deliberately issue. */
    if (bytes > sizeof(test_heap) - test_heap_off) return (void *)0;
    void *p = test_heap + test_heap_off;
    test_heap_off += bytes;
    return p;
}

static int failures;
static int checks;

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

    printf("test_malloc: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
