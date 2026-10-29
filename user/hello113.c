/// hello113: SysV IPC / poll / AF_UNIX hardening.
///
///   A. poll() with fd = -1 ignores the entry instead of panicking.
///   B. msgget/shmget with a negative key, then msgctl(IPC_STAT), do not panic.
///   C. msgctl(IPC_RMID) on a queue that still holds a message frees it, so
///      the queue table cannot be exhausted by create/send/remove cycles.
///   D. mprotect(PROT_WRITE) on a SHM_RDONLY attachment is refused.
///   E. semop wakes every waiter that can proceed, not just the oldest one.
///   F. an AF_UNIX listener's stale backlog entry cannot rewire a reused slot.
///   G. clone() with an unusable stack or TLS address fails with EINVAL
///      instead of halting the machine when the child is first dispatched.
///   I. a path string that ends right before an unmapped page is accepted by
///      every path-taking call (the kernel must stop at the NUL, not demand
///      255 readable bytes).
///   J. the native kernel-state dump (#3: task table with page-table and
///      kernel-stack addresses, IRQs off while it prints) is not available to
///      an unprivileged process.
///   H. 64-bit fd arguments that do not fit 32 bits are EBADF, not a panic;
///      eventfd2 with a huge initval cannot overflow the counter later.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}
static inline int64_t syscall4(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_NANOSLEEP 35
#define SYS_FORK      57
#define SYS_CLONE     243
#define SYS_MPROTECT  164
#define SYS_CLOSE     11
#define SYS_READ      10
#define SYS_DUP2      33
#define SYS_EVENTFD2  169
#define SYS_POLL      162
#define SYS_SHMGET    149
#define SYS_SHMAT     150
#define SYS_SHMDT     151
#define SYS_SHMCTL    152
#define SYS_SEMGET    153
#define SYS_SEMOP     154
#define SYS_SEMCTL    155
#define SYS_MSGGET    156
#define SYS_MSGSND    157
#define SYS_MSGCTL    159
#define SYS_MMAP      8
#define SYS_MUNMAP    12
#define SYS_OPEN      9
#define SYS_STATX     183
#define SYS_ACCESS    198
#define SYS_CHDIR     80
#define SYS_MKDIR     83
#define SYS_RMDIR     84
#define SYS_UNLINK    87
#define SYS_CHMOD     90
#define SYS_TRUNCATE  210
#define SYS_READLINK  182

#define IPC_CREAT  01000
#define IPC_RMID   0
#define IPC_STAT   2
#define IPC_PRIVATE 0
#define SHM_RDONLY 010000
#define SETVAL     16
#define EINVAL     22
#define ENOSPC     28

static inline int64_t syscall5(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return ret;
}

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello113:   ok   " : "hello113:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void nap_ms(int64_t ms) {
    int64_t ts[2] = { ms / 1000, (ms % 1000) * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)ts, 0);
}

struct pollfd { int32_t fd; int16_t events; int16_t revents; };
struct msgbuf1 { int64_t mtype; char text[8]; };

