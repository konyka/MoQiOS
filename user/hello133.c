/// hello133: process lifecycle: wait status encoding, wait options and errors,
/// orphaning, process groups and sessions.

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
#define SYS_FORK      57
#define SYS_GETPID    39
#define SYS_KILL      62
#define SYS_WAIT4     263
#define SYS_GETPPID   205
#define SYS_SETSID    206
#define SYS_SETPGID   207
#define SYS_GETPGID   208
#define SYS_GETSID    209
#define SYS_NANOSLEEP 35
#define SYS_SIGACTION 13

#define WNOHANG 1
#define SIGKILL 9
#define SIGTERM 15
#define SIGUSR1 10

#define ECHILD_ 10
#define EINVAL_ 22
#define ESRCH_  3
#define EPERM_  1

struct ts { int64_t sec, nsec; };
static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}
static int failures = 0;
static void check(int ok, const char *what) {
    print(ok ? "hello133:   ok   " : "hello133:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static void sleep_ms(int ms) {
    struct ts t = { 0, (int64_t)ms * 1000000 };
    syscall2(SYS_NANOSLEEP, (uint64_t)&t, 0);
}
/* spawn a child that exits with `code`, sleeping `ms` first */
static int64_t child_exit(int code, int ms) {
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        if (ms) sleep_ms(ms);
        syscall1(SYS_EXIT, (uint64_t)code);
        for (;;) {}
    }
    return pid;
}
/* spawn a child that waits to be killed */
static int64_t child_wait_forever(void) {
    int64_t pid = syscall1(SYS_FORK, 0);
    if (pid == 0) {
        for (;;) sleep_ms(50);
    }
    return pid;
}

