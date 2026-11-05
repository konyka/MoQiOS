/* hello228: a joined thread must be finished with its memory when pthread_join returns. join frees the thread's block (TCB and
 * stack) and the next allocation of that size gets the same memory. This storm creates a thread, joins it, and at once
 * allocates a block of the same size and zeroes its start (where the TCB was), a thousand times over. If an exiting thread
 * still reads its TCB after join has returned (it re-reads %fs:0 and its detached flag after announcing its exit), it now
 * reads zeros and faults or takes a wrong branch; the kernel logs such a fault. */
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

static volatile long ran;
static void *worker(void *arg) {
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
    print(failures == 0 ? "hello228: PASS\n" : "hello228: FAIL\n");
    return failures;
}
