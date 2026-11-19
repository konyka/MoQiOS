/* hello436: an SA_SIGINFO handler's ucontext points uc_mcontext.fpregs at the interrupted x87/SSE state (Linux
 * __unsafe_setup_sigcontext: sc->fpstate is the user copy of the FPU image that copy_fpstate_to_sigframe wrote on the signal
 * stack). Before, fpregs was always 0, so a handler could not read the interrupted MXCSR or xmm registers.
 * Measured on the host (build with -DHOST):
 *   A. with MXCSR set to 0x7f80 | round-toward-zero (0x6000) = 0x7f80 and xmm0 = 0x1122334455667788 before raise(SIGUSR1): the
 *      handler sees fpregs != 0, inside the region just above its stack pointer, its mxcsr field (offset 24) has the rounding bits
 *      0x6000 and its xmm0 (offset 160) holds 0x1122334455667788;
 *   B. after the handler returns, MXCSR still has 0x6000 (restored by sigreturn). */
#ifdef HOST
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <string.h>
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
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello436:   ok   " : "hello436:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static volatile unsigned long seen_fp, seen_sp, seen_xmm0;
static volatile unsigned seen_mxcsr;
/* mcontext gregs[23] start at offset 40 of ucontext_t; fpregs follows them at 40 + 23 * 8 = 224. */
static void handler(int sig, void *info, void *ucv) {
    (void)sig;
    (void)info;
    unsigned char *uc = ucv;
    unsigned long fp = 0;
    memcpy(&fp, uc + 224, 8);
    seen_fp = fp;
    unsigned long sp;
    __asm__ volatile("mov %%rsp, %0" : "=r"(sp));
    seen_sp = sp;
    if (fp) {
        unsigned m = 0;
        unsigned long x = 0;
        memcpy(&m, (unsigned char *)fp + 24, 4);
        memcpy(&x, (unsigned char *)fp + 160, 8);
        seen_mxcsr = m;
        seen_xmm0 = x;
    }
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
#else
__attribute__((naked)) static void restorer(void) { __asm__ volatile("movq $15, %rax\n syscall"); }
static void install(void) {
    unsigned long a[4] = { (unsigned long)handler, 0x4 | 0x04000000, (unsigned long)restorer, 0 };
    syscall4(13, 10, (long)a, 0, 8);
}
static void raise_(void) { syscall2(62, syscall1(39, 0), 10); }
#endif
int main(void) {
    print("hello436: ucontext fpregs points at the interrupted FPU state\n");
    install();
    unsigned orig = 0, want = 0x1f80 | 0x6000;
    __asm__ volatile("stmxcsr %0" : "=m"(orig));
    __asm__ volatile("ldmxcsr %0" : : "m"(want));
    unsigned long v = 0x1122334455667788UL;
    __asm__ volatile("movq %0, %%xmm0" : : "r"(v) : "xmm0");
    raise_();
    unsigned after = 0;
    __asm__ volatile("stmxcsr %0" : "=m"(after));
    __asm__ volatile("ldmxcsr %0" : : "m"(orig));
    int near = seen_fp > seen_sp && seen_fp - seen_sp < 65536;
    snprintf(msg, sizeof msg, "A: fpregs %s, above the handler stack %d; mxcsr 0x%x (rounding 0x6000: %d); xmm0 0x%lx (nonzero 1; 1; 1; 0x1122334455667788)",
             seen_fp ? "nonzero" : "zero", near, seen_mxcsr, (seen_mxcsr & 0x6000) == 0x6000, seen_xmm0);
    check(seen_fp != 0 && near && (seen_mxcsr & 0x6000) == 0x6000 && seen_xmm0 == 0x1122334455667788UL, msg);
    snprintf(msg, sizeof msg, "B: MXCSR after the handler 0x%x (rounding 0x6000 kept)", after);
    check((after & 0x6000) == 0x6000, msg);
    print(failures == 0 ? "hello436: PASS\n" : "hello436: FAIL\n");
    return failures == 0 ? 0 : 1;
}
