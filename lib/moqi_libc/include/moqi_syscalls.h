/* moqi_syscalls.h — MoQiOS syscall numbers and raw syscall wrappers.
 *
 * Single source of truth for the user-side syscall ABI. Numbers match the
 * kernel dispatch table (kernel/arch/x86_64/syscall_entry.zig, the
 * `switch (syscall_nr)` in syscallDispatch). Do not renumber: the kernel
 * ABI is fixed.
 *
 * ABI: number in rax, args in rdi/rsi/rdx/r10/r8/r9, return in rax
 * (negative small integer = -errno). rcx/r11 are clobbered by `syscall`.
 */
#ifndef MOQI_SYSCALLS_H
#define MOQI_SYSCALLS_H

/* Process control */
#define SYS_exit        2
#define SYS_getpid      4
#define SYS_spawn       5
#define SYS_waitpid     6
#define SYS_fork        57
#define SYS_execve      59
#define SYS_kill        62
#define SYS_uname       63

/* Memory */
#define SYS_brk         7
#define SYS_mmap        8
#define SYS_munmap      12

/* File I/O */
#define SYS_write       1
#define SYS_open        9
#define SYS_read        10
#define SYS_close       11
#define SYS_dup2        33
#define SYS_pipe        22
#define SYS_lseek       197
#define SYS_fstat       110
#define SYS_unlink      111
#define SYS_mkdir       123

/* Signals */
#define SYS_sigaction   13
#define SYS_sigprocmask 14
#define SYS_sigreturn   15

/* Time / scheduling */
#define SYS_yield       24  /* sched_yield */
#define SYS_nanosleep   35
#define SYS_gettimeofday 96
#define SYS_clock_gettime 228

/* Environment / directories (MoQiOS-specific) */
#define SYS_getenv      105
#define SYS_setenv      106
#define SYS_listdir     107
#define SYS_chdir       108
#define SYS_getcwd      109

/* Resource limits */
#define SYS_getrlimit   236
#define SYS_setrlimit   237
#define SYS_prlimit64   238

static inline long syscall0(long n) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n) : "rcx", "r11", "memory");
    return ret;
}

static inline long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline long syscall2(long n, long a1, long a2) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

static inline long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static inline long syscall4(long n, long a1, long a2, long a3, long a4) {
    long ret;
    register long r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}

static inline long syscall5(long n, long a1, long a2, long a3, long a4, long a5) {
    long ret;
    register long r10 __asm__("r10") = a4;
    register long r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}

static inline long syscall6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
    long ret;
    register long r10 __asm__("r10") = a4;
    register long r8 __asm__("r8") = a5;
    register long r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

#endif /* MOQI_SYSCALLS_H */
