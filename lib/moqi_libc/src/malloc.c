/* malloc.c — first-fit free-list allocator for MoQiOS user programs.
 *
 * The allocator core is syscall-free: it grows the heap through the weak
 * hook __moqi_heap_grow(bytes), which src/sbrk.c implements over the
 * kernel brk syscall. Host tests override the hook with a static buffer,
 * so the alloc/free/split/coalesce logic is host-testable.
 */
#include "../include/errno.h"
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

/* Every header currently linked into heap_head carries BLOCK_MAGIC; a
 * header swallowed by coalesce() has it cleared, so a stale pointer to it
 * (double free after merge) no longer validates. */
#define BLOCK_MAGIC 0x4d6f5169U /* "MoQi" */

struct block {
    size_t size;          /* payload bytes, excluding this header */
    int free;
    unsigned int magic;   /* BLOCK_MAGIC while linked; reuses the old _pad */
    struct block *next;
    void *_pad2;          /* pad the header to 32 so payloads stay 16-aligned */
};

_Static_assert(sizeof(struct block) % ALIGN == 0, "block header must keep payloads ALIGN-aligned");

static struct block *heap_head;

/* Debug counters (inspect with a debugger): frees rejected by validation,
 * and reentrant frees leaked because the deferred array was full. */
static unsigned long free_rejected;
static unsigned long deferred_leaked;

/* ── heap lock ───────────────────────────────────────────────────────
 * The lock word is the owner's thread identity (0 = unlocked), taken with
 * one CAS, so "who holds it" is never out of sync with "is it held". A
 * thread finding itself as owner can only be a signal handler interrupting
 * that thread's own critical section: spinning would wait on itself
 * forever, so malloc returns NULL and free defers the pointer instead.
 * Critical sections are short (no syscalls except grow's brk), so spinning
 * (with pause, and a yield now and then for uniprocessor) beats futexes. */
static void *volatile heap_owner;

#ifdef MOQI_MALLOC_SELF
/* Host tests supply a fixed identity. */
static void *heap_self(void) { return MOQI_MALLOC_SELF(); }
static void heap_yield(void) {}
#else
#include "../include/moqi_syscalls.h"
#define SYS_arch_prctl_v 472
#define ARCH_GET_FS_v    0x1003
/* Before crt0's __pthread_init_main installs FS the base is 0 and %fs:0
 * would fault; the process is still single-threaded with no handlers, so
 * a fixed id suffices. Once FS is seen set it stays set for the process
 * (pthread threads get theirs via CLONE_SETTLS), so the arch_prctl probe
 * runs only until then. Identity = TCB self pointer at %fs:0. */
static volatile int tcb_ready;
static void *heap_self(void) {
    if (!__atomic_load_n(&tcb_ready, __ATOMIC_RELAXED)) {
        unsigned long fs = 0;
        if (syscall2(SYS_arch_prctl_v, ARCH_GET_FS_v, (long)&fs) != 0 || fs == 0)
            return (void *)1;
        __atomic_store_n(&tcb_ready, 1, __ATOMIC_RELAXED);
    }
    void *t;
    __asm__ volatile ("movq %%fs:0, %0" : "=r"(t));
    return t ? t : (void *)1;
}
static void heap_yield(void) { syscall0(SYS_yield); }
#endif

/* Reentrant frees parked until the interrupted owner releases. Slots are
 * claimed/emptied with single atomic ops, so a handler pushing while the
 * owner drains on the same thread cannot lose or duplicate an entry. */
#define DEFERRED_MAX 8
static void *volatile deferred[DEFERRED_MAX];

/* Returns 1 once acquired, 0 if the calling thread already holds the lock
 * (signal-handler reentry): the caller must then not touch the heap. */
