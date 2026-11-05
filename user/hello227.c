/* hello227: system() on the real kernel: the status of the command, a missing command, a pipeline and a redirection through
 * "sh -c", the signal state left behind, and system(NULL). */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/signal.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello227:   ok   " : "hello227:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int exited(int st, int code) { return st != -1 && (st & 0x7f) == 0 && ((st >> 8) & 0xff) == code; }

static void on_int(int s) { (void)s; }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello227: system()\n");

    check(system((const char *)0) != 0, "A: system(NULL) says a shell exists");

    int st = system("exit 3");
    check(exited(st, 3), "A: system(\"exit 3\") returns a status whose exit code is 3");
    st = system("exit");
    check(exited(st, 0), "A: \"exit\" without a number is status 0");
    st = system("hello11");
    check(exited(st, 42), "A: a program is run and its exit code (42) comes back");
    st = system("nosuchprogram_zz");
    check(exited(st, 127), "A: a missing program is exit code 127");

    unlink("/tmp/h227_out");
    st = system("echo hello > /tmp/h227_out");
    check(exited(st, 0), "B: a redirection runs");
    FILE *f = fopen("/tmp/h227_out", "r");
    char buf[32] = { 0 };
    if (f) { fread(buf, 1, 31, f); fclose(f); }
    check(strcmp(buf, "hello\n") == 0, "B: and wrote exactly \"hello\\n\" to the file (a built-in honours the redirection)");
    /* A pipeline: both ends are started, and the status is the last command's (hello11 exits 42; there is no cat in the image). */
    st = system("hello2 | hello11");
    check(exited(st, 42), "B: a two-command pipeline runs and reports the last command's status");
    unlink("/tmp/h227_out");

    /* B2: command lists. ';' runs both, '&&' runs the second only after success, '||' only after failure; the status is the last
     * command that ran. hello11 exits 42 (a failure), "cd /tmp" is a silent success, and "exit N" ends the shell with N at that
     * point, as in any shell. */
    st = system("hello11 ; exit 7");
    check(exited(st, 7), "B: 'a ; b' runs both (the second ends the shell with 7)");
    st = system("cd /tmp && exit 8");
    check(exited(st, 8), "B: '&&' runs the second command after a success");
    st = system("hello11 && exit 9");
    check(exited(st, 42), "B: '&&' skips the second command after a failure (42 stays)");
    st = system("hello11 || exit 6");
    check(exited(st, 6), "B: '||' runs the second command after a failure");
    st = system("cd /tmp || exit 6");
    check(exited(st, 0), "B: '||' skips the second command after a success");
    st = system("hello11 ; cd /tmp && exit 4");
    check(exited(st, 4), "B: a longer list is evaluated left to right");
    st = system("hello11 || cd /tmp && exit 3");
    check(exited(st, 3), "B: '||' then '&&': the failure runs the cd, which succeeds, so the exit runs");
    st = system("hello2 | hello11 ; exit 3");
    check(exited(st, 3), "B: a pipeline is one element of a list");
    st = system("exit 2 ; exit 9");
    check(exited(st, 2), "B: an exit ends the shell, so nothing after it runs");

    /* C: the caller's signal state is exactly what it was */
    struct ksigaction a = { on_int, 0, 0, 0 };
    sigaction(SIGINT, &a, (struct ksigaction *)0);
    sigset_t before, after;
    sigprocmask(SIG_BLOCK, (const sigset_t *)0, &before);
    system("exit 0");
    struct ksigaction cur;
    sigaction(SIGINT, (const struct ksigaction *)0, &cur);
    sigprocmask(SIG_BLOCK, (const sigset_t *)0, &after);
    check(cur.handler == on_int, "C: the SIGINT handler is back after system()");
    check(sigismember(&after, SIGCHLD) == sigismember(&before, SIGCHLD) && after.sig[0] == before.sig[0], "C: and the signal mask is unchanged (SIGCHLD is not left blocked)");

    /* D: system() can be called again and again */
    int ok = 1;
    for (int i = 0; i < 8; i++) ok &= exited(system("exit 5"), 5);
    check(ok, "D: eight calls in a row each return their own status");

    print(failures == 0 ? "hello227: PASS\n" : "hello227: FAIL\n");
    return failures;
}
