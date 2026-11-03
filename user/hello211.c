/* hello211: signal dispositions belong to the process, not to a thread (Linux CLONE_SIGHAND, which every pthread has). A
 * handler installed by one thread must be the handler every other thread sees, and a signal sent to the process must run
 * the handler that was installed last, whichever thread installed it. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/pthread.h"

#define SIGUSR1 10
#define SIGUSR2 12

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello211:   ok   " : "hello211:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static volatile int hits_main_handler, hits_thread_handler;
static void main_handler(int sig) { (void)sig; hits_main_handler++; }
static void thread_handler(int sig) { (void)sig; hits_thread_handler++; }

static void (*volatile seen_handler)(int);
static volatile long seen_ret;

static void *query_thread(void *arg) {
    int sig = (int)(long)arg;
    struct ksigaction old;
    memset(&old, 0, sizeof old);
    seen_ret = sigaction(sig, (const struct ksigaction *)0, &old);
    seen_handler = old.handler;
    return (void *)0;
}

static void *install_thread(void *arg) {
    int sig = (int)(long)arg;
    struct ksigaction act;
    memset(&act, 0, sizeof act);
    act.handler = thread_handler;
    seen_ret = sigaction(sig, &act, (struct ksigaction *)0);
    return (void *)0;
}

static void run(void *(*fn)(void *), long sig) {
    pthread_t t;
    for (int tries = 0; tries < 100000; tries++) {
        if (pthread_create(&t, (void *)0, fn, (void *)sig) == 0) {
            pthread_join(t, (void **)0);
            return;
        }
        yield();
    }
    failures++;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello211: signal dispositions shared by threads\n");

    struct ksigaction act;
    memset(&act, 0, sizeof act);
    act.handler = main_handler;
    check(sigaction(SIGUSR1, &act, (struct ksigaction *)0) == 0, "A: the main thread installs a handler for SIGUSR1");

    run(query_thread, SIGUSR1);
    check(seen_ret == 0 && seen_handler == main_handler, "A: a thread created afterwards sees that handler");

    run(install_thread, SIGUSR1);
    check(seen_ret == 0, "B: a thread installs its own handler for SIGUSR1");
    struct ksigaction cur;
    memset(&cur, 0, sizeof cur);
    sigaction(SIGUSR1, (const struct ksigaction *)0, &cur);
    check(cur.handler == thread_handler, "B: and the main thread now sees the thread's handler");

    hits_main_handler = hits_thread_handler = 0;
    kill(getpid(), SIGUSR1);
    for (int i = 0; i < 1000 && hits_main_handler + hits_thread_handler == 0; i++) yield();
    check(hits_thread_handler == 1 && hits_main_handler == 0, "C: a signal to the process runs the handler installed last (the thread's)");

    struct ksigaction ign;
    memset(&ign, 0, sizeof ign);
    ign.handler = SIG_IGN;
    sigaction(SIGUSR2, &ign, (struct ksigaction *)0);
    run(query_thread, SIGUSR2);
    check(seen_ret == 0 && seen_handler == SIG_IGN, "D: SIG_IGN set by the main thread is what a thread sees");
    kill(getpid(), SIGUSR2);
    for (int i = 0; i < 50; i++) yield();
    check(1, "D: and SIGUSR2 to the process is ignored (we are still here)");

    print(failures == 0 ? "hello211: PASS\n" : "hello211: FAIL\n");
    return failures;
}
