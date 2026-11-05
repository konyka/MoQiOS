/* hello221: setjmp / longjmp / sigsetjmp / siglongjmp on the real kernel. The register-level behavior is checked on the host
 * against a stub; here the interesting part is the interplay with the kernel: leaving a signal handler by siglongjmp (the
 * kernel never sees a sigreturn), what happens to the signal mask, recovering from a real page fault again and again, and
 * four threads jumping at the same time, each with its own buffer and stack. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/setjmp.h"
#include "../lib/moqi_libc/include/pthread.h"

#define SYS_tkill 223
#define SIG_BLOCK_ 0
#define SIG_SETMASK_ 2

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello221:   ok   " : "hello221:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static unsigned long get_mask(void) {
    unsigned long m = 0;
    syscall4(SYS_sigprocmask, SIG_BLOCK_, 0, (long)&m, 8);
    return m;
}
static void set_mask(unsigned long m) { syscall4(SYS_sigprocmask, SIG_SETMASK_, (long)&m, 0, 8); }
static unsigned long bit(int sig) { return 1UL << (sig - 1); }
static long install(int sig, void (*h)(int), unsigned long flags) {
    struct ksigaction a = { h, flags, 0, 0 };
    return sigaction(sig, &a, (struct ksigaction *)0);
}
static void raise_self(int sig) { syscall2(SYS_tkill, getpid(), sig); }

static sigjmp_buf sj;
static jmp_buf plain;
static volatile int handler_hits;
static volatile unsigned long mask_in_handler;

static void on_usr1(int s) {
    handler_hits++;
    mask_in_handler = get_mask();
    siglongjmp(sj, 100 + s);
}

static void on_segv(int s) {
    handler_hits++;
    siglongjmp(sj, 200 + s);
}

static volatile int worker_bad;
static void *worker(void *arg) {
    long id = (long)arg;
    jmp_buf env;
    volatile long sum = 0;
    for (int round = 0; round < 3000; round++) {
        volatile int local = round * 3 + (int)id;
        int r = setjmp(env);
        if (r == 0) {
            sum += local;
            longjmp(env, local % 50 + 1);
        }
        if (r != local % 50 + 1 || local != round * 3 + (int)id) {
            worker_bad++;
            break;
        }
        if ((round & 63) == 0) yield();
    }
    return (void *)(long)(sum != 0);
}

static volatile int probe_ok;
static void deep(int n) {
    volatile char pad[512];
    pad[0] = (char)n;
    if (n == 0) longjmp(plain, 7);
    deep(n - 1);
    probe_ok = 0;
    (void)pad;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello221: setjmp family\n");

    /* A: plain setjmp / longjmp */
    {
        jmp_buf env;
        volatile int hops = 0;
        int r = setjmp(env);
        if (r == 0) {
            hops = 1;
            longjmp(env, 0);
        }
        check(r == 1 && hops == 1, "A: longjmp(env, 0) makes setjmp return 1");
        r = setjmp(env);
        if (r == 0) longjmp(env, -5);
        check(r == -5, "A: a negative value comes back unchanged");
        volatile int count = 0;
        r = setjmp(env);
        if (r < 50000) {
            count = count + 1;
            longjmp(env, r + 1);
        }
        check(r == 50000 && count == 50000, "A: 50000 jumps to the same setjmp");
        probe_ok = 1;
        r = setjmp(plain);
        if (r == 0) deep(3000);
        check(r == 7 && probe_ok == 1, "A: out of a 3000-frame recursion (1.5 MB of stack)");
    }

    /* B: the signal mask */
    {
        sigjmp_buf env;
        set_mask(0);
        int r = setjmp(plain);
        if (r == 0) {
            set_mask(bit(SIGUSR2));
            longjmp(plain, 1);
        }
        check((get_mask() & bit(SIGUSR2)) != 0, "B: setjmp/longjmp leave the signal mask as it was at the jump");
        set_mask(0);
        r = sigsetjmp(env, 1);
        if (r == 0) {
            set_mask(bit(SIGUSR2));
            siglongjmp(env, 1);
        }
        check(get_mask() == 0, "B: sigsetjmp(env, 1) + siglongjmp puts the mask back");
        r = sigsetjmp(env, 0);
        if (r == 0) {
            set_mask(bit(SIGUSR2));
            siglongjmp(env, 1);
        }
        check((get_mask() & bit(SIGUSR2)) != 0, "B: sigsetjmp(env, 0) does not");
        set_mask(0);
    }

    /* C: leaving a signal handler by siglongjmp */
    {
        set_mask(0);
        check(install(SIGUSR1, on_usr1, 0) == 0, "C: handler installed");
        handler_hits = 0;
        int r = sigsetjmp(sj, 1);
        if (r == 0) {
            raise_self(SIGUSR1);
            r = -1;
        }
        check(r == 100 + SIGUSR1 && handler_hits == 1, "C: siglongjmp from the handler lands in sigsetjmp with the value given");
        check((mask_in_handler & bit(SIGUSR1)) != 0, "C: SIGUSR1 was blocked while the handler ran");
        check((get_mask() & bit(SIGUSR1)) == 0, "C: and sigsetjmp(env, 1) unblocked it again");
        r = sigsetjmp(sj, 0);
        if (r == 0) {
            raise_self(SIGUSR1);
            r = -1;
        }
        check(r == 100 + SIGUSR1 && handler_hits == 2, "C: a second time");
        check((get_mask() & bit(SIGUSR1)) != 0, "C: with savemask 0 the signal stays blocked, as POSIX says (the handler never returned)");
        set_mask(0);
        int again = 0;
        for (int i = 0; i < 200; i++) {
            r = sigsetjmp(sj, 1);
            if (r == 0) {
                raise_self(SIGUSR1);
                r = -1;
            }
            again += r == 100 + SIGUSR1;
        }
        check(again == 200 && handler_hits == 202 && get_mask() == 0, "C: 200 more rounds, the mask is clean at the end");
    }

    /* D: recovering from a real page fault, repeatedly */
    {
        set_mask(0);
        check(install(SIGSEGV, on_segv, 0) == 0, "D: SIGSEGV handler installed");
        handler_hits = 0;
        int recovered = 0;
        for (int i = 0; i < 100; i++) {
            int r = sigsetjmp(sj, 1);
            if (r == 0) {
                volatile int *p = (volatile int *)0;
                *p = 1;
                r = -1;
            }
            recovered += r == 200 + SIGSEGV;
        }
        check(recovered == 100 && handler_hits == 100, "D: 100 faults on address 0, each recovered by siglongjmp out of the handler");
        check((get_mask() & bit(SIGSEGV)) == 0, "D: and SIGSEGV is not left blocked");
        /* a store to a read-only page (the program's own text) */
        int r = sigsetjmp(sj, 1);
        if (r == 0) {
            volatile unsigned char *code = (volatile unsigned char *)&main;
            *code = 0;
            r = -1;
        }
        check(r == 200 + SIGSEGV, "D: a write to the program's code is recovered too");
    }

    /* E: threads */
    {
        pthread_t t[4];
        int created = 0;
        for (long i = 0; i < 4; i++) {
            int tries = 0;
            while (pthread_create(&t[i], (void *)0, worker, (void *)i) != 0 && tries++ < 1000) yield();
            if (tries < 1000) created++;
        }
        long ok = 0;
        for (int i = 0; i < created; i++) {
            void *rv = (void *)0;
            pthread_join(t[i], &rv);
            ok += (long)rv;
        }
        check(created == 4 && ok == 4 && worker_bad == 0, "E: four threads making 3000 jumps each, every one landing with its own value");
    }

    print(failures == 0 ? "hello221: PASS\n" : "hello221: FAIL\n");
    return failures;
}
