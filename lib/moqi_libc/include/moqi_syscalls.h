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
#define SYS_mremap      25
#define SYS_mprotect    164
#define SYS_madvise     235
#define SYS_mincore     251
#define SYS_mlock       252
#define SYS_munlock     253
#define SYS_msync       254
#define SYS_mlockall    271
#define SYS_munlockall  272

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
#define SYS_getdents64  173
#define SYS_fcntl       142
#define SYS_pread64     136
#define SYS_pwrite64    137
#define SYS_dup         160
#define SYS_dup3        161
#define SYS_access      198
#define SYS_truncate    210
#define SYS_ftruncate   211
#define SYS_fchdir      234
#define SYS_umask       239
#define SYS_fsync       244
#define SYS_sysinfo     99
#define SYS_sched_getaffinity 227
#define SYS_getrandom   242
#define SYS_link        86
#define SYS_symlink     88
#define SYS_readlink    89
#define SYS_chmod       90
#define SYS_fchmod      91
#define SYS_statx       183
#define SYS_statfs      276
#define SYS_fstatfs     277
#define SYS_fdatasync   245
#define SYS_pipe2       250
#define SYS_mkdir       123

/* Signals */
#define SYS_sigaction   13
#define SYS_sigprocmask 14
#define SYS_sigreturn   15
#define SYS_sigpending  219
#define SYS_sigsuspend  220
#define SYS_tkill       223
#define SYS_gettid      497
#define SYS_preadv2     498
#define SYS_pwritev2    499
#define SYS_waitid      500
#define SYS_exit_group  501
#define SYS_adjtimex    502
#define SYS_clock_adjtime 503

/* Processes, identity and terminals */
#define SYS_pause       34
#define SYS_alarm       37
#define SYS_ioctl       165
#define SYS_getuid      201
#define SYS_getgid      202
#define SYS_geteuid     203
#define SYS_getegid     204
#define SYS_getppid     205
#define SYS_rename      212
#define SYS_rmdir       84

/* Time / scheduling */
#define SYS_yield       24  /* sched_yield */
#define SYS_nanosleep   35
#define SYS_gettimeofday 96
#define SYS_clock_gettime 228
#define SYS_clock_nanosleep 247
#define SYS_clock_getres 269

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

/* Native IPC capability ABI */
#define SYS_moqipc_create_ep 297
#define SYS_moqipc_destroy_ep 298
#define SYS_moqipc_send 299
#define SYS_moqipc_recv 300
#define SYS_moqipc_call 301
#define SYS_moqipc_reply 302
#define SYS_moqipc_notify 303
#define SYS_moqipc_get_notify 304
#define SYS_moqipc_grant_cap 311
#define SYS_moqipc_grant_cap_to 486
#define SYS_socket      117
#define SYS_bind        118
#define SYS_listen      119
#define SYS_connect     124
#define SYS_accept4     131
#define SYS_netpoll     104
#define SYS_dns_resolve 495
#define SYS_mlock2 496
#define SYS_poll        162
#define SYS_ppoll       493
#define SYS_select      163
#define SYS_epoll_create1 146
#define SYS_epoll_ctl   147
#define SYS_epoll_wait  148
#define SYS_epoll_pwait 248
#define SYS_pselect6    494

static inline long moqi_ipc_create_ep(void) { return syscall0(SYS_moqipc_create_ep); }
static inline long moqi_ipc_destroy_ep(unsigned endpoint) { return syscall1(SYS_moqipc_destroy_ep, endpoint); }
static inline long moqi_ipc_send(unsigned endpoint, const void *message) { return syscall2(SYS_moqipc_send, endpoint, (long)message); }
static inline long moqi_ipc_recv(unsigned endpoint, void *message) { return syscall2(SYS_moqipc_recv, endpoint, (long)message); }
static inline long moqi_ipc_call(unsigned endpoint, void *message) { return syscall2(SYS_moqipc_call, endpoint, (long)message); }
static inline long moqi_ipc_reply(unsigned endpoint, const void *message) { return syscall2(SYS_moqipc_reply, endpoint, (long)message); }
static inline long moqi_ipc_notify(unsigned endpoint, unsigned long bits) { return syscall2(SYS_moqipc_notify, endpoint, (long)bits); }
static inline long moqi_ipc_get_notify(unsigned endpoint) { return syscall1(SYS_moqipc_get_notify, endpoint); }

static inline long moqi_grant_cap(unsigned endpoint, unsigned rights) {
    return syscall2(SYS_moqipc_grant_cap, endpoint, rights);
}

static inline long moqi_grant_cap_to(unsigned target_tid, unsigned endpoint, unsigned rights) {
    return syscall3(SYS_moqipc_grant_cap_to, target_tid, endpoint, rights);
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
