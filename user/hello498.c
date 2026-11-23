/* hello498: clone CLONE_SIGHAND / CLONE_FS validation and sharing (Linux copy_process).
 * A: CLONE_SIGHAND without CLONE_VM and CLONE_THREAD without CLONE_SIGHAND are EINVAL;
 * B: a CLONE_VM | CLONE_FS | CLONE_SIGHAND | CLONE_THREAD thread sees the creator's later chdir and sigaction;
 * C: changes the thread makes are seen by the creator. Measured with -DHOST. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long mmap_(long n) { void *p = mmap(0, (size_t)n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); return p == MAP_FAILED ? -errno : (long)p; }
static long raw(long n, long a, long b, long c, long d) {
    long r;
    register long r10 __asm__("r10") = d;
    __asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10) : "rcx", "r11", "memory");
    return r;
}
static long clone_(long fl, void *stack) { (void)rc; return raw(SYS_clone, fl, (long)stack, 0, 0); }
#define CLONE_NR 56
#define EXIT_NR 60
struct ksa { void *handler; unsigned long flags; void *restorer; unsigned long mask; };
static long chdir_(const char *p) { return raw(SYS_chdir, (long)p, 0, 0, 0); }
static long getcwd_(char *b, long n) { long r = raw(SYS_getcwd, (long)b, n, 0, 0); return r < 0 ? r : (long)strlen(b); }
static long sigaction_(int sig, void *handler, void *old) {
    struct ksa sa, os;
    memset(&sa, 0, sizeof sa);
    memset(&os, 0, sizeof os);
    sa.handler = handler;
    long r = raw(SYS_rt_sigaction, sig, (long)&sa, (long)&os, 8);
    if (old) *(void **)old = os.handler;
    return r;
}
static void nap(void) { struct timespec t = { 0, 1000000 }; raw(SYS_nanosleep, (long)&t, 0, 0, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
static long clone_(long fl, void *stack) { return syscall5(243, fl, (long)stack, 0, 0, 0); }
static long mmap_(long n) { return syscall6(8, 0, n, 3, 0x22, -1, 0); }
static long chdir_(const char *p) { return syscall1(SYS_chdir, (long)p); }
static long getcwd_(char *b, long n) { long r = syscall2(SYS_getcwd, (long)b, n); return r < 0 ? r : (long)strlen(b); }
static long sigaction_(int sig, void *handler, void *old) {
    struct ksigaction sa, os;
    memset(&sa, 0, sizeof sa);
    memset(&os, 0, sizeof os);
    sa.handler = (void (*)(int))handler;
    long r = sigaction(sig, &sa, &os);
    if (old) *(void **)old = (void *)os.handler;
    return r;
}
static void nap(void) { long t[2] = { 0, 1000000 }; syscall2(35, (long)t, 0); }
#define CLONE_NR 243
#define EXIT_NR 2
#endif
/* clone whose child calls fn() on the new stack and exits there: a child returning through a C frame would use the parent's stack. */
static long clone_fn(long fl, void *stack, void (*fn)(void)) {
    long r;
    register long r10 __asm__("r10") = 0;
    register long r8 __asm__("r8") = 0;
    register long r12 __asm__("r12") = (long)fn;
    __asm__ volatile(
        "syscall\n\t"
        "test %%rax, %%rax\n\t"
        "jnz 1f\n\t"
        "xor %%ebp, %%ebp\n\t"
        "call *%%r12\n\t"
        "mov %[ex], %%eax\n\t"
        "xor %%edi, %%edi\n\t"
        "syscall\n\t"
        "2: jmp 2b\n\t"
        "1:\n\t"
        : "=a"(r)
        : "a"((long)CLONE_NR), "D"(fl), "S"(stack), "d"(0L), "r"(r10), "r"(r8), "r"(r12), [ex] "i"(EXIT_NR)
        : "rcx", "r11", "memory");
    return r;
}
#define CLONE_VM 0x100
#define CLONE_FS 0x200
#define CLONE_FILES 0x400
#define CLONE_SIGHAND 0x800
#define CLONE_THREAD 0x10000
#define SIGUSR1_ 10
static int failures;
static char msg[500];
static volatile int stage;
static volatile long t_cwd, t_old, t_set, t_chdir;
static char t_buf[256];
static void check(int ok, const char *w) {
    print(ok ? "hello498:   ok   " : "hello498:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void handler_a(int s) { (void)s; }
static void handler_b(int s) { (void)s; }
static void wait_stage(int want) { for (int i = 0; i < 5000 && stage < want; i++) nap(); }
static void thread_body(void) {
    wait_stage(1);
    t_cwd = getcwd_(t_buf, sizeof t_buf);
    void *seen = 0;
    t_old = sigaction_(SIGUSR1_, (void *)handler_b, &seen);
    t_set = (long)seen;
    t_chdir = chdir_("/");
    stage = 2;
}
int main(void) {
    print("hello498: CLONE_SIGHAND / CLONE_FS share thread-group state\n");
    long ev = clone_(CLONE_SIGHAND, 0), et = clone_(CLONE_VM | CLONE_THREAD, 0);
    snprintf(msg, sizeof msg, "A: SIGHAND without VM %ld, THREAD without SIGHAND %ld (-22 -22)", ev, et);
    check(ev == -22 && et == -22, msg);
    char saved[256];
    long sl = getcwd_(saved, sizeof saved);
    void *old_handler = 0;
    long sa0 = sigaction_(SIGUSR1_, (void *)1, &old_handler);
    long cd0 = chdir_("/");
    long stack = mmap_(65536);
    long tid = stack > 0 ? clone_fn(CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD, (void *)(stack + 65536 - 64), thread_body) : stack;
    long cd1 = chdir_("/tmp");
    long sa1 = sigaction_(SIGUSR1_, (void *)handler_a, 0);
    stage = 1;
    wait_stage(2);
    snprintf(msg, sizeof msg, "B: setup %ld/%ld/%ld stack %ld tid %ld; creator chdir/sigaction %ld/%ld; thread cwd %ld '%s', old handler %d (>=0 0 0 >0 >0 0 0; 4 /tmp 1)",
             sl, sa0, cd0, stack > 0 ? 1L : stack, tid, cd1, sa1, t_cwd, t_buf, t_set == (long)handler_a);
    check(sl > 0 && sa0 == 0 && cd0 == 0 && stack > 0 && tid > 0 && cd1 == 0 && sa1 == 0 && stage == 2 && t_cwd == 4 && strcmp(t_buf, "/tmp") == 0 && t_old == 0 && t_set == (long)handler_a, msg);
    char now[256];
    long nl = getcwd_(now, sizeof now);
    void *seen = 0;
    long sr = sigaction_(SIGUSR1_, old_handler, &seen);
    long restore = chdir_(saved);
    snprintf(msg, sizeof msg, "C: thread chdir %ld, creator cwd %ld '%s', creator sees thread handler %d; restore %ld/%ld (0 1 / 1; 0 0)",
             t_chdir, nl, now, seen == (void *)handler_b, sr, restore);
    check(t_chdir == 0 && nl == 1 && strcmp(now, "/") == 0 && seen == (void *)handler_b && sr == 0 && restore == 0, msg);
    print(failures ? "hello498: FAIL\n" : "hello498: PASS\n");
    return failures ? 1 : 0;
}
