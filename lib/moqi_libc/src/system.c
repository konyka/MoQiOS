/* system.c — system(3) (see include/stdlib.h).
 *
 * The command runs in a child as "sh -c command". As POSIX and glibc require, while it runs the caller ignores SIGINT and
 * SIGQUIT and blocks SIGCHLD, so that a terminal interrupt kills the command and not the waiting parent and no other wait
 * collects the child; all three are restored afterwards. The child gets the original mask and handlers back before it execs.
 */
#include "../include/errno.h"
#include "../include/signal.h"
#include "../include/stdlib.h"
#include "../include/unistd.h"
#include "hostsys.h"

int system(const char *command) {
    if (command == (const char *)0) return 1; /* a shell is available */

    unsigned long chld = 1UL << (SIGCHLD - 1);
    unsigned long old_mask = 0;
    MSYS4(SYS_sigprocmask, SIG_BLOCK, &chld, &old_mask, 8);

    struct ksigaction ign = { SIG_IGN, 0, (void *)0, 0 };
    struct ksigaction old_int = { SIG_DFL, 0, (void *)0, 0 }, old_quit = { SIG_DFL, 0, (void *)0, 0 };
    sigaction(SIGINT, &ign, &old_int);
    sigaction(SIGQUIT, &ign, &old_quit);

    long pid = MSYS0(SYS_fork);
    if (pid == 0) {
        sigaction(SIGINT, &old_int, (struct ksigaction *)0);
        sigaction(SIGQUIT, &old_quit, (struct ksigaction *)0);
        MSYS4(SYS_sigprocmask, SIG_SETMASK, &old_mask, 0, 8);
        char *argv[] = { (char *)"sh", (char *)"-c", (char *)command, (char *)0 };
        MSYS3(SYS_execve, "sh", argv, (char *const *)0);
        _exit(127);
    }

    int status = -1;
    int err = 0;
    if (__moqi_is_error(pid)) {
        err = (int)-pid;
    } else {
        long r;
        do {
            status = 0;
            r = MSYS3(SYS_waitpid, pid, &status, 0);
        } while (r == -EINTR);
        if (__moqi_is_error(r)) {
            err = (int)-r;
            status = -1;
        }
    }

    sigaction(SIGINT, &old_int, (struct ksigaction *)0);
    sigaction(SIGQUIT, &old_quit, (struct ksigaction *)0);
    MSYS4(SYS_sigprocmask, SIG_SETMASK, &old_mask, 0, 8);
    if (err) errno = err;
    return status;
}
