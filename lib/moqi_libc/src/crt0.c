/* crt0.c — C runtime entry for MoQiOS user programs (freestanding only).
 *
 * The kernel jumps to _start with no CRT call frame. All user programs are
 * compiled with -mstackrealign, so the prologue realigns rsp for SSE
 * locals; the explicit and$ here additionally guarantees the ABI-aligned
 * call into main on entry paths where the compiler assumes alignment.
 */
#include "../include/unistd.h"

extern int main(void);

__attribute__((used, noreturn)) void _start(void) {
    __asm__ volatile ("andq $-16, %%rsp" ::: "memory");
    int code = main();
    _exit(code);
}
