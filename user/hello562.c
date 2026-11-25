/* hello562: the shell's nounset ("set -u", "set +u", "sh -u"; POSIX, measured with bash --posix). Expanding a variable that is not
 * set is an error: a message naming it goes to standard error, nothing more of the command line runs, and a non-interactive shell
 * ends (status 127 for "sh -c", 1 for a script file). A: "set -u" then "$H562_UNSET" ends "sh -c" with 127 after the first echo;
 * B: in double quotes too; C: a variable set to the empty string is set; D: "$?" is always set; E: "$!" before any background job
 * is not set; F: "set +u" switches it off again (the variable is then empty); G: "sh -u -c"; H: "sh -u FILE" ends with 1. */
#ifdef HOST
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/fcntl.h"
#endif

static int failures;
static char msg[400];
static void check(int ok, const char *what) {
    print(ok ? "hello562:   ok   " : "hello562:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int code(int st) { return st == -1 || (st & 0x7f) ? -1 : (st >> 8) & 0xff; }
static void slurp(const char *path, char *out, size_t cap) {
    out[0] = 0;
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return;
    long n = (long)read(fd, out, cap - 1);
    close(fd);
    out[n > 0 ? n : 0] = 0;
}
#define OUT "/tmp/h562_out"
#define ERR "/tmp/h562_err"
/* system(cmd) with standard error sent to ERR; the status into *st, OUT's text into out and ERR's into err. */
static void run(const char *cmd, int *st, char *out, char *err, size_t cap) {
    unlink(OUT);
    unlink(ERR);
    int fd = (int)open(ERR, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    int saved = dup(2);
    dup2(fd, 2);
    close(fd);
    *st = code(system(cmd));
    dup2(saved, 2);
    close(saved);
    slurp(OUT, out, cap);
    slurp(ERR, err, cap);
}
int main(void) {
    print("hello562: set -u, set +u and sh -u\n");
    char out[200], err[200];
    int st;

    run("set -u; echo a >> " OUT "; echo $H562_UNSET >> " OUT "; echo b >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "A: an unset variable: status %d, wrote '%s', error '%s' (127, 'a\\n', naming H562_UNSET)", st, out, err);
    check(st == 127 && strcmp(out, "a\n") == 0 && strstr(err, "H562_UNSET") != 0, msg);

    run("set -u; echo \"$H562_UNSET\" >> " OUT "; echo b >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "B: in double quotes: status %d, wrote '%s' (127, '')", st, out);
    check(st == 127 && out[0] == 0 && strstr(err, "H562_UNSET") != 0, msg);

    run("export H562_EMPTY=; set -u; echo x$H562_EMPTY >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "C: set to the empty string: status %d, wrote '%s', error '%s' (0, 'x\\n', '')", st, out, err);
    check(st == 0 && strcmp(out, "x\n") == 0 && err[0] == 0, msg);

    run("set -u; echo $? >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "D: $?: status %d, wrote '%s' (0, '0\\n')", st, out);
    check(st == 0 && strcmp(out, "0\n") == 0, msg);

    run("set -u; echo $! >> " OUT "; echo b >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "E: $! before any background job: status %d, wrote '%s' (127, '')", st, out);
    check(st == 127 && out[0] == 0 && err[0] != 0, msg);

    run("set -u; set +u; echo x$H562_UNSET >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "F: set +u: status %d, wrote '%s' (0, 'x\\n')", st, out);
    check(st == 0 && strcmp(out, "x\n") == 0, msg);

    run("sh -u -c 'echo $H562_UNSET >> " OUT "; echo b >> " OUT "'", &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "G: sh -u -c: status %d, wrote '%s' (127, '')", st, out);
    check(st == 127 && out[0] == 0 && strstr(err, "H562_UNSET") != 0, msg);

    int fd = (int)open("/tmp/h562_script", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    const char *script = "echo a >> " OUT "\necho $H562_UNSET >> " OUT "\necho b >> " OUT "\n";
    long w = (long)write(fd, script, strlen(script));
    close(fd);
    run("sh -u /tmp/h562_script", &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "H: sh -u FILE: status %d, wrote '%s' (write %ld; 1, 'a\\n')", st, out, w);
    check(st == 1 && strcmp(out, "a\n") == 0 && strstr(err, "H562_UNSET") != 0, msg);

    unlink(OUT);
    unlink(ERR);
    unlink("/tmp/h562_script");
    print(failures ? "hello562: FAIL\n" : "hello562: PASS\n");
    return failures ? 1 : 0;
}
