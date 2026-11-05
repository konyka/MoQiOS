/* hello227: system() and the shell it starts ("sh -c") on the real kernel: the status of the command, a missing command,
 * pipelines, command lists (; && ||), quotes and backslashes, $? and $!, background jobs and wait, input and append
 * redirection, export and env, ls, cd and redirection failures, the signal state system() leaves behind, and system(NULL). */
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

    /* B3: quoting. Inside double or single quotes a separator, a '>' or a '|' is text, spaces are kept, and the quotes
     * themselves are not part of the word. */
    unlink("/tmp/h227_q");
    st = system("echo \"a ; b  c\" > /tmp/h227_q");
    check(exited(st, 0), "B: a quoted separator does not split the command");
    f = fopen("/tmp/h227_q", "r");
    char qb[32] = { 0 };
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(strcmp(qb, "a ; b  c\n") == 0, "B: the quoted text is written as it is, spaces kept and quotes dropped");
    st = system("echo 'x | y' > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "x | y\n") == 0, "B: single quotes protect a pipe character");
    unlink("/tmp/h227_q");
    st = system("echo \"unterminated");
    check(exited(st, 0), "B: an unterminated quote runs to the end of the line");

    /* B4: "$?" is the exit status of the command that ran before it in the line (0 before any command has run). It is replaced
     * when its list element is about to run, not when the line is read. */
    st = system("hello11 ; exit $?");
    check(exited(st, 42), "B: $? is the exit status of the previous command (42)");
    st = system("exit $?");
    check(exited(st, 0), "B: $? is 0 before any command has run");
    st = system("hello11 ; cd /tmp ; exit $?");
    check(exited(st, 0), "B: $? follows the latest command (a successful cd resets it to 0)");
    st = system("hello11 || exit $?");
    check(exited(st, 42), "B: $? works as the argument after '||'");
    st = system("hello11 && exit 1 ; exit $?");
    check(exited(st, 42), "B: a skipped command leaves $? as it was");
    unlink("/tmp/h227_q");
    st = system("hello11 ; echo \"s=$?\" > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "s=42\n") == 0, "B: $? inside double quotes is replaced in place");
    st = system("export H227V=5 ; exit $H227V");
    check(exited(st, 5), "B: a variable exported earlier in the same line is expanded for the next command");
    unlink("/tmp/h227_q");
    st = system("export H227W=a b ; echo \"$H227W\" > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "a b\n") == 0, "B: a quoted variable whose value has a space stays one word");
    unlink("/tmp/h227_q");
    st = system("nosuchprogram_zz ; exit $?");
    check(exited(st, 127), "B: $? after a missing program is 127");

    /* B5: a single quote keeps '$' literal; a backslash outside quotes (or before \\, \" or \$ inside double quotes) makes the next
     * character plain text. */
    unlink("/tmp/h227_q");
    st = system("hello11 ; echo '$?' > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "$?\n") == 0, "B: '$?' in single quotes is not expanded");
    unlink("/tmp/h227_q");
    st = system("export H227S=zz ; echo '$H227S' \"$H227S\" > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "$H227S zz\n") == 0, "B: a single-quoted variable stays text, a double-quoted one is expanded");
    unlink("/tmp/h227_q");
    st = system("echo a\\;b > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "a;b\n") == 0, "B: a backslash makes ';' plain text");
    unlink("/tmp/h227_q");
    st = system("echo a\\ b > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "a b\n") == 0, "B: a backslash makes a space part of the word");
    unlink("/tmp/h227_q");
    st = system("echo \\$HOME \"q\\\"q\" > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "$HOME q\"q\n") == 0, "B: \\$ is a literal dollar and \\\" inside double quotes is a quote character");
    unlink("/tmp/h227_q");
    st = system("echo 'a\\b' \"c\\d\" > /tmp/h227_q");
    f = fopen("/tmp/h227_q", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "a\\b c\\d\n") == 0, "B: a backslash stays as it is in single quotes and before an ordinary character in double quotes");
    unlink("/tmp/h227_q");

    /* B6: background jobs. "cmd &" starts the pipeline and goes on without waiting (its own status there is 0); "$!" is the
     * pid of the last one, "wait $!" waits for that job and gives its status, "wait" alone waits for all of them and gives 0,
     * and a foreground command's status is its own, never that of a background job that happened to end first. */
    st = system("hello11 & exit 3");
    check(exited(st, 3), "B: 'cmd & next' starts the job and goes on to the next command");
    st = system("hello11 &");
    check(exited(st, 0), "B: a trailing '&' ends the line with status 0");
    st = system("hello11 & exit $?");
    check(exited(st, 0), "B: $? right after a background start is 0");
    st = system("hello11 & wait $! ; exit $?");
    check(exited(st, 42), "B: 'wait $!' returns the background job's exit status (42)");
    st = system("hello11 & hello11 & wait ; exit $?");
    check(exited(st, 0), "B: a bare 'wait' waits for every job and returns 0");
    st = system("wait 99999 ; exit $?");
    check(exited(st, 127), "B: 'wait' for a pid that is not a child of the shell is 127");
    st = system("hello11 & hello11 ; hello11 ; wait $! ; exit $?");
    check(exited(st, 42), "B: a job that ended before 'wait' keeps its status");
    int fg_ok = 1;
    for (int i = 0; i < 8; i++) fg_ok &= exited(system("hello11 & sh -c \"exit 7\""), 7);
    check(fg_ok, "B: a foreground command's status is its own even when a background job ends first (8 runs)");
    st = system("hello11 & hello2 | hello11 ; exit $?");
    check(exited(st, 42), "B: a pipeline after a background job reports its own last command");

    /* B7: input redirection and append. "cmd < file" feeds the file to the command's standard input, ">>" appends instead of
     * truncating, and both work with built-ins, in pipelines and without spaces around the operator. hello230 copies its
     * standard input to its standard output (or, with "count", exits with the byte count). */
    unlink("/tmp/h227_in");
    unlink("/tmp/h227_out");
    f = fopen("/tmp/h227_in", "w");
    if (f) { fputs("abc\n", f); fclose(f); }
    st = system("hello230 < /tmp/h227_in > /tmp/h227_out");
    f = fopen("/tmp/h227_out", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "abc\n") == 0, "B: 'cmd < file > file2' copies the input file to the output file");
    st = system("hello230 count < /tmp/h227_in");
    check(exited(st, 4), "B: the command sees exactly the file's 4 bytes on standard input (count = 4)");
    st = system("hello230 count</tmp/h227_in");
    check(exited(st, 4), "B: no spaces are needed around '<'");
    st = system("hello230 count < /tmp/h227_nonexistent");
    check(!exited(st, 4) && !exited(st, 0), "B: a missing input file fails the command instead of reading the terminal");
    unlink("/tmp/h227_out");
    st = system("echo one > /tmp/h227_out ; echo two >> /tmp/h227_out");
    f = fopen("/tmp/h227_out", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "one\ntwo\n") == 0, "B: '>>' appends to a file (built-in echo)");
    st = system("hello230 < /tmp/h227_in >> /tmp/h227_out");
    f = fopen("/tmp/h227_out", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "one\ntwo\nabc\n") == 0, "B: '>>' appends the output of an external command");
    st = system("echo x > /tmp/h227_out ; echo y > /tmp/h227_out");
    f = fopen("/tmp/h227_out", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "y\n") == 0, "B: a single '>' still truncates");
    unlink("/tmp/h227_out2");
    st = system("hello230 < /tmp/h227_in | hello230 > /tmp/h227_out2");
    f = fopen("/tmp/h227_out2", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "abc\n") == 0, "B: '<' on the first command of a pipeline");
    st = system("echo \"a < b\" > /tmp/h227_out");
    f = fopen("/tmp/h227_out", "r");
    memset(qb, 0, sizeof qb);
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "a < b\n") == 0, "B: a quoted '<' is text");
    unlink("/tmp/h227_in");
    unlink("/tmp/h227_out");
    unlink("/tmp/h227_out2");

    /* B8: the environment. "export" puts a variable into the shell's environment and every program the shell starts inherits
     * it; "env" prints the environment. hello231 exits 0 when H231V equals its argument. */
    st = system("export H231V=child-value ; hello231 child-value");
    check(exited(st, 0), "B: a program started after 'export' sees the variable");
    st = system("hello231 child-value");
    check(!exited(st, 0), "B: and without the export it does not (a fresh shell has no H231V)");
    st = system("export H231V=\"two words\" ; hello231 \"two words\"");
    check(exited(st, 0), "B: a quoted value with a space reaches the program whole");
    st = system("export H231V=a ; export H231V=b ; hello231 b");
    check(exited(st, 0), "B: a second 'export' of the same name replaces the value");
    st = system("export H231V=deep ; sh -c \"hello231 deep\"");
    check(exited(st, 0), "B: the variable passes through a nested shell to its child");
    st = system("export H231V=bg ; hello231 bg & wait $! ; exit $?");
    check(exited(st, 0), "B: a background program inherits the variable too");
    unlink("/tmp/h227_env");
    st = system("export H231V=listed ; env > /tmp/h227_env");
    f = fopen("/tmp/h227_env", "r");
    char eb[512] = { 0 };
    if (f) { fread(eb, 1, 511, f); fclose(f); }
    check(exited(st, 0) && strstr(eb, "H231V=listed\n") != (char *)0, "B: 'env' prints the exported variable as NAME=value");
    unlink("/tmp/h227_env");

    /* B9: ls. "ls" lists the working directory, "ls DIR" lists DIR, one name per line, and a directory that cannot be opened is a
     * message and status 1. A fresh directory is used so that the expected names are exactly known. */
    unlink("/tmp/h227_d/a.txt");
    unlink("/tmp/h227_d/b.txt");
    rmdir("/tmp/h227_d");
    mkdir("/tmp/h227_d", 0755);
    f = fopen("/tmp/h227_d/a.txt", "w");
    if (f) { fputs("A", f); fclose(f); }
    f = fopen("/tmp/h227_d/b.txt", "w");
    if (f) { fputs("B", f); fclose(f); }
    unlink("/tmp/h227_ls");
    st = system("ls /tmp/h227_d > /tmp/h227_ls");
    char lb[256] = { 0 };
    f = fopen("/tmp/h227_ls", "r");
    if (f) { fread(lb, 1, 255, f); fclose(f); }
    check(exited(st, 0) && strstr(lb, "a.txt\n") && strstr(lb, "b.txt\n") && !strstr(lb, "hello"), "B: 'ls DIR' lists exactly the entries of DIR, one per line");
    check(!strstr(lb, ".\n") && !strstr(lb, "..\n"), "B: and does not list '.' or '..'");
    memset(lb, 0, sizeof lb);
    st = system("cd /tmp/h227_d ; ls > /tmp/h227_ls");
    f = fopen("/tmp/h227_ls", "r");
    if (f) { fread(lb, 1, 255, f); fclose(f); }
    check(exited(st, 0) && strstr(lb, "a.txt\n") && strstr(lb, "b.txt\n") && !strstr(lb, "hello"), "B: 'ls' without an argument lists the working directory");
    st = system("ls /tmp/h227_no_such_dir");
    check(exited(st, 1), "B: 'ls' of a directory that does not exist is status 1");
    st = system("ls /tmp/h227_d/a.txt > /tmp/h227_ls");
    memset(lb, 0, sizeof lb);
    f = fopen("/tmp/h227_ls", "r");
    if (f) { fread(lb, 1, 255, f); fclose(f); }
    check(exited(st, 0) && strcmp(lb, "/tmp/h227_d/a.txt\n") == 0, "B: 'ls FILE' prints the file's name");
    unlink("/tmp/h227_d/a.txt");
    unlink("/tmp/h227_d/b.txt");
    rmdir("/tmp/h227_d");
    unlink("/tmp/h227_ls");

    /* B10: cd reports failure. A directory that does not exist (or a file) is status 1 and the working directory stays where it
     * was, so "cd X && cmd" does not run cmd and "cd X || cmd" does. "cd -" and "cd ~" are not supported and are plain failures. */
    st = system("cd /tmp/h227_no_such_dir");
    check(exited(st, 1), "B: 'cd' to a directory that does not exist is status 1");
    st = system("cd /tmp/h227_no_such_dir && exit 7");
    check(exited(st, 1), "B: and '&&' after a failed cd does not run the next command");
    st = system("cd /tmp/h227_no_such_dir || exit 7");
    check(exited(st, 7), "B: '||' after a failed cd runs the next command");
    unlink("/tmp/h227_cd");
    st = system("cd /tmp ; cd /tmp/h227_no_such_dir ; pwd > /tmp/h227_cd");
    memset(qb, 0, sizeof qb);
    f = fopen("/tmp/h227_cd", "r");
    if (f) { fread(qb, 1, 31, f); fclose(f); }
    check(exited(st, 0) && strcmp(qb, "/tmp\n") == 0, "B: a failed cd leaves the working directory unchanged");
    unlink("/tmp/h227_cd");
    f = fopen("/tmp/h227_cdfile", "w");
    if (f) { fputs("x", f); fclose(f); }
    st = system("cd /tmp/h227_cdfile");
    check(exited(st, 1), "B: 'cd' to a regular file is status 1");
    unlink("/tmp/h227_cdfile");
    st = system("cd /tmp && exit 5");
    check(exited(st, 5), "B: a successful cd is status 0 (the next '&&' command runs)");
    st = system("cd");
    check(exited(st, 0), "B: 'cd' with no argument goes to / and is status 0");

    /* B11: a redirection target that cannot be opened fails the command with status 1 (not a signal-looking status), for built-ins
     * and external programs alike, and the command does not run. */
    st = system("echo hi > /tmp/h227_no_such_dir/out");
    check(exited(st, 1), "B: a built-in whose '>' target cannot be opened is status 1");
    st = system("hello11 > /tmp/h227_no_such_dir/out");
    check(exited(st, 1), "B: an external program whose '>' target cannot be opened is status 1 (it does not run, so not 42)");
    st = system("echo hi > /tmp/h227_no_such_dir/out || exit 6");
    check(exited(st, 6), "B: and '||' after it runs the next command");
    st = system("echo hi > /tmp/h227_no_such_dir/out && exit 6");
    check(exited(st, 1), "B: '&&' after it does not");

    /* B12: export failures and forms. A name without "=" is not an assignment: "export NAME" marks an existing variable (here: it
     * succeeds and leaves the value alone) and is status 0 whether or not NAME is set; an empty name ("=x") or a name with
     * characters a variable cannot have is status 1; running out of room in the environment table is status 1. */
    st = system("export =novalue");
    check(exited(st, 1), "B: 'export =x' (empty name) is status 1");
    st = system("export =novalue || exit 6");
    check(exited(st, 6), "B: and '||' after it runs the next command");
    st = system("export H231V=kept ; export H231V ; hello231 kept");
    check(exited(st, 0), "B: 'export NAME' without a value keeps the value and passes it on");
    st = system("export H231NOTSET");
    check(exited(st, 0), "B: 'export NAME' for a name that is not set is status 0");
    st = system("export H231V=ok ; export H231V=ok2 && hello231 ok2");
    check(exited(st, 0), "B: a successful export is status 0 (the '&&' command runs)");
    st = system("export A.B=1");
    check(exited(st, 1), "B: a name containing '.' is status 1");
    st = system("export 1ABC=1");
    check(exited(st, 1), "B: a name that starts with a digit is status 1");

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
