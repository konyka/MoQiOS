/* exit.c — atexit, exit and _Exit (see include/stdlib.h).
 *
 * The registered functions form a stack of blocks: the first block is static (so a program that registers a few handlers
 * never allocates), later ones come from malloc and go back to it when emptied. exit() pops from the top, so the function
 * registered last runs first, and calls it with the lock released: a handler may register another function (it runs next) or
 * call exit() itself (that call carries on with whatever is left, then the flush, then the process ends with its status).
 */
#include "../include/errno.h"
#include "../include/stdlib.h"
#include "../include/unistd.h"

#define EX_CHUNK 32

struct ex_block {
    struct ex_block *prev;
    int used;
    void (*fn[EX_CHUNK])(void);
};

static struct ex_block ex_first;
static struct ex_block *ex_top = &ex_first;
static volatile int ex_lk;

static void ex_lock(void) {
    unsigned int spins = 0;
    while (__atomic_exchange_n(&ex_lk, 1, __ATOMIC_ACQUIRE)) {
        if ((++spins & 63U) == 0) yield();
    }
}
static void ex_unlock(void) { __atomic_store_n(&ex_lk, 0, __ATOMIC_RELEASE); }

int atexit(void (*fn)(void)) {
    if (fn == (void (*)(void))0) {
        errno = EINVAL;
        return -1;
    }
    ex_lock();
    if (ex_top->used == EX_CHUNK) {
        ex_unlock();
        struct ex_block *b = (struct ex_block *)malloc(sizeof *b);
        if (b == (struct ex_block *)0) return -1; /* malloc set ENOMEM */
        b->used = 0;
        ex_lock();
        b->prev = ex_top;
        ex_top = b;
    }
    ex_top->fn[ex_top->used++] = fn;
    ex_unlock();
    return 0;
}

/* The function registered last and not yet run, or NULL. */
static void (*ex_pop(void))(void) {
    void (*fn)(void) = (void (*)(void))0;
    ex_lock();
    while (ex_top->used == 0 && ex_top->prev != (struct ex_block *)0) {
        struct ex_block *dead = ex_top;
        ex_top = dead->prev;
        ex_unlock();
        free(dead);
        ex_lock();
    }
    if (ex_top->used > 0) fn = ex_top->fn[--ex_top->used];
    ex_unlock();
    return fn;
}

/* Weak, so a program (or a host test) that does not link the stdio code still gets a working exit. */
extern int fflush_all(void) __attribute__((weak));

void exit(int code) {
    void (*fn)(void);
    while ((fn = ex_pop()) != (void (*)(void))0) fn();
    if (fflush_all) fflush_all();
    _exit(code);
}

void _Exit(int code) {
    _exit(code);
}
