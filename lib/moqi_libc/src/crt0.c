/* crt0.c — C runtime entry for MoQiOS user programs (freestanding only).
 *
 * The kernel jumps to _start with no CRT call frame; rsp points at the
 * System V style initial stack (argc, argv pointers, NULL, envp pointers,
 * NULL, auxv — see kernel/proc/user_stack.zig). A naked _start captures rsp
 * before any prologue can move it, realigns the stack, and hands the raw
 * pointer to _start_c, which parses argc/argv/envp (include/crt0.h), sets
 * the global environ, and calls main(argc, argv, envp).
 */
#include "../include/crt0.h"
#include "../include/unistd.h"

extern int main(int argc, char **argv, char **envp);
extern void __pthread_init_main(void);
extern void __moqi_tls_setup(unsigned long *sp);

/* Process environment, set by _start_c from the initial stack. */
char **environ;

__attribute__((used)) void _start_c(unsigned long *sp) {
    long argc;
    char **argv;
    char **envp;
    /* 先发现 PT_TLS 模板（auxv），再装主线程 FS/TCB（TLS 块布局依赖模板）。 */
    __moqi_tls_setup(sp);
    __pthread_init_main();
    moqi_parse_initial_stack(sp, &argc, &argv, &envp);
    environ = envp;
    int code = main((int)argc, argv, envp);
    _exit(code);
}

__attribute__((used, naked, noreturn)) void _start(void) {
    __asm__ volatile (
        /* Pass the entry rsp to _start_c, then align for the ABI-aligned
         * call (all user programs are built with -mstackrealign as well). */
        "movq %%rsp, %%rdi\n\t"
        "andq $-16, %%rsp\n\t"
        "call _start_c\n\t"
        "hlt\n\t" /* unreachable: _start_c never returns */
        ::: "memory");
}
