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

#define malloc moqi_malloc
#define free   moqi_free
#define calloc moqi_calloc
#include "../src/malloc.c"

/* Strong override of the weak hook (declared in malloc.c above, so the
 * weak attribute is already visible here). */
void *__moqi_heap_grow(unsigned long bytes) {
    if (test_heap_off + bytes > sizeof(test_heap)) return (void *)0;
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

    printf("test_malloc: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
