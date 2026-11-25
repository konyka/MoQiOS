/* hello559: the shell's -e option (POSIX set -e, measured with bash --posix): a command that fails ends the shell with its status,
 * except a command whose status an && or || list tests. A: "sh -e FILE" stops at the first failing line and ends with 1; B: "a || b"
 * and "a && b" in the file do not stop it, a later plain failure does; C: "sh -e -c" stops inside the command line; D: "sh -ec" is
 * the same as "-e -c"; E: the failing command's own status (exit 3 in a subshell is not there, so a program's exit code: hello11's
 * 42) is the shell's; F: commands read from standard input ("sh -e < FILE") stop the same way; G: without -e the whole file runs.
 * Each case prints what it saw; the expected value is in parentheses. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/fcntl.h"

static int failures;
static char msg[300];
static void check(int ok, const char *what) {
    print(ok ? "hello559:   ok   " : "hello559:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}
static int code(int st) { return st == -1 || (st & 0x7f) ? -1 : (st >> 8) & 0xff; }
static int put(const char *path, const char *text) {
    int fd = (int)open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
/* The file's text, up to 127 bytes, into `out` ("" when it is missing). */
static void slurp(const char *path, char *out, size_t cap) {
    out[0] = 0;
    int fd = (int)open(path, O_RDONLY, 0);
    if (fd < 0) return;
    long n = (long)read(fd, out, cap - 1);
    close(fd);
    out[n > 0 ? n : 0] = 0;
}
#define OUT "/tmp/h559_out"
int main(void) {
    print("hello559: sh -e\n");
    char got[128];

    unlink(OUT);
    int w1 = put("/tmp/h559_a", "echo one >> " OUT "\nfalse\necho two >> " OUT "\n");
    int a = code(system("sh -e /tmp/h559_a"));
    slurp(OUT, got, sizeof got);
    snprintf(msg, sizeof msg, "A: sh -e FILE: status %d, wrote '%s' (write %d; 1, 'one\\n')", a, got, w1);
    check(w1 == 0 && a == 1 && strcmp(got, "one\n") == 0, msg);

    unlink(OUT);
    int w2 = put("/tmp/h559_b", "false || echo alt >> " OUT "\nfalse && echo no >> " OUT "\necho three >> " OUT "\nfalse\necho four >> " OUT "\n");
    int b = code(system("sh -e /tmp/h559_b"));
    slurp(OUT, got, sizeof got);
    snprintf(msg, sizeof msg, "B: || and && lists: status %d, wrote '%s' (write %d; 1, 'alt\\nthree\\n')", b, got, w2);
    check(w2 == 0 && b == 1 && strcmp(got, "alt\nthree\n") == 0, msg);

    unlink(OUT);
    int c = code(system("sh -e -c \"echo a >> " OUT "; false; echo b >> " OUT "\""));
    slurp(OUT, got, sizeof got);
    snprintf(msg, sizeof msg, "C: sh -e -c: status %d, wrote '%s' (1, 'a\\n')", c, got);
    check(c == 1 && strcmp(got, "a\n") == 0, msg);

    unlink(OUT);
    int d = code(system("sh -ec \"echo a >> " OUT "; false; echo b >> " OUT "\""));
    slurp(OUT, got, sizeof got);
    snprintf(msg, sizeof msg, "D: sh -ec: status %d, wrote '%s' (1, 'a\\n')", d, got);
    check(d == 1 && strcmp(got, "a\n") == 0, msg);

    unlink(OUT);
    int w5 = put("/tmp/h559_e", "echo a >> " OUT "\nhello11\necho b >> " OUT "\n");
    int e = code(system("sh -e /tmp/h559_e"));
    slurp(OUT, got, sizeof got);
    snprintf(msg, sizeof msg, "E: a program's exit code: status %d, wrote '%s' (write %d; 42, 'a\\n')", e, got, w5);
    check(w5 == 0 && e == 42 && strcmp(got, "a\n") == 0, msg);

    unlink(OUT);
    int f = code(system("sh -e < /tmp/h559_a"));
    slurp(OUT, got, sizeof got);
    snprintf(msg, sizeof msg, "F: sh -e < FILE: status %d, wrote '%s' (1, 'one\\n')", f, got);
    check(f == 1 && strcmp(got, "one\n") == 0, msg);

    unlink(OUT);
    int g = code(system("sh /tmp/h559_a"));
    slurp(OUT, got, sizeof got);
    snprintf(msg, sizeof msg, "G: without -e: status %d, wrote '%s' (0, 'one\\ntwo\\n')", g, got);
    check(g == 0 && strcmp(got, "one\ntwo\n") == 0, msg);

    unlink(OUT);
    unlink("/tmp/h559_a");
    unlink("/tmp/h559_b");
    unlink("/tmp/h559_e");
    print(failures ? "hello559: FAIL\n" : "hello559: PASS\n");
    return failures ? 1 : 0;
}
