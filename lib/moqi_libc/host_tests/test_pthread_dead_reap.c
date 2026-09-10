/* test_pthread_dead_reap.c — host test for the pthread_exit/pthread_detach
 * dead-stack push race (src/dead_reap.h, used by src/pthread.c).
 *
 * Both sides do "store my flag, then load yours". On x86 TSO the
 * interleaving exit:store state=1 → detach:TAS detached=1 → both loads see
 * each other is legal, and without an ownership claim both sides push the
 * same TCB onto the dead-stack list (dead_next self-loop → infinite loop
 * and double-free in dead_drain). This test drives the extracted decision
 * logic through both sequential orderings and the both-visible
 * interleaving, asserting the TCB is pushed exactly once each time.
 */
#include <stdio.h>

#include "../src/dead_reap.h"

/* Stand-in TCB: just the fields the exit/detach race touches, plus a push
 * counter playing the role of dead_push. */
struct fake_tcb {
    volatile int state;         /* 0=running 1=done */
    volatile int detached;
    volatile int dead_claimed;
    volatile int join_claimed;  /* join owns the block: exit must not push */
    int pushes;
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

/* Mirrors pthread_exit: thread stored state=1, then reaps itself iff it
 * observes detached. */
static void exit_side(struct fake_tcb *t) {
    if (dead_reap_on_exit(&t->detached, &t->join_claimed, &t->dead_claimed)) t->pushes++;
}

/* Mirrors pthread_detach: detach stored detached=1, then reaps iff it
 * observes state==1. */
static void detach_side(struct fake_tcb *t) {
    if (dead_reap_on_detach(&t->state, &t->dead_claimed)) t->pushes++;
}

int main(void) {
    /* exit-then-detach: exit sees detached==0 (no push); the later detach
     * sees state==1 and must be the one to push. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0 };
        t.state = 1;
        exit_side(&t);
        t.detached = 1;
        detach_side(&t);
        CHECK(t.pushes == 1);
    }

    /* detach-then-exit: detach sees state==0 (no push); the exiting thread
     * sees detached==1 and must be the one to push. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0 };
        t.detached = 1;
        detach_side(&t);
        t.state = 1;
        exit_side(&t);
        CHECK(t.pushes == 1);
    }

    /* Both-visible interleaving (the TSO double-push): both stores landed
     * before either load, so both sides observe each other. Exactly one
     * may win the claim. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0 };
        t.state = 1;
        t.detached = 1;
        exit_side(&t);
        detach_side(&t);
        CHECK(t.pushes == 1);
    }

    /* Same interleaving, opposite arrival order at the claim: detach wins,
     * exit must back off. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0 };
        t.state = 1;
        t.detached = 1;
        detach_side(&t);
        exit_side(&t);
        CHECK(t.pushes == 1);
    }

    /* Joinable thread (never detached): nobody pushes; join owns the
     * stack block, as before. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0 };
        t.state = 1;
        exit_side(&t);
        CHECK(t.pushes == 0);
        CHECK(t.dead_claimed == 0);
    }

    /* Detached but join-claimed (detach backed off under a racing join):
     * exit must not push — the block belongs to join. */
    {
        struct fake_tcb t = { 0, 0, 0, 0, 0 };
        t.state = 1;
        CHECK(join_claim_acquire(&t.detached, &t.join_claimed) == 0);
        t.detached = 1;
        CHECK(join_claim_held(&t.join_claimed) != 0);
        exit_side(&t);
        CHECK(t.pushes == 0);
        CHECK(t.dead_claimed == 0);
    }

    printf("test_pthread_dead_reap: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
