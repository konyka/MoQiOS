/* hello212: RLIMIT_AS accounting belongs to the address space, not to a thread. The pages one thread maps count against
 * the limit for every thread of the process, and pages another thread unmaps stop counting. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/mman.h"
#include "../lib/moqi_libc/include/resource.h"
#include "../lib/moqi_libc/include/pthread.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello212:   ok   " : "hello212:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

#define MIB (1024UL * 1024UL)

static void *volatile worker_ptr;
static volatile int worker_errno;
static volatile int go, done_flag, quit;
static volatile unsigned long worker_len;

/* A worker thread created up front: it waits for a request, maps worker_len bytes, reports, and waits again. */
static void *worker(void *arg) {
    (void)arg;
    for (;;) {
        while (!go && !quit) yield();
        if (quit) return (void *)0;
        go = 0;
        errno = 0;
        void *p = mmap(0, worker_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        worker_ptr = p;
        worker_errno = errno;
        done_flag = 1;
    }
}

static void ask(unsigned long len) {
    worker_len = len;
    done_flag = 0;
    go = 1;
    while (!done_flag) yield();
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello212: RLIMIT_AS accounting shared by threads\n");

    struct rlimit lim = { 16 * MIB, RLIM_INFINITY };
    check(setrlimit(RLIMIT_AS, &lim) == 0, "A: RLIMIT_AS is set to 16 MiB");

    pthread_t t;
    check(pthread_create(&t, (void *)0, worker, (void *)0) == 0, "A: a worker thread starts");

    void *mine = mmap(0, 10 * MIB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(mine != MAP_FAILED, "B: the main thread maps 10 MiB (within the limit)");

    ask(10 * MIB);
    check(worker_ptr == MAP_FAILED && worker_errno == ENOMEM, "B: the worker then cannot map another 10 MiB: together they would exceed 16 MiB");
    if (worker_ptr != MAP_FAILED) munmap(worker_ptr, 10 * MIB);

    check(munmap(mine, 10 * MIB) == 0, "C: the main thread unmaps its 10 MiB");
    ask(10 * MIB);
    check(worker_ptr != MAP_FAILED, "C: and now the worker can map 10 MiB (the charge went away with the unmap)");
    void *theirs = worker_ptr;

    errno = 0;
    void *again = mmap(0, 10 * MIB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(again == MAP_FAILED && errno == ENOMEM, "D: the main thread cannot map 10 MiB on top of what the worker holds");
    if (again != MAP_FAILED) munmap(again, 10 * MIB);

    if (theirs != MAP_FAILED) check(munmap(theirs, 10 * MIB) == 0, "E: the main thread can unmap what the worker mapped");
    again = mmap(0, 10 * MIB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    check(again != MAP_FAILED, "E: and then 10 MiB is available to it again");
    if (again != MAP_FAILED) munmap(again, 10 * MIB);

    quit = 1;
    pthread_join(t, (void **)0);
    struct rlimit back = { RLIM_INFINITY, RLIM_INFINITY };
    setrlimit(RLIMIT_AS, &back);

    print(failures == 0 ? "hello212: PASS\n" : "hello212: FAIL\n");
    return failures;
}
