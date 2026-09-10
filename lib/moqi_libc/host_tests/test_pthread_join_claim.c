/* test_pthread_join_claim.c — host test for the pthread_join/pthread_detach
 * ownership race (src/dead_reap.h join-claim protocol, used by
 * src/pthread.c).
 *
 * pthread_join used to re-check t->detached after the futex wait and then
 * read t->retval / free t->alloc_base. A concurrent pthread_detach could
 * already have dead_push'ed the TCB and a third thread's pthread_create
 * could have dead_drain'ed (freed) the block, so the post-wait guard read
 * recycled memory and join could free an allocation it did not own
 * (double-free / UAF write). The fix claims join ownership BEFORE waiting:
 * join CAS-claims join_claimed at entry (-EINVAL if already claimed or
 * detached), detach returns -EINVAL without pushing when a join holds the
 * claim, and exit skips the dead-stack push while a join owns the block.
 *
 * These tests drive the extracted decision logic through the relevant
 * interleavings deterministically, asserting who pushes / frees each time.
 */
#include <stdio.h>

#include "../src/dead_reap.h"

/* Stand-in TCB: the fields the join/detach/exit protocol touches, plus
 * push/free counters playing the roles of dead_push and free(alloc_base). */
struct fake_tcb {
    volatile int state;         /* 0=running 1=done */
    volatile int detached;
    volatile int dead_claimed;
    volatile int join_claimed;
    int pushes;
    int frees;
};

static int failures;
static int checks;

#define CHECK(cond) do { \
    checks++; \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    } \
} while (0)

/* Mirrors pthread_join's claim + post-wait ownership (wait itself elided;
 * tests pre-set state). Returns the join result. */
static int join_side(struct fake_tcb *t) {
    if (join_claim_acquire(&t->detached, &t->join_claimed) != 0) return -22;
    t->frees++;                 /* read retval + free(alloc_base) */
    return 0;
}

/* Mirrors pthread_detach verbatim: TAS detached, back off on join claim,
 * otherwise reap an already-exited thread. */
static int detach_side(struct fake_tcb *t) {
    if (__sync_lock_test_and_set(&t->detached, 1) != 0) return -22;
    if (join_claim_held(&t->join_claimed)) return -22;
    if (dead_reap_on_detach(&t->state, &t->dead_claimed)) t->pushes++;
    return 0;
}

/* Mirrors pthread_exit: store state=1, then self-reap iff detached and no
 * join owns the block. */
static void exit_side(struct fake_tcb *t) {
    __atomic_store_n(&t->state, 1, __ATOMIC_SEQ_CST);
    if (dead_reap_on_exit(&t->detached, &t->join_claimed, &t->dead_claimed))
        t->pushes++;
}

int main(void) {
    /* The audited defect: join claims first, detach arrives while join
     * waits, thread exits. Detach must return -EINVAL and never push;
     * exit must not push either; join alone frees. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0, 0 };
        CHECK(join_side(&t) == 0);
        CHECK(detach_side(&t) == -22);
        exit_side(&t);
        CHECK(t.pushes == 0);
        CHECK(t.frees == 1);
    }

    /* Same, but the thread had already exited before detach arrived:
     * still no push, join still the sole owner. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0, 0 };
        CHECK(join_side(&t) == 0);
        __atomic_store_n(&t.state, 1, __ATOMIC_SEQ_CST);
        CHECK(detach_side(&t) == -22);
        CHECK(t.pushes == 0);
        CHECK(t.frees == 1);
    }

    /* detach-then-join (running thread): join must return -EINVAL and
     * never touch the block; the exiting thread reaps itself. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0, 0 };
        CHECK(detach_side(&t) == 0);
        CHECK(join_side(&t) == -22);
        exit_side(&t);
        CHECK(t.pushes == 1);
        CHECK(t.frees == 0);
    }

    /* detach-then-join after the thread already exited: detach pushes,
     * join backs off without freeing (the old code's double-free). */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0, 0 };
        __atomic_store_n(&t.state, 1, __ATOMIC_SEQ_CST);
        CHECK(detach_side(&t) == 0);
        CHECK(t.pushes == 1);
        CHECK(join_side(&t) == -22);
        CHECK(t.frees == 0);
    }

    /* Double join: the second join fails the claim with -EINVAL; only the
     * first frees. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0, 0 };
        CHECK(join_side(&t) == 0);
        CHECK(join_side(&t) == -22);
        CHECK(t.pushes == 0);
        CHECK(t.frees == 1);
    }

    /* Normal joinable join, no detach at all: join owns and frees, nobody
     * pushes. Unchanged from before the fix. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0, 0 };
        exit_side(&t);
        CHECK(t.pushes == 0);
        CHECK(join_side(&t) == 0);
        CHECK(t.frees == 1);
    }

    /* Detach a running thread twice: second one still -EINVAL. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0, 0 };
        CHECK(detach_side(&t) == 0);
        CHECK(detach_side(&t) == -22);
        exit_side(&t);
        CHECK(t.pushes == 1);
    }

    printf("test_pthread_join_claim: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
