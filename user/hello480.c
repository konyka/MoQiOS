/* hello480: sigreturn takes the FPU image from wherever uc_mcontext.fpregs points when the handler returns (Linux
 * restore_sigcontext → fpu__restore_sig reads sc->fpstate): a handler may redirect it to its own copy, a null pointer resets the
 * FPU (fpu__clear_user_states), a misaligned one is a bad frame and the task gets SIGSEGV. Measured on the host (build with
 * -DHOST):
 *   A. the handler copies the 512-byte image, writes 0x11223344 into its xmm0 and points fpregs at the copy: after the return
 *      xmm0 holds 0x11223344;
 *   B. the handler sets fpregs to 0: after the return xmm0 is 0 and MXCSR is the initial 0x1f80 (the rounding bits set before
 *      are gone);
 *   C. in a child, the handler points fpregs 8 bytes into an aligned buffer: the child dies of SIGSEGV. */
#ifdef HOST
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <ucontext.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello480:   ok   " : "hello480:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int mode;
static unsigned char mine[512 + 64] __attribute__((aligned(64)));
/* mcontext gregs[23] start at offset 40 of ucontext_t; fpregs follows them at 40 + 23 * 8 = 224. */
static void handler(int sig, void *info, void *ucv) {
    (void)sig;
    (void)info;
    unsigned char *uc = ucv;
    unsigned long fp = 0;
    memcpy(&fp, uc + 224, 8);
    unsigned long nfp = 0;
    if (mode == 1) {
        memcpy(mine, (void *)fp, 512);
        unsigned v = 0x11223344;
        memcpy(mine + 160, &v, 4);
        nfp = (unsigned long)mine;
    } else if (mode == 3) {
        nfp = (unsigned long)mine + 8;
    }
    memcpy(uc + 224, &nfp, 8);
}
#ifdef HOST
static void install(void) {
    struct sigaction a;
    memset(&a, 0, sizeof a);
    a.sa_sigaction = (void (*)(int, siginfo_t *, void *))handler;
    a.sa_flags = SA_SIGINFO;
    sigaction(SIGUSR1, &a, 0);
}
static void raise_(void) { raise(SIGUSR1); }
static long fork_(void) { return fork(); }
static long wait_(long p, int *st) { return waitpid((int)p, st, 0); }
static void exit_(int c) { _exit(c); }
#else
__attribute__((naked)) static void restorer(void) { __asm__ volatile("movq $15, %rax\n syscall"); }
static void install(void) {
    unsigned long a[4] = { (unsigned long)handler, 0x4 | 0x04000000, (unsigned long)restorer, 0 };
    syscall4(13, 10, (long)a, 0, 8);
}
static void raise_(void) { syscall2(62, syscall1(39, 0), 10); }
static long fork_(void) { return syscall0(SYS_fork); }
static long wait_(long p, int *st) { return syscall3(SYS_waitpid, p, (long)st, 0); }
static void exit_(int c) { syscall1(2, c); }
#endif
static unsigned xmm0(void) {
    unsigned out;
    __asm__ volatile("movd %%xmm0, %0" : "=r"(out));
    return out;
}
static void set_xmm0(unsigned v) { __asm__ volatile("movd %0, %%xmm0" : : "r"(v) : "xmm0"); }
int main(void) {
    print("hello480: sigreturn takes the FPU image fpregs points at\n");
    install();
    mode = 1;
    set_xmm0(0xaaaa);
    raise_();
    unsigned a1 = xmm0();
    snprintf(msg, sizeof msg, "A: redirected fpregs: xmm0 after the return 0x%x (0x11223344)", a1);
    check(a1 == 0x11223344, msg);

    mode = 2;
    unsigned want = 0x1f80 | 0x6000;
    __asm__ volatile("ldmxcsr %0" : : "m"(want));
    set_xmm0(0xbbbb);
    raise_();
    unsigned b1 = xmm0(), mx = 0;
    __asm__ volatile("stmxcsr %0" : "=m"(mx));
    snprintf(msg, sizeof msg, "B: null fpregs: xmm0 0x%x, MXCSR 0x%x (0 0x1f80)", b1, mx);
    check(b1 == 0 && mx == 0x1f80, msg);

    long c = fork_();
    if (c == 0) {
        mode = 3;
        raise_();
        exit_(0);
    }
    int st = -1;
    long w = wait_(c, &st);
    snprintf(msg, sizeof msg, "C: misaligned fpregs: child %ld, status 0x%x (signal 11)", w, st);
    check(w == c && (st & 0x7f) == 11, msg);

    print(failures == 0 ? "hello480: PASS\n" : "hello480: FAIL\n");
    return failures == 0 ? 0 : 1;
}
