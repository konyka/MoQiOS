/* hello228: a joined thread must be finished with its memory when pthread_join returns. join frees the thread's block (TCB and
 * stack) and the next pthread_create gets the same memory. This storm creates a thread, joins it, and at once allocates and
 * zeroes a block of the same size, thousands of times over; every worker also guards a canary array on its own stack (see
 * worker). A thread that is still running pthread_exit after join returned writes to the stack its successor is using. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello228:   ok   " : "hello228:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile long ran, corrupted;

/* The worker keeps a canary array in its own frame and checks it after spinning for a while. pthread_exit of the PREVIOUS thread
 * (whose block join has just freed and pthread_create has handed to this one) pushes a return address for its call to _exit
 * at the depth where this function's frame lives; if that late push lands after this thread has filled the canary, the
 * pattern no longer matches. */
static void *worker(void *arg) {
    volatile unsigned char canary[256];
    unsigned char pat = (unsigned char)(0x5a ^ (unsigned long)arg);
    for (int i = 0; i < 256; i++) canary[i] = pat;
    for (volatile int spin = 0; spin < 20000; spin++) {}
    int bad = 0;
    for (int i = 0; i < 256; i++) if (canary[i] != pat) bad = 1;
    if (bad) __atomic_add_fetch(&corrupted, 1, __ATOMIC_SEQ_CST);
    __atomic_add_fetch(&ran, 1, __ATOMIC_SEQ_CST);
    return arg;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello228: join then reuse the joined thread's block\n");
    int made = 0, bad_join = 0;
    for (long i = 1; i <= 4000; i++) {
        pthread_t t;
        int tries = 0, rc;
        while ((rc = pthread_create(&t, (void *)0, worker, (void *)i)) != 0 && tries < 100000) { tries++; yield(); }
        if (rc != 0) break;
        made++;
        void *rv = (void *)0;
        if (pthread_join(t, &rv) != 0 || rv != (void *)i) { bad_join++; continue; }
        unsigned char *p = (unsigned char *)malloc(64 * 1024);
        if (p) { memset(p, 0, 2048); free(p); }
    }
    check(made == 4000, "A: 4000 threads created");
    check(bad_join == 0, "A: every join returned the thread's value");
    check(ran == made, "A: every thread ran exactly once");
    { char m[64]; snprintf(m, sizeof m, "hello228: corrupted canaries=%ld\n", (long)corrupted); print(m); }
    check(corrupted == 0, "B: no worker found its stack changed under it by the thread that used the block before");
    print(failures == 0 ? "hello228: PASS\n" : "hello228: FAIL\n");
    return failures;
}
