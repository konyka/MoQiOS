/* test_system_abi.c — system() (src/system.c) against a recording system-call stub. The expectations are what glibc does
 * (measured on glibc 2.43): system(NULL) says a shell exists (non-zero); the command runs in a child through the shell with
 * "-c"; the wait status is returned as it is; while it runs SIGINT and SIGQUIT are ignored and SIGCHLD is blocked in the
 * caller, and all three are put back afterwards; a failed fork is -1 with errno; a shell that cannot be started exits with 127.
 */
#include <errno.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"
#include "../include/signal.h"

int moqi_system(const char *cmd);

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

#define MAXCALLS 32
static int ncalls;
static long c_nr[MAXCALLS], c_a1[MAXCALLS], c_a2[MAXCALLS], c_a3[MAXCALLS];
static unsigned long c_mask[MAXCALLS];                    /* sigprocmask: the set passed in */
static unsigned long c_handler[MAXCALLS];                 /* sigaction: the handler installed */
static char c_path[MAXCALLS][32], c_arg0[MAXCALLS][32], c_arg1[MAXCALLS][32], c_arg2[MAXCALLS][256];

static long fork_reply;                                   /* >0: parent path, 0: child path, <0: failure */
static long exec_reply;
static long wait_status;
static long wait_reply;                                   /* pid, or -errno; -EINTR is returned wait_eintr times first */
static int wait_eintr;
static unsigned long old_mask_reply = 0x00000000000000a0UL;
static unsigned long old_int_handler = 0x1234;
static jmp_buf out;
static int exit_status = -1;

void moqi__exit(int code) { exit_status = code; longjmp(out, 1); }

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a4; (void)a5; (void)a6;
    int i = ncalls < MAXCALLS ? ncalls : MAXCALLS - 1;
    ncalls++;
    c_nr[i] = nr; c_a1[i] = a1; c_a2[i] = a2; c_a3[i] = a3;
    switch (nr) {
    case SYS_sigprocmask:
        if (a2 > 4096) c_mask[i] = *(unsigned long *)a2;
        if (a3 > 4096) *(unsigned long *)a3 = old_mask_reply;
        return 0;
    case SYS_sigaction:
        if (a2 > 4096) c_handler[i] = *(unsigned long *)a2;
        if (a3 > 4096) { unsigned long *o = (unsigned long *)a3; o[0] = old_int_handler; o[1] = 0x10000000UL; o[2] = 0; o[3] = 0; }
        return 0;
    case SYS_fork:
        return fork_reply;
    case SYS_execve: {
        const char *path = (const char *)a1;
        const char *const *argv = (const char *const *)a2;
        strncpy(c_path[i], path, 31);
        if (argv[0]) strncpy(c_arg0[i], argv[0], 31);
        if (argv[0] && argv[1]) strncpy(c_arg1[i], argv[1], 31);
        if (argv[0] && argv[1] && argv[2]) strncpy(c_arg2[i], argv[2], 255);
        return exec_reply;
    }
    case SYS_waitpid:
        if (wait_eintr > 0) { wait_eintr--; return -4; }
        if (a2 > 4096 && wait_reply > 0) *(int *)a2 = (int)wait_status;
        return wait_reply;
    }
    return -38;
}

static void reset(void) {
    ncalls = 0; fork_reply = 1234; exec_reply = 0; wait_status = 0; wait_reply = 1234; wait_eintr = 0; errno_slot = 0; exit_status = -1;
    memset(c_path, 0, sizeof c_path); memset(c_arg0, 0, sizeof c_arg0); memset(c_arg1, 0, sizeof c_arg1); memset(c_arg2, 0, sizeof c_arg2);
}
static int find(long nr, int from) { for (int k = from; k < ncalls; k++) if (c_nr[k] == nr) return k; return -1; }

