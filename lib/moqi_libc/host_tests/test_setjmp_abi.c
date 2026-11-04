/* test_setjmp_abi.c — setjmp, sigsetjmp, longjmp, siglongjmp (include/setjmp.h, src/setjmp.c).
 *
 * The library's functions are compiled under other names (-Dsetjmp=moqi_setjmp and so on, see run_tests.sh) so they cannot
 * collide with the host's. The signal-mask system call is a recording stub (moqi_test_syscall6). What the host's glibc does
 * for the same calls is what the expectations say: setjmp does not save the signal mask, sigsetjmp(env, 0) does not, and
 * sigsetjmp(env, nonzero) does and siglongjmp (and longjmp on that buffer) puts it back; longjmp(env, 0) makes setjmp return 1.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../include/setjmp.h"

/* ---- the system call stub ------------------------------------------------------------------------------------------ */

static long stub_calls;
static long stub_nr[16], stub_a1[16], stub_a2[16], stub_a3[16], stub_a4[16];
static unsigned long stub_mask_reply = 0x1234;   /* what "read the current mask" returns */
static long stub_ret;                            /* the value every call returns */
static unsigned long stub_set_seen[16];

static long misaligned_calls;

/* Called from the library's C helpers, which setjmp and longjmp reach with a call instruction: the System V ABI wants the stack
 * 16-byte aligned at that call, and the frame of any function entered that way then sits on a 16-byte boundary. */
__attribute__((noinline)) long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a5;
    (void)a6;
    if (((uintptr_t)__builtin_frame_address(0) & 15) != 0) misaligned_calls++;
    long i = stub_calls < 16 ? stub_calls : 15;
    stub_calls++;
    stub_nr[i] = nr;
    stub_a1[i] = a1;
    stub_a2[i] = a2;
    stub_a3[i] = a3;
    stub_a4[i] = a4;
    if (nr == 14 && a2) stub_set_seen[i] = *(unsigned long *)a2;
    if (nr == 14 && a3 && stub_ret == 0) *(unsigned long *)a3 = stub_mask_reply;
    return stub_ret;
}

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

/* ---- the callee-saved registers: a thunk puts known values in them, calls setjmp, scribbles, longjmps back ------------ */

#define XSTR_(x) #x
#define XSTR(x) XSTR_(x)
int test_regs_thunk(jmp_buf env, unsigned long out[8]);
__asm__(
    ".pushsection .text\n"
    ".globl test_regs_thunk\n"
    ".type test_regs_thunk,@function\n"
    "test_regs_thunk:\n"
    "    push %rbx\n    push %rbp\n    push %r12\n    push %r13\n    push %r14\n    push %r15\n"
    "    sub $24, %rsp\n"
    "    mov %rdi, (%rsp)\n"
    "    mov %rsi, 8(%rsp)\n"
    "    movabs $0x1111111111111111, %rbx\n"
    "    movabs $0x2222222222222222, %rbp\n"
    "    movabs $0x3333333333333333, %r12\n"
    "    movabs $0x4444444444444444, %r13\n"
    "    movabs $0x5555555555555555, %r14\n"
    "    movabs $0x6666666666666666, %r15\n"
    "    call " XSTR(setjmp) "\n"
    "    test %eax, %eax\n"
    "    jnz 1f\n"
    "    movabs $0xdeadbeefdeadbeef, %rbx\n"
    "    movabs $0xdeadbeefdeadbee0, %rbp\n"
    "    movabs $0xdeadbeefdeadbee1, %r12\n"
    "    movabs $0xdeadbeefdeadbee2, %r13\n"
    "    movabs $0xdeadbeefdeadbee3, %r14\n"
    "    movabs $0xdeadbeefdeadbee4, %r15\n"
    "    mov (%rsp), %rdi\n"
    "    mov $7, %esi\n"
    "    call " XSTR(longjmp) "\n"
    "1:  mov 8(%rsp), %rdi\n"
    "    mov %rbx, 0(%rdi)\n"
    "    mov %rbp, 8(%rdi)\n"
    "    mov %r12, 16(%rdi)\n"
    "    mov %r13, 24(%rdi)\n"
    "    mov %r14, 32(%rdi)\n"
    "    mov %r15, 40(%rdi)\n"
    "    mov %rsp, 48(%rdi)\n"
    "    add $24, %rsp\n"
    "    pop %r15\n    pop %r14\n    pop %r13\n    pop %r12\n    pop %rbp\n    pop %rbx\n"
    "    ret\n"
    ".size test_regs_thunk, .-test_regs_thunk\n"
    ".popsection\n");