void _start(void) {
    print("hello133: process lifecycle\n");
    int status;

    /* A: exit status encoding */
    int64_t c = child_exit(7, 0);
    status = -1;
    check(syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&status, 0) == c, "A: waitpid returns the child pid");
    check((status & 0x7f) == 0 && ((status >> 8) & 0xff) == 7, "A: exit(7) is WIFEXITED with status 7");
    c = child_exit(255, 0);
    status = -1;
    syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&status, 0);
    check((status & 0x7f) == 0 && ((status >> 8) & 0xff) == 255, "A: exit(255) keeps 255");
    c = child_exit(256 + 3, 0);
    status = -1;
    syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&status, 0);
    check(((status >> 8) & 0xff) == 3, "A: only the low 8 bits of the exit code survive");
    c = child_exit(137, 0);
    status = -1;
    syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&status, 0);
    check((status & 0x7f) == 0 && ((status >> 8) & 0xff) == 137, "A: exit(137) is an exit, not a SIGKILL death");

    /* B: death by signal */
    c = child_wait_forever();
    sleep_ms(20);
    check(syscall2(SYS_KILL, (uint64_t)c, SIGKILL) == 0, "B: kill(SIGKILL)");
    status = -1;
    check(syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&status, 0) == c, "B: waitpid reaps the killed child");
    check((status & 0x7f) == SIGKILL && ((status >> 8) & 0xff) == 0, "B: the status is WIFSIGNALED with WTERMSIG == SIGKILL");
    c = child_wait_forever();
    sleep_ms(20);
    syscall2(SYS_KILL, (uint64_t)c, SIGTERM);
    status = -1;
    syscall3(SYS_WAITPID, (uint64_t)c, (uint64_t)&status, 0);
    check((status & 0x7f) == SIGTERM, "B: a default-action SIGTERM is WTERMSIG == SIGTERM");

    /* C: options and errors */
    check(syscall3(SYS_WAITPID, (uint64_t)-1, 0, WNOHANG) == -ECHILD_, "C: with no children waitpid is ECHILD");
    c = child_exit(0, 100);
    check(syscall3(SYS_WAITPID, (uint64_t)c, 0, WNOHANG) == 0, "C: WNOHANG with a running child returns 0");
    check(syscall4(SYS_WAIT4, (uint64_t)c, 0, 0x4, 0) == -EINVAL_, "C: wait4 with unknown options is EINVAL");
    check(syscall3(SYS_WAITPID, (uint64_t)c + 100000, 0, 0) == -ECHILD_, "C: waiting for a pid that is not our child is ECHILD");
    status = -1;
    check(syscall4(SYS_WAIT4, (uint64_t)c, (uint64_t)&status, 0, 0) == c && ((status >> 8) & 0xff) == 0, "C: wait4 reaps it");
    check(syscall3(SYS_WAITPID, (uint64_t)c, 0, WNOHANG) == -ECHILD_, "C: a reaped child cannot be waited for again (ECHILD)");

    /* D: wait for any child returns whichever exits first */
    int64_t slow = child_exit(1, 150);
    int64_t fast = child_exit(2, 0);
    status = -1;
    int64_t got = syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);
    check(got == fast && ((status >> 8) & 0xff) == 2, "D: waitpid(-1) returns the child that exited first");
    status = -1;
    got = syscall3(SYS_WAITPID, (uint64_t)-1, (uint64_t)&status, 0);
    check(got == slow && ((status >> 8) & 0xff) == 1, "D: and then the other one");

    /* E: pids and orphaning */
    int64_t me = syscall1(SYS_GETPID, 0);
    check(me > 0 && syscall1(SYS_GETPPID, 0) > 0, "E: getpid and getppid are positive");
    {
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            syscall1(SYS_EXIT, syscall1(SYS_GETPPID, 0) == me ? 0 : 9);
            for (;;) {}
        }
        status = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&status, 0);
        check(((status >> 8) & 0xff) == 0, "E: the child's getppid is the parent's pid");
    }

    /* F: process groups and sessions */
    int64_t pg = syscall1(SYS_GETPGID, 0);
    check(pg > 0, "F: getpgid(0) is positive");
    check(syscall1(SYS_GETPGID, 999999) == -ESRCH_, "F: getpgid of a missing pid is ESRCH");
    check(syscall1(SYS_GETSID, 999999) == -ESRCH_, "F: getsid of a missing pid is ESRCH");
    check(syscall2(SYS_SETPGID, 0, (uint64_t)-1) == -EINVAL_, "F: setpgid with a negative pgid is EINVAL");
    check(syscall2(SYS_SETPGID, 999999, 0) == -ESRCH_, "F: setpgid of a missing pid is ESRCH");
    {
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            int ok = syscall1(SYS_SETSID, 0) > 0;
            int64_t sid = syscall1(SYS_GETSID, 0), pgid = syscall1(SYS_GETPGID, 0), pid = syscall1(SYS_GETPID, 0);
            ok = ok && sid == pid && pgid == pid;
            /* a session leader cannot be moved to another group, and cannot setsid again */
            ok = ok && syscall1(SYS_SETSID, 0) == -EPERM_;
            syscall1(SYS_EXIT, ok ? 0 : 1);
            for (;;) {}
        }
        status = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&status, 0);
        check(((status >> 8) & 0xff) == 0, "F: setsid makes the caller session and group leader; a second setsid is EPERM");
    }
    {
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            int64_t mypid = syscall1(SYS_GETPID, 0);
            int ok = syscall2(SYS_SETPGID, 0, 0) == 0 && syscall1(SYS_GETPGID, 0) == mypid;
            syscall1(SYS_EXIT, ok ? 0 : 1);
            for (;;) {}
        }
        status = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&status, 0);
        check(((status >> 8) & 0xff) == 0, "F: setpgid(0, 0) makes the caller its own group leader");
    }
    {
        /* waitpid(0) waits for a child in our own group; a child that moved to its own
         * group is not selected, so with no other children it is ECHILD */
        int64_t p = syscall1(SYS_FORK, 0);
        if (p == 0) {
            syscall2(SYS_SETPGID, 0, 0);
            sleep_ms(250);
            syscall1(SYS_EXIT, 0);
            for (;;) {}
        }
        sleep_ms(60); /* the child has moved to its own group by now */
        check(syscall3(SYS_WAITPID, 0, 0, WNOHANG) == -ECHILD_, "F: waitpid(0) does not select a child that left our group (ECHILD)");
        check(syscall3(SYS_WAITPID, (uint64_t)-1, 0, WNOHANG) == 0, "F: but waitpid(-1) still sees it as a running child");
        status = -1;
        syscall3(SYS_WAITPID, (uint64_t)p, (uint64_t)&status, 0);
        /* waitpid(-pgid) selects by group */
        int64_t q = syscall1(SYS_FORK, 0);
        if (q == 0) {
            syscall2(SYS_SETPGID, 0, 0);
            sleep_ms(100);
            syscall1(SYS_EXIT, 4);
            for (;;) {}
        }
        sleep_ms(30);
        check(syscall3(SYS_WAITPID, (uint64_t)-q, (uint64_t)&status, 0) == q && ((status >> 8) & 0xff) == 4, "F: waitpid(-pgid) selects a child in that group");
        check(syscall3(SYS_WAITPID, (uint64_t)-(q + 1000), 0, WNOHANG) == -ECHILD_, "F: waitpid of an empty group is ECHILD");
    }

    print(failures == 0 ? "hello133: PASS\n" : "hello133: FAIL\n");
    print("hello133 done\n");
    syscall1(SYS_EXIT, failures == 0 ? 0 : 1);
    for (;;) {}
}
