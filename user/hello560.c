/* hello560: the shell's "set -e" / "set +e" and "! command" (POSIX, measured with bash --posix). A: "set -e" switches errexit on in
 * the middle of a command line: what follows a failure does not run, status 1; B: "set +e" switches it off again; C: "! true" is
 * status 1 and "! false" status 0 (seen through $?); D: under -e a negated command never ends the shell, so "! true; echo after"
 * runs the echo, status 0; E: "!true" without a blank is a command named "!true" (127); F: "set -q" is an unknown option, status
 * 2; G: "set -e; false || true; echo ok" runs the echo. Each case prints what it saw; the expected value is in parentheses. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/fcntl.h"

static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello560:   ok   " : "hello560:   FAIL ");
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
#define OUT "/tmp/h560_out"
/* system(cmd) with OUT cleared first; the status into *st and OUT's text into got. */
static void run(const char *cmd, int *st, char *got, size_t cap) {
    unlink(OUT);
    *st = code(system(cmd));
    slurp(OUT, got, cap);
}
int main(void) {
    print("hello560: set -e, set +e and ! in the shell\n");
    char got[128];
    int st;

    run("echo a >> " OUT "; set -e; false; echo b >> " OUT, &st, got, sizeof got);
    snprintf(msg, sizeof msg, "A: set -e mid-line: status %d, wrote '%s' (1, 'a\\n')", st, got);
    check(st == 1 && strcmp(got, "a\n") == 0, msg);

    run("set -e; set +e; false; echo b >> " OUT, &st, got, sizeof got);
    snprintf(msg, sizeof msg, "B: set +e: status %d, wrote '%s' (0, 'b\\n')", st, got);
    check(st == 0 && strcmp(got, "b\n") == 0, msg);

    run("! true; echo $? >> " OUT "; ! false; echo $? >> " OUT, &st, got, sizeof got);
    snprintf(msg, sizeof msg, "C: ! true then ! false: wrote '%s' ('1\\n0\\n')", got);
    check(strcmp(got, "1\n0\n") == 0, msg);

    run("set -e; ! true; echo after >> " OUT, &st, got, sizeof got);
    snprintf(msg, sizeof msg, "D: a negated command under -e: status %d, wrote '%s' (0, 'after\\n')", st, got);
    check(st == 0 && strcmp(got, "after\n") == 0, msg);

    run("!true; echo $? >> " OUT, &st, got, sizeof got);
    snprintf(msg, sizeof msg, "E: !true without a blank: wrote '%s' ('127\\n')", got);
    check(strcmp(got, "127\n") == 0, msg);

    run("set -q; echo $? >> " OUT, &st, got, sizeof got);
    snprintf(msg, sizeof msg, "F: set -q: wrote '%s' ('2\\n')", got);
    check(strcmp(got, "2\n") == 0, msg);

    run("set -e; false || true; echo ok >> " OUT, &st, got, sizeof got);
    snprintf(msg, sizeof msg, "G: set -e; false || true: status %d, wrote '%s' (0, 'ok\\n')", st, got);
    check(st == 0 && strcmp(got, "ok\n") == 0, msg);

    unlink(OUT);
    print(failures ? "hello560: FAIL\n" : "hello560: PASS\n");
    return failures ? 1 : 0;
}