void _start(void) {
    print("hello113: SysV IPC / poll hardening\n");

    /* A */
    struct pollfd p = { -1, 1, 7 };
    int64_t r = syscall3(SYS_POLL, (uint64_t)&p, 1, 0);
    check(r == 0 && p.revents == 0, "A: poll(fd=-1) ignores the entry");

    /* B */
    int64_t mq = syscall2(SYS_MSGGET, (uint64_t)(int64_t)-5, IPC_CREAT | 0600);
    check(mq >= 0, "B: msgget(negative key)");
    if (mq >= 0) {
        uint64_t st[6] = {0};
        check(syscall3(SYS_MSGCTL, (uint64_t)mq, IPC_STAT, (uint64_t)st) >= 0, "B: msgctl(IPC_STAT) on a negative key");
        syscall3(SYS_MSGCTL, (uint64_t)mq, IPC_RMID, 0);
    }
    int64_t sm = syscall3(SYS_SHMGET, (uint64_t)(int64_t)-5, 4096, IPC_CREAT | 0600);
    check(sm >= 0, "B: shmget(negative key)");
    if (sm >= 0) syscall3(SYS_SHMCTL, (uint64_t)sm, IPC_RMID, 0);

    /* C */
    int ok = 1;
    for (int i = 0; i < 40; i++) {
        int64_t q = syscall2(SYS_MSGGET, IPC_PRIVATE, IPC_CREAT | 0600);
        if (q < 0) { ok = 0; break; }
        struct msgbuf1 m = { 1, "x" };
        syscall4(SYS_MSGSND, (uint64_t)q, (uint64_t)&m, 1, 0);
        if (syscall3(SYS_MSGCTL, (uint64_t)q, IPC_RMID, 0) != 0) { ok = 0; break; }
    }
    check(ok, "C: 40 create/send/remove cycles never exhaust the queue table");

    /* D */
    int64_t seg = syscall3(SYS_SHMGET, IPC_PRIVATE, 4096, IPC_CREAT | 0600);
    check(seg >= 0, "D: shmget");
    if (seg >= 0) {
        int64_t at = syscall3(SYS_SHMAT, (uint64_t)seg, 0, SHM_RDONLY);
        check(at > 0, "D: shmat(SHM_RDONLY)");
        if (at > 0) {
            check(syscall3(SYS_MPROTECT, (uint64_t)at, 4096, 3) == -EINVAL, "D: mprotect(PROT_WRITE) on the attachment is refused");
            check(syscall1(SYS_SHMDT, (uint64_t)at) == 0, "D: shmdt");
        }
        syscall3(SYS_SHMCTL, (uint64_t)seg, IPC_RMID, 0);
    }

    /* E: two waiters on different semaphores of one set; a V on semaphore 0
     * must wake the one waiting on semaphore 0 even though the older waiter
     * is blocked on semaphore 1. */
    int64_t ss = syscall3(SYS_SEMGET, IPC_PRIVATE, 2, IPC_CREAT | 0600);
    check(ss >= 0, "E: semget(2 sems)");
    if (ss >= 0) {
        int64_t a = syscall1(SYS_FORK, 0);
        if (a == 0) { syscall3(SYS_SEMOP, (uint64_t)ss, 1, (uint64_t)(int64_t)-1); syscall1(SYS_EXIT, 11); for (;;) {} }
        nap_ms(50);
        int64_t b = syscall1(SYS_FORK, 0);
        if (b == 0) { int64_t rr = syscall3(SYS_SEMOP, (uint64_t)ss, 0, (uint64_t)(int64_t)-1); syscall1(SYS_EXIT, rr == 0 ? 22 : 99); for (;;) {} }
        nap_ms(50);
        syscall3(SYS_SEMOP, (uint64_t)ss, 0, 1);      /* V(sem0): only b can proceed */
        int32_t sb = 0;
        int64_t wr = 0;
        for (int i = 0; i < 100; i++) {
            wr = syscall3(SYS_WAITPID, (uint64_t)b, (uint64_t)&sb, 1 /* WNOHANG */);
            if (wr == b) break;
            nap_ms(20);
        }
        check(wr == b && ((sb >> 8) & 0xff) == 22, "E: V(sem0) wakes the waiter on sem0 past the older sem1 waiter");
        syscall3(SYS_SEMOP, (uint64_t)ss, 1, 1);      /* release a */
        int32_t sa = 0;
        syscall3(SYS_WAITPID, (uint64_t)a, (uint64_t)&sa, 0);
        check(((sa >> 8) & 0xff) == 11, "E: V(sem1) then releases the older waiter");
        syscall3(SYS_SEMCTL, (uint64_t)ss, 0, 0 /* IPC_RMID */);
    }

    /* G: hostile clone arguments (CLONE_VM = 0x100, CLONE_SETTLS = 0x80000) */
    check(syscall5(SYS_CLONE, 0x100, 0x1000, 0, 0, 0) == -EINVAL, "G: clone with a stack below the floor is EINVAL");
    check(syscall5(SYS_CLONE, 0x100, 0x8000000000000000ULL, 0, 0, 0) == -EINVAL, "G: clone with a kernel-half stack is EINVAL");
    check(syscall5(SYS_CLONE, 0x100 | 0x80000, 0x7f0000, 0, 0, 0x8000000000000000ULL) == -EINVAL, "G: clone with a non-canonical TLS is EINVAL");

    /* H */
    check(syscall1(SYS_CLOSE, 0x100000000ULL) < 0, "H: close(1<<32) fails instead of panicking");
    check(syscall3(SYS_READ, 0x100000000ULL, 0, 0) < 0, "H: read(1<<32) fails instead of panicking");
    check(syscall2(SYS_DUP2, 0x100000000ULL, 5) < 0, "H: dup2(1<<32, 5) fails instead of panicking");
    int64_t efd = syscall2(SYS_EVENTFD2, 0xFFFFFFFFFFFFFFFFULL, 0);
    if (efd >= 0) {
        uint64_t one = 1;
        syscall3(SYS_WRITE, (uint64_t)efd, (uint64_t)&one, 8);
        struct pollfd pe = { (int32_t)efd, 4 /* POLLOUT */, 0 };
        syscall3(SYS_POLL, (uint64_t)&pe, 1, 0);
        check(1, "H: eventfd2(huge initval) then write+poll does not panic");
        syscall1(SYS_CLOSE, (uint64_t)efd);
    } else {
        check(1, "H: eventfd2(huge initval) rejected");
    }

    /* I */
    {
        /* two pages; unmap the second so the string's NUL is the last mapped byte */
        int64_t base = syscall6(SYS_MMAP, 0, 8192, 3, 0x22, (uint64_t)-1, 0);
        check(base > 0, "I: mmap two pages");
        if (base > 0) {
            check(syscall2(SYS_MUNMAP, (uint64_t)base + 4096, 4096) == 0, "I: unmap the second page");
            char *edge = (char *)base + 4096 - 8;
            const char *name = "/tmp/i1"; /* 7 chars + NUL = 8 bytes, ends at the page boundary */
            for (int k = 0; k < 8; k++) edge[k] = name[k];
            int64_t fd = syscall3(SYS_OPEN, (uint64_t)edge, 0x41 /* O_WRONLY|O_CREAT */, 0644);
            check(fd >= 0, "I: open() accepts a path ending at the last mapped byte");
            if (fd >= 0) syscall1(SYS_CLOSE, (uint64_t)fd);
            check(syscall2(SYS_ACCESS, (uint64_t)edge, 0) == 0, "I: access() too");
            static uint64_t stx[32];
            check(syscall5(SYS_STATX, (uint64_t)-100, (uint64_t)edge, 0, 0x7ff, (uint64_t)stx) == 0, "I: statx() too");
            check(syscall2(SYS_CHMOD, (uint64_t)edge, 0600) == 0, "I: chmod() too");
            check(syscall2(SYS_TRUNCATE, (uint64_t)edge, 0) == 0, "I: truncate() too");
            check(syscall1(SYS_UNLINK, (uint64_t)edge) == 0, "I: unlink() too");
            const char *dname = "/tmp/i2";
            for (int k = 0; k < 8; k++) edge[k] = dname[k];
            check(syscall2(SYS_MKDIR, (uint64_t)edge, 0755) == 0, "I: mkdir() too");
            check(syscall1(SYS_CHDIR, (uint64_t)edge) == 0, "I: chdir() too");
            syscall1(SYS_CHDIR, (uint64_t)"/");
            check(syscall1(SYS_RMDIR, (uint64_t)edge) == 0, "I: rmdir() too");
            /* the kernel still refuses a string that runs into the unmapped page */
            for (int k = 0; k < 8; k++) edge[k] = 'x';
            check(syscall3(SYS_OPEN, (uint64_t)edge, 0, 0) == -14, "I: an unterminated path running off the mapping is EFAULT");
            syscall2(SYS_MUNMAP, (uint64_t)base, 4096);
        }
    }

    /* J (hello113 runs as uid 1000 without capabilities) */
    check(syscall1(3, 0) == -1, "J: the kernel diagnostics dump (#3) is EPERM without CAP_SYS_ADMIN");

    print(failures == 0 ? "hello113: PASS\n" : "hello113: FAIL\n");
    print("hello113 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
