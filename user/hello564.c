/* hello564: positional parameters beyond "sh -s" (POSIX, measured with bash --posix). A: "sh FILE a b" makes $0 the file and $1 $2
 * the arguments; B: "sh -c CMD n0 n1" makes $0 n0 and $1 n1; C: "shift" drops $1 and lowers $#; D: "shift 2"; E: "shift" past the
 * end is status 1 and changes nothing; F: "shift x" is an error that ends a non-interactive shell with 2; G: "set -- x y" replaces
 * the parameters and "set --" clears them; H: "set -e -- p q" takes options and then parameters (and -e is on: the false ends
 * the shell). */
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
    print(ok ? "hello564:   ok   " : "hello564:   FAIL ");
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
#define OUT "/tmp/h564_out"
#define SCRIPT "/tmp/h564_s"
static void writef(const char *path, const char *text) {
    int fd = (int)open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    write(fd, text, strlen(text));
    close(fd);
}
/* system(cmd) with standard error thrown away (the messages differ from bash); status into *st, OUT's text into out. */
static void run(const char *cmd, int *st, char *out, size_t cap) {
    unlink(OUT);
    int fd = (int)open("/dev/null", O_WRONLY, 0);
    int saved = dup(2);
    dup2(fd, 2);
    close(fd);
    *st = code(system(cmd));
    dup2(saved, 2);
    close(saved);
    slurp(OUT, out, cap);
}
int main(void) {
    print("hello564: sh FILE args, sh -c CMD args, shift, set --\n");
    char out[200];
    int st;

    writef(SCRIPT, "echo $0 $1 $2 $# >> " OUT "\n");
    run("sh " SCRIPT " a b", &st, out, sizeof out);
    snprintf(msg, sizeof msg, "A: sh FILE a b: status %d, wrote '%s' (0, '" SCRIPT " a b 2\\n')", st, out);
    check(st == 0 && strcmp(out, SCRIPT " a b 2\n") == 0, msg);

    run("sh -c 'echo $0 $1 $# >> " OUT "' n0 n1", &st, out, sizeof out);
    snprintf(msg, sizeof msg, "B: sh -c CMD n0 n1: status %d, wrote '%s' (0, 'n0 n1 1\\n')", st, out);
    check(st == 0 && strcmp(out, "n0 n1 1\n") == 0, msg);

    writef(SCRIPT, "shift\necho $1 $# >> " OUT "\n");
    run("sh " SCRIPT " a b c", &st, out, sizeof out);
    snprintf(msg, sizeof msg, "C: shift: status %d, wrote '%s' (0, 'b 2\\n')", st, out);
    check(st == 0 && strcmp(out, "b 2\n") == 0, msg);

    writef(SCRIPT, "shift 2\necho $? $1 $# >> " OUT "\n");
    run("sh " SCRIPT " a b c d", &st, out, sizeof out);
    snprintf(msg, sizeof msg, "D: shift 2: status %d, wrote '%s' (0, '0 c 2\\n')", st, out);
    check(st == 0 && strcmp(out, "0 c 2\n") == 0, msg);

    writef(SCRIPT, "shift 3\necho $? $1 $# >> " OUT "\n");
    run("sh " SCRIPT " a b", &st, out, sizeof out);
    snprintf(msg, sizeof msg, "E: shift past the end: status %d, wrote '%s' (0, '1 a 2\\n')", st, out);
    check(st == 0 && strcmp(out, "1 a 2\n") == 0, msg);

    writef(SCRIPT, "shift x\necho after >> " OUT "\n");
    run("sh " SCRIPT " a", &st, out, sizeof out);
    snprintf(msg, sizeof msg, "F: shift x: status %d, wrote '%s' (2, '')", st, out);
    check(st == 2 && out[0] == 0, msg);

    run("set -- x y; echo $1 $2 $# >> " OUT "; set --; echo $# >> " OUT, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "G: set -- x y, set --: status %d, wrote '%s' (0, 'x y 2\\n0\\n')", st, out);
    check(st == 0 && strcmp(out, "x y 2\n0\n") == 0, msg);

    run("set -e -- p q; echo $1 $# >> " OUT "; false; echo no >> " OUT, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "H: set -e -- p q: status %d, wrote '%s' (1, 'p 2\\n')", st, out);
    check(st == 1 && strcmp(out, "p 2\n") == 0, msg);

    unlink(OUT);
    unlink(SCRIPT);
    print(failures ? "hello564: FAIL\n" : "hello564: PASS\n");
    return failures ? 1 : 0;
}
