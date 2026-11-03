/* hello213: resource limits belong to the process, not to a thread. setrlimit from one thread is seen by every other
 * thread, including threads that already existed, and is what limits their allocations. */
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
    print(ok ? "hello213:   ok   " : "hello213:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

#define MIB (1024UL * 1024UL)

enum { OP_NONE, OP_MAP, OP_GET, OP_SET, OP_QUIT };
static volatile int op, done_flag;
static volatile long arg_res;
static volatile unsigned long arg_cur, arg_max;
static volatile long ret_value, ret_errno;
static void *volatile ret_ptr;

/* A worker created before any limit is touched; it does one job per request. */
static void *worker(void *arg) {
    (void)arg;
    for (;;) {
        while (op == OP_NONE) yield();
        int what = op;
        op = OP_NONE;
        if (what == OP_QUIT) return (void *)0;
        errno = 0;
        if (what == OP_MAP) {
            ret_ptr = mmap(0, arg_cur, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        } else if (what == OP_GET) {
            struct rlimit l = {0, 0};
            ret_value = getrlimit(arg_res, &l);
            arg_cur = l.rlim_cur;
            arg_max = l.rlim_max;
        } else if (what == OP_SET) {
            struct rlimit l = { arg_cur, arg_max };
            ret_value = setrlimit(arg_res, &l);
        }
        ret_errno = errno;
        done_flag = 1;
    }
}

static void ask(int what) {
    done_flag = 0;
    op = what;
    while (!done_flag) yield();
}

static unsigned long worker_get_cur(long res) { arg_res = res; ask(OP_GET); return arg_cur; }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello213: resource limits shared by threads\n");

    pthread_t t;
    check(pthread_create(&t, (void *)0, worker, (void *)0) == 0, "A: a worker thread starts before any limit is changed");

    struct rlimit lim = { 16 * MIB, RLIM_INFINITY };
    check(setrlimit(RLIMIT_AS, &lim) == 0, "A: the main thread sets RLIMIT_AS to 16 MiB");
    check(worker_get_cur(RLIMIT_AS) == 16 * MIB, "A: and the already-running worker reads 16 MiB back");

    arg_cur = 32 * MIB;
    ask(OP_MAP);
    check(ret_ptr == MAP_FAILED && ret_errno == ENOMEM, "B: so the worker cannot map 32 MiB: the main thread's limit applies to it");
    if (ret_ptr != MAP_FAILED) munmap(ret_ptr, 32 * MIB);

    struct rlimit none = { RLIM_INFINITY, RLIM_INFINITY };
    setrlimit(RLIMIT_AS, &none);

    arg_res = RLIMIT_NOFILE;
    arg_cur = 20;
    arg_max = 20;
    ask(OP_SET);
    check(ret_value == 0, "C: the worker sets RLIMIT_NOFILE to 20");
    struct rlimit seen = {0, 0};
    check(getrlimit(RLIMIT_NOFILE, &seen) == 0 && seen.rlim_cur == 20 && seen.rlim_max == 20, "C: and the main thread reads 20 back");
    int opened = 0;
    long firstfail = 0;
    int keep[64];
    for (int i = 0; i < 30; i++) {
        int p2[2];
        long r = pipe(p2);
        if (r < 0) { firstfail = -r; break; }
        keep[opened++] = p2[0];
        keep[opened++] = p2[1];
    }
    check(opened > 0 && opened <= 20 && firstfail == EMFILE, "C: the main thread's descriptor allocations stop at 20 (EMFILE)");
    for (int i = 0; i < opened; i++) close(keep[i]);

    arg_res = RLIMIT_NOFILE;
    arg_cur = 64;
    arg_max = 64;
    ask(OP_SET);

    arg_res = RLIMIT_CORE;
    arg_cur = 12345;
    arg_max = 54321;
    ask(OP_SET);
    memset(&seen, 0, sizeof seen);
    check(getrlimit(RLIMIT_CORE, &seen) == 0 && seen.rlim_cur == 12345 && seen.rlim_max == 54321, "D: a limit with no enforcement point (RLIMIT_CORE) set by the worker is read by the main thread");

    struct rlimit st = { 4 * MIB, 4 * MIB };
    check(setrlimit(RLIMIT_STACK, &st) == 0, "E: the main thread lowers RLIMIT_STACK");
    check(worker_get_cur(RLIMIT_STACK) == 4 * MIB, "E: and the worker reads it");

    struct rlimit pl = {0, 0};
    check(prlimit64(0, RLIMIT_CORE, (const struct rlimit *)0, &pl) == 0 && pl.rlim_cur == 12345, "F: prlimit64(0, ...) from the main thread reads the shared value");

    op = OP_QUIT;
    pthread_join(t, (void **)0);
    print(failures == 0 ? "hello213: PASS\n" : "hello213: FAIL\n");
    return failures;
}
