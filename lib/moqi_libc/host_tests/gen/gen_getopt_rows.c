/* gen_getopt_rows.c — writes test_getopt_rows.inc from the host glibc.  gcc -O1 -o gen gen/gen_getopt_rows.c && ./gen > test_getopt_rows.inc */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <gnu/libc-version.h>
static const char *esc(const char *s, char *buf) { char *o = buf; *o++ = '"'; for (; *s; s++) { if (*s == '"' || *s == '\\') *o++ = '\\'; *o++ = *s; } *o++ = '"'; *o = 0; return buf; }
static int row_no;
static void scen(const char *spec, int posixly, int nargs, const char *const *args) {
    char *argv[16]; char store[16][32];
    argv[0] = "prog";
    for (int i = 0; i < nargs; i++) { strcpy(store[i], args[i]); argv[i + 1] = store[i]; }
    int argc = nargs + 1; argv[argc] = NULL;
    if (posixly) setenv("POSIXLY_CORRECT", "1", 1); else unsetenv("POSIXLY_CORRECT");
    optind = 0; opterr = 0; optopt = 0; optarg = NULL;
    char b1[96], b2[96];
    printf("SC(%s, %d, %d,", esc(spec, b1), posixly, nargs);
    for (int i = 0; i < nargs; i++) printf(" %s,", esc(args[i], b2));
    for (int i = nargs; i < 8; i++) printf(" \"\",");
    printf("\n   (");
    int o, n = 0;
    while ((o = getopt(argc, argv, spec)) != -1 && n < 12) {
        char ob[96];
        printf(" {%d, %s, %d, %d},", o, optarg ? esc(optarg, ob) : "(const char *)0", optind, optopt);
        n++;
    }
    printf(" {-1, (const char *)0, %d, 0}),\n   (", optind);
    for (int i = 0; i < argc; i++) printf(" %s,", esc(argv[i], b2));
    for (int i = argc; i < 9; i++) printf(" \"\",");
    printf("));\n");
    row_no++;
}
#define S(spec, posix, ...) do { const char *a[] = { __VA_ARGS__ }; scen(spec, posix, sizeof a / sizeof a[0], a); } while (0)
int main(void) {
    printf("/* Generated from glibc %s: spec, POSIXLY_CORRECT set, argument count, the 8 arguments after argv[0],\n * each getopt result {return, optarg, optind, optopt}, then argv afterwards (permuted). */\n", gnu_get_libc_version());
    S("ab:", 0, "-a", "-b", "v", "x"); S("ab:", 0, "x", "-a", "y", "-b", "v"); S("+ab:", 0, "x", "-a", "y", "-b", "v"); S("-ab:", 0, "x", "-a", "y", "-b", "v");
    S("ab:", 1, "x", "-a", "y"); S("ab:", 0, "-abv", "x"); S("ab:", 0, "-bval", "x"); S("ab:c::", 0, "-c", "-cX", "y"); S("ab:c::", 0, "-c", "X");
    S("ab:", 0, "-a", "-b"); S(":ab:", 0, "-a", "-b"); S("ab:", 0, "-z", "-a", "-q"); S(":ab:", 0, "-z", "-a"); S("ab:", 0, "-a", "--", "-b", "v", "x");
    S("ab:", 0, "-a", "-", "x"); S("ab:", 0, "-", "-a"); S("ab:", 0, "x", "y"); S("ab:", 0, "-b", "-a", "x"); S("ab:", 0, "-b", "--"); S("ab:", 0, "-b", "--", "x");
    S("ab:", 0, "x", "--", "-a", "y"); S("ab:", 0, "x", "y", "-a", "z", "-b", "v"); S("a", 0, "-a", "-a", "-a"); S("12", 0, "-1", "-2");
    S("ab", 0, "--abc", "x"); S("abc", 0, "--abc", "x"); S("", 0, "-a", "x"); S(":", 0, "-a"); S("+:", 0, "-:", "-+"); S("W;", 0, "-W", "foo"); S("ab:", 0, "-:", "x");
    S("a:b:c:", 0, "-a1", "-b", "2", "-c3"); S("a:b:c:", 0, "-a", "-b"); S("ab", 0, "-a", "--", "x", "-b"); S("ab:", 0, "-ab", "-ab");
    S("ab:", 0, "-b", "x", "-b", "y"); S("-a", 0, "x", "-a", "y", "--", "-a"); S("+a", 0, "-a", "x", "-a"); S("ab:", 0, "-a", "-a", "x", "-b", "-a");
    S("a", 0, "x"); S("a", 0, "-a"); S("a", 0, "-aa"); S("a", 0, "-ab"); S("ab:", 0, "-b"); S("ab:", 0, "-ba"); S(":b:", 0, "-b"); S(":b:", 0, "-ba");
    S("a", 1, "-a", "x", "-a"); S("a", 1, "x", "-a"); S("-a", 1, "x", "-a"); S("+a", 1, "x", "-a");
    S("ab:", 0, "---"); S("ab:", 0, "--"); S("ab:", 0, "-", "-");
    fprintf(stderr, "%d scenarios\n", row_no);
    return 0;
}