int main(void) {
    CHECK(SYS_fork == 57 && SYS_execve == 59 && SYS_waitpid == 6);

    /* system(NULL): is there a shell? Yes, without running anything. */
    reset();
    CHECK(moqi_system((const char *)0) != 0 && ncalls == 0);

    /* the parent path: the status comes back untouched */
    reset(); wait_status = 768;
    CHECK(moqi_system("exit 3") == 768);
    reset(); wait_status = 9;
    CHECK(moqi_system("x") == 9);
    reset(); wait_status = 0;
    CHECK(moqi_system("true") == 0);
    {
        int f = find(SYS_fork, 0), w = find(SYS_waitpid, 0);
        CHECK(f >= 0 && w > f);
        CHECK(c_a1[w] == 1234 && c_a3[w] == 0);                                /* waits for that child, no options */
    }

    /* signals around the call: block SIGCHLD, ignore SIGINT and SIGQUIT, then put everything back */
    reset();
    moqi_system("x");
    {
        int b = find(SYS_sigprocmask, 0);
        CHECK(b >= 0 && c_a1[b] == SIG_BLOCK && c_mask[b] == (1UL << (SIGCHLD - 1)));
        int f = find(SYS_fork, 0);
        CHECK(b < f);
        int ign_int = -1, ign_quit = -1;
        for (int k = 0; k < f; k++)
            if (c_nr[k] == SYS_sigaction && c_handler[k] == 1) { if (c_a1[k] == SIGINT) ign_int = k; if (c_a1[k] == SIGQUIT) ign_quit = k; }
        CHECK(ign_int >= 0 && ign_quit >= 0);
        int w = find(SYS_waitpid, 0);
        int rest_int = -1, rest_quit = -1, rest_mask = -1;
        for (int k = w + 1; k < ncalls; k++) {
            if (c_nr[k] == SYS_sigaction && c_handler[k] == old_int_handler) { if (c_a1[k] == SIGINT) rest_int = k; if (c_a1[k] == SIGQUIT) rest_quit = k; }
            if (c_nr[k] == SYS_sigprocmask && c_a1[k] == SIG_SETMASK && c_mask[k] == old_mask_reply) rest_mask = k;
        }
        CHECK(rest_int > w && rest_quit > w && rest_mask > w);                  /* restored after the wait, to what they were */
    }

    /* the child path: restore the mask and handlers, run "sh -c <command>", exit 127 if that fails */
    reset(); fork_reply = 0; exec_reply = 0;
    if (setjmp(out) == 0) moqi_system("echo hi | cat");
    {
        int e = find(SYS_execve, 0);
        CHECK(e >= 0);
        CHECK(strcmp(c_path[e], "sh") == 0 && strcmp(c_arg0[e], "sh") == 0 && strcmp(c_arg1[e], "-c") == 0);
        CHECK(strcmp(c_arg2[e], "echo hi | cat") == 0);
        int f = find(SYS_fork, 0);
        int m = -1;
        for (int k = f + 1; k < e; k++) if (c_nr[k] == SYS_sigprocmask && c_a1[k] == SIG_SETMASK && c_mask[k] == old_mask_reply) m = k;
        CHECK(m > f);                                                           /* the child does not inherit the blocked SIGCHLD */
        CHECK(find(SYS_waitpid, 0) < 0);                                        /* and does not wait */
    }
    reset(); fork_reply = 0; exec_reply = -2;
    if (setjmp(out) == 0) moqi_system("x");
    CHECK(exit_status == 127);

    /* fork fails: -1 with the error, and the signals are put back */
    reset(); fork_reply = -11;
    CHECK(moqi_system("x") == -1 && errno_slot == EAGAIN);
    {
        int rest_mask = -1;
        int f = find(SYS_fork, 0);
        for (int k = f + 1; k < ncalls; k++) if (c_nr[k] == SYS_sigprocmask && c_a1[k] == SIG_SETMASK) rest_mask = k;
        CHECK(rest_mask > f && find(SYS_waitpid, 0) < 0);
    }

    /* an interrupted wait is retried; any other wait error is -1 */
    reset(); wait_eintr = 3; wait_status = 256;
    CHECK(moqi_system("x") == 256);
    reset(); wait_reply = -10; errno_slot = 0;
    CHECK(moqi_system("x") == -1 && errno_slot == ECHILD);

    if (bad) { fprintf(stderr, "test_system_abi: %d failure(s)\n", bad); return 1; }
    printf("test_system_abi: ok\n");
    return 0;
}
