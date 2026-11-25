/* hello561: the shell's xtrace ("set -x", "set +x", "sh -x"; POSIX, measured with bash --posix). Before a command runs, the shell
 * writes "+ " and its words after expansion to standard error, one line per command of a pipeline, redirections left out, a word
 * that holds anything but letters, digits and "_./,:=@%+-" in single quotes. A: "set -x" traces a built-in; B: the words are shown
 * after "$V" is expanded; C: quoting of a word with blanks, a plain "x=y" and a single quote; D: "set +x" is traced
 * and switches it off; E: "sh -x -c"; F: "sh -xe -c" traces the failing command and stops; G: "!" is not shown and only the
 * commands of an && / || list that run are traced; H: each command of a pipeline has its own line. */
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
    print(ok ? "hello561:   ok   " : "hello561:   FAIL ");
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
#define OUT "/tmp/h561_out"
#define ERR "/tmp/h561_err"
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
    print("hello561: set -x, set +x and sh -x\n");
    char out[160], err[160];
    int st;

    run("set -x; echo hi >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "A: set -x; echo hi: traced '%s', wrote '%s' ('+ echo hi\\n', 'hi\\n')", err, out);
    check(strcmp(err, "+ echo hi\n") == 0 && strcmp(out, "hi\n") == 0, msg);

    run("export V=7; set -x; echo $V >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "B: expanded words: traced '%s' ('+ echo 7\\n')", err);
    check(strcmp(err, "+ echo 7\n") == 0, msg);

    run("set -x; echo \"a  b\" x=y \"it's\" >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "C: quoting: traced '%s' (\"+ echo 'a  b' x=y 'it'\\''s'\\n\")", err);
    check(strcmp(err, "+ echo 'a  b' x=y 'it'\\''s'\n") == 0, msg);

    run("set -x; set +x; echo off >> " OUT, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "D: set +x: traced '%s', wrote '%s' ('+ set +x\\n', 'off\\n')", err, out);
    check(strcmp(err, "+ set +x\n") == 0 && strcmp(out, "off\n") == 0, msg);

    run("sh -x -c \"echo k >> " OUT "\"", &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "E: sh -x -c: traced '%s', wrote '%s' ('+ echo k\\n', 'k\\n')", err, out);
    check(strcmp(err, "+ echo k\n") == 0 && strcmp(out, "k\n") == 0, msg);

    run("sh -xe -c \"false; echo n >> " OUT "\"", &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "F: sh -xe -c: status %d, traced '%s', wrote '%s' (1, '+ false\\n', '')", st, err, out);
    check(st == 1 && strcmp(err, "+ false\n") == 0 && out[0] == 0, msg);

    run("set -x; ! false; true && false || true; false && echo no", &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "G: ! and lists: traced '%s' ('+ false\\n+ true\\n+ false\\n+ true\\n+ false\\n')", err);
    check(strcmp(err, "+ false\n+ true\n+ false\n+ true\n+ false\n") == 0, msg);

    /* bash traces each command of a pipeline from its own process, so the order of the two lines is not fixed there. The second
     * command is hello11 (it ends with status 42 and reads nothing); on the host it is "sh -c 'exit 42'". */
#ifdef HOST
#define SECOND "sh -c 'exit 42'"
#define SECOND_TRACE "+ sh -c 'exit 42'\n"
#else
#define SECOND "hello11"
#define SECOND_TRACE "+ hello11\n"
#endif
    run("set -x; echo q | " SECOND, &st, out, err, sizeof out);
    snprintf(msg, sizeof msg, "H: pipeline: status %d, traced '%s' (42, '+ echo q\\n' and '%s')", st, err, SECOND_TRACE);
    check(st == 42 && strlen(err) == strlen("+ echo q\n" SECOND_TRACE) && strstr(err, "+ echo q\n") && strstr(err, SECOND_TRACE), msg);

    unlink(OUT);
    unlink(ERR);
    print(failures ? "hello561: FAIL\n" : "hello561: PASS\n");
    return failures ? 1 : 0;
}
