/* hello215: thread create + join, many times in a row, from the same thread. pthread_join frees the exited thread's block
 * (TCB and stack) as soon as it sees the thread's state flip, while the exiting thread is still running pthread_exit on
 * that block; the next pthread_create can be handed the same memory. The exit path must not read or write the block
 * after announcing its exit. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello215:   ok   " : "hello215:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile long counter;
static void *bump(void *arg) { counter += (long)arg; return arg; }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello215: thread create/join storm\n");
    long expect = 0;
    int bad = 0, retries = 0;
    for (long i = 1; i <= 3000; i++) {
        pthread_t t;
        int rc;
        int tries = 0;
        while ((rc = pthread_create(&t, (void *)0, bump, (void *)i)) != 0 && tries < 100000) { tries++; retries++; yield(); }
        if (rc != 0) { bad = 1; break; }
        void *rv = (void *)0;
        if (pthread_join(t, &rv) != 0 || rv != (void *)i) { bad = 2; break; }
        expect += i;
    }
    check(!bad, "A: 3000 threads created and joined, each returning its argument");
    check(counter == expect, "A: every thread ran exactly once");
    { char m[64]; snprintf(m, sizeof m, "hello215: create retries=%d\n", retries); print(m); }
    print(failures == 0 ? "hello215: PASS\n" : "hello215: FAIL\n");
    return failures;
}
