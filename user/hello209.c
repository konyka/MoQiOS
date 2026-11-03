/* hello209: the program break belongs to the address space, not to a thread. A CLONE_VM thread that grows the heap with
 * sbrk must move the break for every thread of the process, and a thread that grows it after another thread did must
 * start from the real break. Threads that each grow the malloc heap rely on this. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello209:   ok   " : "hello209:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static void *volatile thread_before;
static void *volatile thread_old;
static void *volatile thread_new;

static void *grow_thread(void *arg) {
    (void)arg;
    thread_before = sbrk(0);
    thread_old = sbrk(8192);
    if (thread_old != (void *)-1) memset(thread_old, 0x5A, 8192);
    thread_new = sbrk(0);
    return (void *)0;
}

static void *probe_thread(void *arg) {
    *(long *)arg = (long)sbrk(0);
    return (void *)0;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello209: program break shared by CLONE_VM threads\n");

    pthread_t t;
    check(pthread_create(&t, (void *)0, grow_thread, (void *)0) == 0, "A: a thread starts");
    pthread_join(t, (void **)0);
    check(thread_old != (void *)-1, "A: sbrk(8192) in a CLONE_VM thread succeeds");
    check(thread_old == thread_before, "A: it returns the break the thread saw");
    check(thread_new == (void *)((char *)thread_before + 8192), "A: and the break moved by exactly 8192");

    void *main_view = sbrk(0);
    check(main_view == thread_new, "B: the creating thread sees the break the other thread set");
    void *got = sbrk(4096);
    check(got == main_view, "B: and its own sbrk continues from there, not from a stale break");
    if (got != (void *)-1) memset(got, 0x6B, 4096);
    check(sbrk(0) == (void *)((char *)main_view + 4096), "B: the break moved by 4096");
    unsigned char *tp = (unsigned char *)thread_old;
    check(thread_old != (void *)-1 && tp[0] == 0x5A && tp[8191] == 0x5A, "B: the pages the thread mapped are intact");

    long seen = 0;
    pthread_t t2;
    pthread_create(&t2, (void *)0, probe_thread, &seen);
    pthread_join(t2, (void **)0);
    check(seen == (long)sbrk(0), "C: a thread started later sees the current break");

    long ok = 1;
    for (int i = 0; i < 6; i++) {
        pthread_t u;
        thread_old = (void *)0;
        pthread_create(&u, (void *)0, grow_thread, (void *)0);
        pthread_join(u, (void **)0);
        void *before = sbrk(0);
        void *m = sbrk(4096);
        if (thread_old == (void *)-1 || m == (void *)-1 || m != before) ok = 0;
    }
    check(ok, "D: threads and the main thread take turns growing the heap, six rounds, nobody fails");

    print(failures == 0 ? "hello209: PASS\n" : "hello209: FAIL\n");
    return failures;
}
