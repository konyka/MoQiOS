/* hello563: the shell's -s option (POSIX, measured with bash --posix): read commands from standard input, remaining arguments are
 * positional parameters ($1..$9, $#, $@, $0). A: "echo $1" with one argument prints that argument; B: "$#" is the count (not
 * including $0); C: "$@" joins them; D: "$0" is "sh" (or "bash" on the host); E: "-es" (combined with -e) stops at a failure;
 * F: "-- arg" (double dash ends options, rest is positional); G: "echo $3" with only 2 args is empty; H: without -s, the
 * first non-option argument is a file, not a positional parameter (existing behaviour, regression guard).
 * Commands are written to a temp file and fed through "sh -s arg < file", because "echo cmd | sh -s arg" would need echo to
 * be an external program (the shell's echo built-in only works for single commands, not in a pipeline's fork+exec). */
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
    print(ok ? "hello563:   ok   " : "hello563:   FAIL ");
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
#define OUT "/tmp/h563_out"
#define CMD "/tmp/h563_cmd"
static void writef(const char *path, const char *text) {
    int fd = (int)open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    write(fd, text, strlen(text));
    close(fd);
}
static void run(const char *cmd, int *st, char *out, size_t cap) {
    unlink(OUT);
    *st = code(system(cmd));
    slurp(OUT, out, cap);
}
int main(void) {
    print("hello563: sh -s (positional parameters)\n");
    char out[200];
    int st;

    writef(CMD, "echo $1 >> " OUT "\n");
    run("sh -s alpha < " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "A: $1: status %d, wrote '%s' (0, 'alpha\\n')", st, out);
    check(st == 0 && strcmp(out, "alpha\n") == 0, msg);

    writef(CMD, "echo $# >> " OUT "\n");
    run("sh -s a b c < " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "B: $#: status %d, wrote '%s' (0, '3\\n')", st, out);
    check(st == 0 && strcmp(out, "3\n") == 0, msg);

    writef(CMD, "echo \"$@\" >> " OUT "\n");
    run("sh -s x y z < " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "C: $@: status %d, wrote '%s' (0, 'x y z\\n')", st, out);
    check(st == 0 && strcmp(out, "x y z\n") == 0, msg);

#ifdef HOST
    writef(CMD, "echo $0 >> " OUT "\n");
    run("sh -s < " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "D: $0: status %d, wrote '%s' (0, 'bash\\n' or 'sh\\n')", st, out);
    check(st == 0 && (strcmp(out, "bash\n") == 0 || strcmp(out, "sh\n") == 0), msg);
#else
    writef(CMD, "echo $0 >> " OUT "\n");
    run("sh -s < " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "D: $0: status %d, wrote '%s' (0, 'sh\\n')", st, out);
    check(st == 0 && strcmp(out, "sh\n") == 0, msg);
#endif

    writef(CMD, "false\necho x >> " OUT "\n");
    run("sh -es < " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "E: -es: status %d, wrote '%s' (1, '')", st, out);
    check(st == 1 && out[0] == 0, msg);

    writef(CMD, "echo $1 >> " OUT "\n");
    run("sh -s -- A < " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "F: -- arg: status %d, wrote '%s' (0, 'A\\n')", st, out);
    check(st == 0 && strcmp(out, "A\n") == 0, msg);

    writef(CMD, "echo x$3 >> " OUT "\n");
    run("sh -s a b < " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "G: $3 with 2 args: status %d, wrote '%s' (0, 'x\\n')", st, out);
    check(st == 0 && strcmp(out, "x\n") == 0, msg);

    writef(CMD, "echo file >> " OUT "\n");
    run("sh " CMD, &st, out, sizeof out);
    snprintf(msg, sizeof msg, "H: sh FILE: status %d, wrote '%s' (0, 'file\\n')", st, out);
    check(st == 0 && strcmp(out, "file\n") == 0, msg);

    unlink(OUT);
    unlink(CMD);
    print(failures ? "hello563: FAIL\n" : "hello563: PASS\n");
    return failures ? 1 : 0;
}
