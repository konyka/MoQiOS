/* setjmp.h — non-local jumps (x86-64).
 *
 * jmp_buf holds the callee-saved registers (rbx, rbp, r12-r15), the stack pointer and the resume address, then a flag and
 * the signal mask for sigsetjmp. Behavior follows glibc as measured (host_tests/test_setjmp_abi.c):
 *   - setjmp returns 0, and again with the value passed to longjmp (1 if that value was 0);
 *   - setjmp and sigsetjmp(env, 0) do not save the signal mask; sigsetjmp(env, nonzero) reads it once and siglongjmp puts it
 *     back, and so does longjmp on such a buffer (glibc's longjmp is siglongjmp);
 *   - reading the mask can fail: nothing is saved then and nothing is restored later.
 * Not saved, as in glibc: the x87 control word, MXCSR, floating-point registers. The values of automatic variables changed
 * after setjmp and not declared volatile are indeterminate after the jump, as the C standard says.
 */
#ifndef MOQI_SETJMP_H
#define MOQI_SETJMP_H

struct __moqi_jmp_buf {
    unsigned long regs[8];   /* rbx rbp r12 r13 r14 r15 rsp rip */
    int mask_saved;
    unsigned long mask;
};

typedef struct __moqi_jmp_buf jmp_buf[1];
typedef struct __moqi_jmp_buf sigjmp_buf[1];

int  setjmp(jmp_buf env) __attribute__((returns_twice));
int  sigsetjmp(sigjmp_buf env, int savemask) __attribute__((returns_twice));
void longjmp(jmp_buf env, int val) __attribute__((noreturn));
void siglongjmp(sigjmp_buf env, int val) __attribute__((noreturn));

#endif /* MOQI_SETJMP_H */
