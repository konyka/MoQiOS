/// hello122: execve(2) / execveat(2) errors and name resolution.
///
///   A. Failures return the Linux errno and the caller keeps running:
///      a missing program ENOENT, a flat (non-ELF) ramdisk program such as
///      hello2 ENOEXEC (spawn can load those, exec cannot), a bad path
///      pointer EFAULT, unknown execveat flags EINVAL, a closed dirfd
///      EBADF, a regular-file dirfd ENOTDIR, a name below a directory that
///      is not on the ramdisk ENOENT.
///   B. Successful execs (checked through the child's exit status 42 from
///      hello11, an ELF): execve("hello11"), execve("/hello11"),
///      execveat(AT_FDCWD), execveat(dirfd of testdir, "../hello11"),
///      execve("../hello11") from the cwd /testdir (a bare "hello11" there
///      is ENOENT), and an absolute name that ignores a bad dirfd.

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

#define SYS_WRITE     1
#define SYS_EXIT      2
#define SYS_WAITPID   6
#define SYS_OPEN      9
#define SYS_CLOSE     11
#define SYS_FORK      57
#define SYS_EXECVE    59
#define SYS_CHDIR     80
#define SYS_EXECVEAT  322
#define AT_FDCWD      ((uint64_t)-100)

#define ENOENT_  2
#define ENOEXEC_ 8
#define EBADF_   9
#define EFAULT_  14
#define ENOTDIR_ 20
#define EINVAL_  22

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello122:   ok   " : "hello122:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static char *const argv_hello11[] = { "hello11", 0 };

/* fork; the child chdirs to `cwd` (if set) and runs one exec call; returns
 * the child's exit code, or -1 */
static int run_exec(const char *cwd, uint64_t nr, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e) {
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        if (cwd) syscall1(SYS_CHDIR, (uint64_t)cwd);
        int64_t r;
        if (nr == SYS_EXECVE) r = syscall3(SYS_EXECVE, a, b, c);
        else r = syscall5(SYS_EXECVEAT, a, b, c, d, e);
        /* exit 100 + errno so a failure says why */
        syscall1(SYS_EXIT, (uint64_t)(100 + (r < 0 ? -r : 0)));
        for (;;) {}
    }
    if (pid < 0) return -1;
    int status = 0;
    if (syscall3(SYS_WAITPID, (uint64_t)pid, (uint64_t)&status, 0) != pid) return -1;
    return (status >> 8) & 0xff;
}

void _start(void) {
    print("hello122: execve/execveat errors and name resolution\n");
    uint64_t av = (uint64_t)argv_hello11;

    /* A: errors, the caller keeps running */
    check(syscall3(SYS_EXECVE, (uint64_t)"h122-nope", av, 0) == -ENOENT_, "A: a missing program is ENOENT");
    check(syscall3(SYS_EXECVE, 0, av, 0) == -EFAULT_, "A: a NULL path is EFAULT");
    check(syscall3(SYS_EXECVE, (uint64_t)"hello2", av, 0) == -ENOEXEC_, "A: a flat (non-ELF) ramdisk program is ENOEXEC for exec");
    check(syscall5(SYS_EXECVEAT, AT_FDCWD, (uint64_t)"hello11", av, 0, 0x2) == -EINVAL_, "A: unknown execveat flags are EINVAL");
    check(syscall5(SYS_EXECVEAT, 200, (uint64_t)"hello11", av, 0, 0) == -EBADF_, "A: a closed dirfd is EBADF");
    {
        int64_t ffd = syscall2(SYS_OPEN, (uint64_t)"hello11", 0);
        check(ffd >= 0 && syscall5(SYS_EXECVEAT, (uint64_t)ffd, (uint64_t)"x", av, 0, 0) == -ENOTDIR_, "A: a regular-file dirfd is ENOTDIR");
        if (ffd >= 0) syscall1(SYS_CLOSE, (uint64_t)ffd);
    }
    check(syscall3(SYS_EXECVE, (uint64_t)"/testdir/hello11", av, 0) == -ENOENT_, "A: a name below a directory is not on the ramdisk (ENOENT)");
    check(syscall5(SYS_EXECVEAT, AT_FDCWD, (uint64_t)"", av, 0, 0x1000) == -ENOENT_, "A: AT_EMPTY_PATH is ENOENT (programs are not opened as fds)");

    /* B: successful execs */
    check(run_exec(0, SYS_EXECVE, (uint64_t)"hello11", av, 0, 0, 0) == 42, "B: execve hello11");
    check(run_exec(0, SYS_EXECVE, (uint64_t)"/hello11", av, 0, 0, 0) == 42, "B: execve /hello11");
    check(run_exec(0, SYS_EXECVEAT, AT_FDCWD, (uint64_t)"hello11", av, 0, 0) == 42, "B: execveat(AT_FDCWD, hello11)");
    {
        int64_t dfd = syscall2(SYS_OPEN, (uint64_t)"testdir", 0);
        check(dfd >= 0 && run_exec(0, SYS_EXECVEAT, (uint64_t)dfd, (uint64_t)"../hello11", av, 0, 0) == 42, "B: execveat(dirfd of testdir, ../hello11)");
        if (dfd >= 0) syscall1(SYS_CLOSE, (uint64_t)dfd);
    }
    check(run_exec("/testdir", SYS_EXECVE, (uint64_t)"../hello11", av, 0, 0, 0) == 42, "B: execve ../hello11 from the cwd /testdir");
    check(run_exec("/testdir", SYS_EXECVE, (uint64_t)"hello11", av, 0, 0, 0) == 100 + ENOENT_, "B: execve hello11 from /testdir does not find the root program");
    check(run_exec(0, SYS_EXECVEAT, 200, (uint64_t)"/hello11", av, 0, 0) == 42, "B: an absolute name ignores a bad dirfd");

    print(failures == 0 ? "hello122: PASS\n" : "hello122: FAIL\n");
    print("hello122 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