/* ---- plain control flow -------------------------------------------------------------------------------------------- */

static jmp_buf g_env;
static volatile int g_depth_seen;

static void dive(int n) {
    volatile char pad[256];
    pad[0] = (char)n;
    pad[255] = (char)n;
    if (n == 0) {
        g_depth_seen = 1;
        longjmp(g_env, 42);
    }
    dive(n - 1);
    g_depth_seen = -1; /* never reached */
    (void)pad;
}

static int via_function_value(void) {
    jmp_buf env;
    volatile int step = 0;
    int r = setjmp(env);
    if (r == 0) {
        step = 1;
        longjmp(env, 9);
    }
    return r * 10 + step;
}

int main(void) {
    /* ---- setjmp returns 0 first, then whatever longjmp passes ---- */
    {
        jmp_buf env;
        volatile int count = 0;
        int r = setjmp(env);
        if (r == 0) {
            CHECK(count == 0);
            count = 1;
            longjmp(env, 5);
        }
        CHECK(r == 5 && count == 1);
    }
    {
        jmp_buf env;
        volatile int seen = 0;
        int r = setjmp(env);
        if (r == 0) {
            seen = 1;
            longjmp(env, 0);
        }
        CHECK(r == 1 && seen == 1); /* a value of 0 becomes 1 */
    }
    {
        jmp_buf env;
        int r = setjmp(env);
        if (r == 0) longjmp(env, -3);
        CHECK(r == -3);
        r = setjmp(env);
        if (r == 0) longjmp(env, 0x7fffffff);
        CHECK(r == 0x7fffffff);
        r = setjmp(env);
        if (r == 0) longjmp(env, (int)0x80000000u);
        CHECK(r == (int)0x80000000u);
    }
    CHECK(via_function_value() == 91);

    /* ---- a loop that re-enters the same setjmp many times ---- */
    {
        jmp_buf env;
        volatile int n = 0;
        int r = setjmp(env);
        if (r < 100000) {
            n = n + 1;
            longjmp(env, r + 1);
        }
        CHECK(r == 100000 && n == 100000);
    }

    /* ---- out of a deep recursion: the stack pointer and frames above are intact ---- */
    {
        volatile int local = 1234;
        void *frame = __builtin_frame_address(0);
        int r = setjmp(g_env);
        if (r == 0) dive(2000);
        CHECK(r == 42 && g_depth_seen == 1 && local == 1234 && frame == __builtin_frame_address(0));
        volatile char big[4096];
        memset((void *)big, 0x5a, sizeof big);
        CHECK(big[0] == 0x5a && big[4095] == 0x5a);
    }

    /* ---- every callee-saved register comes back as it was at setjmp ---- */
    {
        jmp_buf env;
        unsigned long out[8] = { 0 };
        int r = test_regs_thunk(env, out);
        (void)r;
        CHECK(out[0] == 0x1111111111111111UL);
        CHECK(out[1] == 0x2222222222222222UL);
        CHECK(out[2] == 0x3333333333333333UL);
        CHECK(out[3] == 0x4444444444444444UL);
        CHECK(out[4] == 0x5555555555555555UL);
        CHECK(out[5] == 0x6666666666666666UL);
        CHECK(out[6] != 0);
    }

    /* ---- setjmp and longjmp do not touch the signal mask ---- */
    {
        jmp_buf env;
        stub_calls = 0;
        int r = setjmp(env);
        if (r == 0) longjmp(env, 1);
        CHECK(r == 1 && stub_calls == 0);
    }

    /* ---- sigsetjmp(env, 0) does not save it either ---- */
    {
        sigjmp_buf env;
        stub_calls = 0;
        int r = sigsetjmp(env, 0);
        if (r == 0) siglongjmp(env, 3);
        CHECK(r == 3 && stub_calls == 0);
        r = sigsetjmp(env, 0);
        if (r == 0) longjmp(env, 4);
        CHECK(r == 4 && stub_calls == 0);
    }

    /* ---- sigsetjmp(env, nonzero) reads the mask once, siglongjmp writes it back once ---- */
    {
        sigjmp_buf env;
        stub_calls = 0;
        stub_ret = 0;
        stub_mask_reply = 0x1234;
        volatile long calls_at_resume = -1;
        int r = sigsetjmp(env, 1);
        if (r == 0) {
            CHECK(stub_calls == 1 && stub_nr[0] == 14 && stub_a1[0] == 0 /* SIG_BLOCK */ && stub_a2[0] == 0 && stub_a3[0] != 0 && stub_a4[0] == 8);
            stub_mask_reply = 0x9999; /* the mask changes after the save */
            siglongjmp(env, 6);
        }
        calls_at_resume = stub_calls;
        CHECK(r == 6 && calls_at_resume == 2);
        CHECK(stub_nr[1] == 14 && stub_a1[1] == 2 /* SIG_SETMASK */ && stub_set_seen[1] == 0x1234 && stub_a3[1] == 0 && stub_a4[1] == 8);
    }
    {
        sigjmp_buf env;
        stub_calls = 0;
        stub_mask_reply = 0x1234;
        int r = sigsetjmp(env, 77); /* any nonzero value means "save" */
        if (r == 0) siglongjmp(env, 0);
        CHECK(r == 1 && stub_calls == 2 && stub_set_seen[1] == 0x1234);
    }
    {
        /* longjmp on a buffer that sigsetjmp saved the mask in restores it too (glibc's longjmp is siglongjmp) */
        sigjmp_buf env;
        stub_calls = 0;
        int r = sigsetjmp(env, 1);
        if (r == 0) longjmp(env, 2);
        CHECK(r == 2 && stub_calls == 2 && stub_nr[1] == 14 && stub_a1[1] == 2);
    }
    {
        /* two saved buffers keep their own masks: jumping to the first restores the first one's */
        sigjmp_buf e1, e2;
        stub_calls = 0;
        stub_mask_reply = 0xaaaa;
        volatile int stage = 0;
        int r1 = sigsetjmp(e1, 1);
        if (stage == 0) {
            stub_mask_reply = 0xbbbb;
            stage = 1;
            int r2 = sigsetjmp(e2, 1);
            if (r2 == 0) siglongjmp(e1, 1);
        }
        CHECK(r1 == 1 && stub_calls == 3 && stub_set_seen[2] == 0xaaaa);
    }
    {
        /* when reading the mask fails, no claim is made and nothing is restored */
        sigjmp_buf env;
        stub_calls = 0;
        stub_ret = -14; /* EFAULT */
        int r = sigsetjmp(env, 1);
        stub_ret = 0;
        if (r == 0) siglongjmp(env, 8);
        CHECK(r == 8 && stub_calls == 1);
    }

    /* ---- the buffer types ---- */
    CHECK(sizeof(jmp_buf) >= 8 * sizeof(unsigned long) && sizeof(sigjmp_buf) == sizeof(jmp_buf));

    CHECK(misaligned_calls == 0);

    if (bad) {
        fprintf(stderr, "test_setjmp_abi: %d failures\n", bad);
        return 1;
    }
    printf("test_setjmp_abi OK\n");
    return 0;
}