static int heap_acquire(void) {
    void *self = heap_self();
    unsigned int spins = 0;
    for (;;) {
        void *cur = __atomic_load_n(&heap_owner, __ATOMIC_RELAXED);
        if (cur == self) return 0;
        if (cur == (void *)0 &&
            __atomic_compare_exchange_n(&heap_owner, &cur, self, 0,
                                        __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
            return 1;
#if defined(__x86_64__) || defined(__i386__)
        __builtin_ia32_pause();
#endif
        if ((++spins & 1023U) == 0) heap_yield();
    }
}

static void free_locked(void *ptr);

static void heap_release(void) {
    /* Drain until a full pass finds nothing: a handler may push mid-drain.
     * One pushed after the last pass but before the store below stays
     * parked until the next release (delayed, not lost). */
    int again = 1;
    while (again) {
        again = 0;
        for (int i = 0; i < DEFERRED_MAX; i++) {
            void *p = __atomic_exchange_n(&deferred[i], (void *)0, __ATOMIC_RELAXED);
            if (p) {
                free_locked(p);
                again = 1;
            }
        }
    }
    __atomic_store_n(&heap_owner, (void *)0, __ATOMIC_RELEASE);
}

static void defer_free(void *ptr) {
    for (int i = 0; i < DEFERRED_MAX; i++) {
        void *empty = (void *)0;
        if (__atomic_compare_exchange_n(&deferred[i], &empty, ptr, 0,
                                        __ATOMIC_RELAXED, __ATOMIC_RELAXED))
            return;
    }
    __atomic_fetch_add(&deferred_leaked, 1, __ATOMIC_RELAXED);
}

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
    b->magic = BLOCK_MAGIC;
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
    rest->magic = BLOCK_MAGIC;
    rest->next = b->next;
    b->size = size;
    b->next = rest;
}

/* errno lives in the thread control block, which exists only once crt0 has installed FS; the early TCB allocation in
 * __pthread_init_main must not touch it (heap_self() is 1 until then). */
static void set_errno(int e) {
    if (heap_self() != (void *)1) errno = e;
}

/* Sizes whose align_up/header additions would wrap hand the caller a tiny block it believes is huge; they are refused.
 * The bound also keeps grow()'s payload + sizeof(struct block) from overflowing. */
#define SIZE_LIMIT ((size_t)-1 - (ALIGN - 1) - sizeof(struct block))

/* First fit, growing the heap when nothing fits; `want` is already rounded. Caller holds the heap lock. */
static void *malloc_locked(size_t want) {
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

void *malloc(size_t size) {
    if (size > SIZE_LIMIT) {
        set_errno(ENOMEM);
        return (void *)0;
    }
    size_t want = align_up(size == 0 ? 1 : size);

    if (!heap_acquire()) { /* reentered from a signal handler */
        set_errno(ENOMEM);
        return (void *)0;
    }
    void *p = malloc_locked(want);
    heap_release();
    if (!p) set_errno(ENOMEM);
    return p;
}

/* Merge each free block with its successor while both are free and
 * physically adjacent (grown regions are appended in address order). The
 * swallowed header loses its magic so it can never validate again. */
static void coalesce(void) {
    for (struct block *b = heap_head; b && b->next; b = b->next) {
        while (b->free && b->next && b->next->free &&
               (char *)(b + 1) + b->size == (char *)b->next) {
            struct block *gone = b->next;
            b->size += sizeof(struct block) + gone->size;
            b->next = gone->next;
            gone->magic = 0;
        }
    }
}

/* Only a pointer that is exactly the payload of a linked, in-use block
 * with an intact header is freed. Lookup compares addresses only, so wild
 * pointers (stack, unaligned, merged-away headers) are never dereferenced;
 * the magic check additionally refuses a header clobbered by an overflow.
 * Anything else is counted and ignored rather than corrupting the heap. */
static void free_locked(void *ptr) {
    for (struct block *b = heap_head; b; b = b->next) {
        if ((void *)(b + 1) != ptr) continue;
        if (b->magic != BLOCK_MAGIC || b->free) break;
        b->free = 1;
        coalesce();
        return;
    }
    free_rejected++;
}

void free(void *ptr) {
    if (ptr == (void *)0) return;
    if (!heap_acquire()) {
        defer_free(ptr); /* reentered from a signal handler */
        return;
    }
    free_locked(ptr);
    heap_release();
}

void *calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    if (size != 0 && total / size != nmemb) { /* overflow */
        set_errno(ENOMEM);
        return (void *)0;
    }
    void *p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

/* The block whose payload starts exactly at ptr and is in use, or NULL (counted as a rejected pointer). */
static struct block *find_live(void *ptr) {
    for (struct block *b = heap_head; b; b = b->next) {
        if ((void *)(b + 1) != ptr) continue;
        if (b->magic != BLOCK_MAGIC || b->free) break;
        return b;
    }
    free_rejected++;
    return (struct block *)0;
}

static int adjacent(const struct block *a, const struct block *b) {
    return (const char *)(a + 1) + a->size == (const char *)b;
}

/* Resize in place when the block shrinks, or when the free blocks right behind it (or fresh heap, if it is the last
 * block) cover the growth; otherwise move. The original is untouched unless the call succeeds. */
static void *realloc_locked(void *ptr, size_t want, int *err) {
    struct block *b = find_live(ptr);
    if (!b) {
        *err = EINVAL;
        return (void *)0;
    }
    if (b->size < want) {
        for (int tries = 0; tries < 2; tries++) {
            size_t avail = b->size;
            const struct block *last = b;
            const struct block *n = b->next;
            while (n && n->free && adjacent(last, n) && avail < want) {
                avail += sizeof(struct block) + n->size;
                last = n;
                n = n->next;
            }
            if (avail >= want) {
                while (b->size < want) {
                    struct block *gone = b->next;
                    b->size += sizeof(struct block) + gone->size;
                    b->next = gone->next;
                    gone->magic = 0;
                }
                break;
            }
            if (tries == 0 && n == (const struct block *)0 && grow(want - avail)) continue;
            break;
        }
    }
    if (b->size >= want) {
        split(b, want);
        coalesce();
        return ptr;
    }
    void *np = malloc_locked(want);
    if (!np) {
        *err = ENOMEM;
        return (void *)0;
    }
    memcpy(np, ptr, b->size);
    free_locked(ptr);
    return np;
}

void *realloc(void *ptr, size_t size) {
    if (ptr == (void *)0) return malloc(size);
    if (size == 0) {
        free(ptr);
        return (void *)0;
    }
    if (size > SIZE_LIMIT) {
        set_errno(ENOMEM);
        return (void *)0;
    }
    size_t want = align_up(size);
    if (!heap_acquire()) { /* reentered from a signal handler */
        set_errno(ENOMEM);
        return (void *)0;
    }
    int err = 0;
    void *p = realloc_locked(ptr, want, &err);
    heap_release();
    if (!p) set_errno(err);
    return p;
}

void *reallocarray(void *ptr, size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    if (size != 0 && total / size != nmemb) {
        set_errno(ENOMEM);
        return (void *)0;
    }
    return realloc(ptr, total);
}

/* A block whose payload starts at a multiple of `align` (a power of two above ALIGN). The first free block with room is
 * cut in two: the part before the aligned payload stays free, so nothing is lost and free() works on the result as on
 * any other. Caller holds the lock. */
static void *aligned_locked(size_t align, size_t want) {
    for (int tries = 0; tries < 2; tries++) {
        for (struct block *b = heap_head; b; b = b->next) {
            if (!b->free) continue;
            unsigned long p = (unsigned long)(b + 1);
            unsigned long a = (p + align - 1) & ~(unsigned long)(align - 1);
            if (a != p && a - p < sizeof(struct block)) a += align; /* no room for the new header before it */
            if (a < p || a - p > b->size || b->size - (a - p) < want) continue;
            if (a != p) {
                struct block *nb = (struct block *)(a - sizeof(struct block));
                nb->size = b->size - (a - p);
                nb->free = 1;
                nb->magic = BLOCK_MAGIC;
                nb->next = b->next;
                b->size = (size_t)(a - p) - sizeof(struct block);
                b->next = nb;
                b = nb;
            }
            split(b, want);
            b->free = 0;
            return (void *)(b + 1);
        }
        if (tries == 0 && !grow(want + align + sizeof(struct block))) break;
    }
    return (void *)0;
}

/* Returns 0 or an errno value; align is already known to be a power of two. */
static int aligned_alloc_impl(void **out, size_t align, size_t size) {
    if (align <= ALIGN) {
        void *p = malloc(size);
        if (!p) return ENOMEM;
        *out = p;
        return 0;
    }
    if (align > SIZE_LIMIT - sizeof(struct block) || size > SIZE_LIMIT - sizeof(struct block) - align) return ENOMEM;
    size_t want = align_up(size == 0 ? 1 : size);
    if (!heap_acquire()) return ENOMEM;
    void *p = aligned_locked(align, want);
    heap_release();
    if (!p) return ENOMEM;
    *out = p;
    return 0;
}

static int is_pow2(size_t n) { return n != 0 && (n & (n - 1)) == 0; }

int posix_memalign(void **memptr, size_t align, size_t size) {
    if (!is_pow2(align) || align % sizeof(void *) != 0) return EINVAL;
    void *p = (void *)0;
    int rc = aligned_alloc_impl(&p, align, size);
    if (rc == 0) *memptr = p;
    return rc;
}

void *aligned_alloc(size_t align, size_t size) {
    void *p = (void *)0;
    int rc = is_pow2(align) ? aligned_alloc_impl(&p, align, size) : EINVAL;
    if (rc != 0) {
        set_errno(rc);
        return (void *)0;
    }
    return p;
}

void *memalign(size_t align, size_t size) {
    if (align == 0) align = 1;
    if (!is_pow2(align)) {
        if (align > ((size_t)1 << (sizeof(size_t) * 8 - 1))) {
            set_errno(EINVAL);
            return (void *)0;
        }
        size_t up = 1;
        while (up < align) up <<= 1;
        align = up;
    }
    void *p = (void *)0;
    int rc = aligned_alloc_impl(&p, align, size);
    if (rc != 0) {
        set_errno(rc);
        return (void *)0;
    }
    return p;
}
