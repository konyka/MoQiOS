/* setjmp.c — setjmp, sigsetjmp, longjmp, siglongjmp (see include/setjmp.h). x86-64 only.
 *
 * The four functions are assembly: they must read the caller's stack pointer and return address exactly as they were at the
 * call. The only C is the pair of helpers that touch the signal mask; sigsetjmp calls its helper after the registers are
 * stored, siglongjmp before they are loaded, so neither disturbs what is saved or restored.
 */
#include <stddef.h>

#include "../include/moqi_syscalls.h"
#include "../include/setjmp.h"

/* The host unit test links this file against a recording stub instead of the real `syscall` instruction. */
#ifdef MOQI_HOST_TEST_SYSCALL
extern long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6);
#define SJ_SYSCALL4(nr, a1, a2, a3, a4) moqi_test_syscall6((nr), (a1), (a2), (a3), (a4), 0, 0)
#else
#define SJ_SYSCALL4(nr, a1, a2, a3, a4) syscall4((nr), (a1), (a2), (a3), (a4))
#endif

#define SJ_SIG_BLOCK  0
#define SJ_SIG_SETMASK 2

_Static_assert(offsetof(struct __moqi_jmp_buf, regs) == 0, "assembly offsets");
_Static_assert(offsetof(struct __moqi_jmp_buf, mask_saved) == 64, "assembly offsets");
_Static_assert(offsetof(struct __moqi_jmp_buf, mask) == 72, "assembly offsets");

/* Reads the current mask into the buffer; if the read fails the buffer is left saying "no mask saved". */
void __moqi_sj_save_mask(struct __moqi_jmp_buf *env) {
    unsigned long m = 0;
    if (SJ_SYSCALL4(SYS_sigprocmask, SJ_SIG_BLOCK, 0, (long)&m, 8) == 0) {
        env->mask = m;
        env->mask_saved = 1;
    }
}

void __moqi_sj_restore_mask(const struct __moqi_jmp_buf *env) {
    unsigned long m = env->mask;
    SJ_SYSCALL4(SYS_sigprocmask, SJ_SIG_SETMASK, (long)&m, 0, 8);
}

/* The host test builds this file with the four names changed (-Dsetjmp=moqi_setjmp ...) so they cannot collide with the host's
 * own; the assembly below spells them through these macros so the change reaches it too. */
#define SJ_STR_(x) #x
#define SJ_STR(x) SJ_STR_(x)

__asm__(
    ".pushsection .text\n"

    ".globl " SJ_STR(setjmp) "\n"
    ".type " SJ_STR(setjmp) ",@function\n"
    SJ_STR(setjmp) ":\n"
    "    xorl %esi, %esi\n"
    "    jmp " SJ_STR(sigsetjmp) "\n"
    ".size " SJ_STR(setjmp) ", .-" SJ_STR(setjmp) "\n"

    ".globl " SJ_STR(sigsetjmp) "\n"
    ".type " SJ_STR(sigsetjmp) ",@function\n"
    SJ_STR(sigsetjmp) ":\n"
    "    movq %rbx, 0(%rdi)\n"
    "    movq %rbp, 8(%rdi)\n"
    "    movq %r12, 16(%rdi)\n"
    "    movq %r13, 24(%rdi)\n"
    "    movq %r14, 32(%rdi)\n"
    "    movq %r15, 40(%rdi)\n"
    "    leaq 8(%rsp), %rax\n"       /* the stack pointer as it will be once this call has returned */
    "    movq %rax, 48(%rdi)\n"
    "    movq (%rsp), %rax\n"        /* the return address */
    "    movq %rax, 56(%rdi)\n"
    "    movl $0, 64(%rdi)\n"
    "    testl %esi, %esi\n"
    "    jz 1f\n"
    "    subq $8, %rsp\n"            /* keep the stack 16-byte aligned for the call */
    "    call __moqi_sj_save_mask\n"
    "    addq $8, %rsp\n"
    "1:  xorl %eax, %eax\n"
    "    ret\n"
    ".size " SJ_STR(sigsetjmp) ", .-" SJ_STR(sigsetjmp) "\n"

    ".globl " SJ_STR(longjmp) "\n"
    ".type " SJ_STR(longjmp) ",@function\n"
    ".globl " SJ_STR(siglongjmp) "\n"
    ".type " SJ_STR(siglongjmp) ",@function\n"
    SJ_STR(longjmp) ":\n"
    SJ_STR(siglongjmp) ":\n"
    "    movl %esi, %eax\n"
    "    testl %eax, %eax\n"
    "    jnz 1f\n"
    "    incl %eax\n"                /* a value of 0 makes setjmp return 1 */
    "1:  cmpl $0, 64(%rdi)\n"
    "    je 2f\n"
    "    movq %rdi, %r12\n"          /* r12 and r13 are reloaded from the buffer below, so they are free to use here */
    "    movl %eax, %r13d\n"
    "    subq $8, %rsp\n"
    "    call __moqi_sj_restore_mask\n"
    "    addq $8, %rsp\n"
    "    movq %r12, %rdi\n"
    "    movl %r13d, %eax\n"
    "2:  movq 0(%rdi), %rbx\n"
    "    movq 8(%rdi), %rbp\n"
    "    movq 16(%rdi), %r12\n"
    "    movq 24(%rdi), %r13\n"
    "    movq 32(%rdi), %r14\n"
    "    movq 40(%rdi), %r15\n"
    "    movq 48(%rdi), %rsp\n"
    "    jmp *56(%rdi)\n"
    ".size " SJ_STR(longjmp) ", .-" SJ_STR(longjmp) "\n"

    ".popsection\n");
