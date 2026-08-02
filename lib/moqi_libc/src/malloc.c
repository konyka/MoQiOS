/* malloc.c — first-fit free-list allocator for MoQiOS user programs.
 *
 * The allocator core is syscall-free: it grows the heap through the weak
 * hook __moqi_heap_grow(bytes), which src/sbrk.c implements over the
 * kernel brk syscall. Host tests override the hook with a static buffer,
 * so the alloc/free/split/coalesce logic is host-testable.
 */
#include "../include/stdlib.h"
#include "../include/string.h"

/* Grows the heap by `bytes` (page-rounded by the implementation) and
 * returns the start of the fresh region, or NULL on failure. Weak:
 * overridden by src/sbrk.c in freestanding builds, by tests on host. */
__attribute__((weak)) void *__moqi_heap_grow(size_t bytes);

#define ALIGN 16UL
#define MIN_SPLIT (sizeof(struct block) + ALIGN)
/* Grow at least a page at a time to amortize brk syscalls. */
#define GROW_CHUNK 4096UL

struct block {
    size_t size;          /* payload bytes, excluding this header */
    int free;
    int _pad;
    struct block *next;
    void *_pad2;          /* pad the header to 32 so payloads stay 16-aligned */
};

static struct block *heap_head;

static size_t align_up(size_t n) {
    return (n + ALIGN - 1) & ~(ALIGN - 1);
}

/* Append a fresh region as one free block at the end of the list. */
static struct block *grow(size_t payload) {
    size_t need = payload + sizeof(struct block);
    size_t ask = need < GROW_CHUNK ? GROW_CHUNK : align_up(need);
    void *mem = __moqi_heap_grow(ask);
    if (mem == (void *)0) return (struct block *)0;

    struct block *b = mem;
    b->size = ask - sizeof(struct block);
    b->free = 1;
    b->next = (struct block *)0;

    if (heap_head == (struct block *)0) {
        heap_head = b;
    } else {
        struct block *tail = heap_head;
        while (tail->next) tail = tail->next;
        tail->next = b;
    }
    return b;
}

static void split(struct block *b, size_t size) {
    if (b->size < size + MIN_SPLIT) return;
    struct block *rest = (struct block *)((char *)(b + 1) + size);
    rest->size = b->size - size - sizeof(struct block);
    rest->free = 1;
    rest->next = b->next;
    b->size = size;
    b->next = rest;
}

void *malloc(size_t size) {
    size_t want = align_up(size == 0 ? 1 : size);

    for (struct block *b = heap_head; b; b = b->next) {
        if (b->free && b->size >= want) {
            split(b, want);
            b->free = 0;
            return (void *)(b + 1);
        }
    }

    struct block *b = grow(want);
    if (b == (struct block *)0) return (void *)0;
    split(b, want);
    b->free = 0;
    return (void *)(b + 1);
}

/* Merge each free block with its successor while both are free and
 * physically adjacent (grown regions are appended in address order). */
static void coalesce(void) {
    for (struct block *b = heap_head; b && b->next; b = b->next) {
        while (b->free && b->next && b->next->free &&
               (char *)(b + 1) + b->size == (char *)b->next) {
            b->size += sizeof(struct block) + b->next->size;
            b->next = b->next->next;
        }
    }
}

void free(void *ptr) {
    if (ptr == (void *)0) return;
    struct block *b = (struct block *)ptr - 1;
    b->free = 1;
    coalesce();
}

void *calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    if (size != 0 && total / size != nmemb) return (void *)0; /* overflow */
    void *p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}
