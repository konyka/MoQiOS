/* gen_getopt_long_rows.c — writes test_getopt_long_rows.inc from the host glibc.
 *   gcc -O1 -o gen gen/gen_getopt_long_rows.c && ./gen > test_getopt_long_rows.inc
 * One row per scenario: option string, long_only, argument count, the 8 arguments after argv[0]; the getopt_long results
 * {return, optarg, optind, optopt, longindex (-77 untouched), flag variable}; the argv afterwards; the standard error text. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <getopt.h>
#include <gnu/libc-version.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "getopt_long_table.inc"

static const char *esc(const char *s, char *buf) {
    char *o = buf;
    *o++ = '"';
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') *o++ = '\\';
        if (*s == '\n') { *o++ = '\\'; *o++ = 'n'; continue; }
        *o++ = *s;
    }
    *o++ = '"';
    *o = 0;
    return buf;
}
static void scen(const char *spec, int only, int nargs, const char *const *args) {
    char *argv[16]; char store[16][40];
    argv[0] = "prog";
    for (int i = 0; i < nargs; i++) { strcpy(store[i], args[i]); argv[i + 1] = store[i]; }
    int argc = nargs + 1; argv[argc] = NULL;
    unsetenv("POSIXLY_CORRECT");
    optind = 0; opterr = 1; optopt = 0; optarg = NULL; flagv = 0;
    char b1[96], b2[256];
    printf("SL(%s, %d, %d,", esc(spec, b1), only, nargs);
    for (int i = 0; i < nargs; i++) printf(" %s,", esc(args[i], b2));
    for (int i = nargs; i < 8; i++) printf(" \"\",");
    fflush(stdout);
    char tmpl[] = "/tmp/gl_err_XXXXXX";
    int tfd = mkstemp(tmpl);
    int saved = dup(2);
    dup2(tfd, 2);
    printf("\n   (");
    int o, n = 0, idx;
    for (;;) {
        idx = -77;
        o = only ? getopt_long_only(argc, argv, spec, long_table, &idx) : getopt_long(argc, argv, spec, long_table, &idx);
        if (o == -1 || n >= 12) break;
        char ob[96];
        printf(" {%d, %s, %d, %d, %d, %d},", o, optarg ? esc(optarg, ob) : "(const char *)0", optind, optopt, idx, flagv);
        n++;
    }
    printf(" {-1, (const char *)0, %d, 0, 0, 0}),\n   (", optind);
    for (int i = 0; i < argc; i++) printf(" %s,", esc(argv[i], b2));
    for (int i = argc; i < 9; i++) printf(" \"\",");
    fflush(stdout);
    dup2(saved, 2); close(saved);
    char err[2048]; lseek(tfd, 0, SEEK_SET);
    ssize_t r = read(tfd, err, sizeof err - 1); if (r < 0) r = 0; err[r] = 0;
    close(tfd); unlink(tmpl);
    char eb[2300];
    printf("),\n   %s);\n", esc(err, eb));
}
#define S(spec, only, ...) do { const char *a[] = { __VA_ARGS__ }; scen(spec, only, sizeof a / sizeof a[0], a); } while (0)
int main(void) {
    printf("/* Generated from glibc %s by gen/gen_getopt_long_rows.c (option table: getopt_long_table.inc). */\n", gnu_get_libc_version());
    S("vo:", 0, "--verbose", "x"); S("vo:", 0, "--output=f", "--output", "g", "x"); S("vo:", 0, "--out=f"); S("vo:", 0, "--ver");
    S("vo:", 0, "--verb"); S("vo:", 0, "--opt=1", "--opt", "2"); S("vo:", 0, "--opt"); S("vo:", 0, "--flag", "--flag");
    S("vo:", 0, "--verbose=1"); S("vo:", 0, "--output"); S("vo:", 0, "--nosuch"); S("vo:", 0, "--=x"); S("vo:", 0, "--", "--verbose");
    S("vo:", 0, "x", "--verbose", "y"); S("+vo:", 0, "x", "--verbose"); S("-vo:", 0, "x", "--verbose"); S("vo:", 0, "--verify");
    S("vo:", 0, "--version"); S("vo:", 0, "--versi"); S(":vo:", 0, "--output"); S(":vo:", 0, "--nosuch");
    S("vo:", 0, "-v", "--x=a", "--x", "b", "-oq"); S("vo:", 0, "--out"); S("vo:", 0, "--o"); S("vo:", 0, "--p=9");
    S("W;", 0, "-W", "verbose"); S("W;", 0, "-W", "nosuch"); S("W;n", 0, "-W", "nosuch"); S("W;", 0, "-Wverbose"); S("W;", 0, "-W"); S("vo:", 0, "---x");
    S("vo:", 0, "--x="); S("vo:", 0, "--opt=");
    S("a", 0, "--ab"); S("a", 0, "--abc"); S("a", 0, "--flagged"); S("a", 0, "--flagg"); S("a", 0, "--no"); S("a", 0, "-abc");
    S("az", 1, "-abc", "-zzz", "-z", "-a", "-ab"); S("az", 1, "-abc=1", "-nof=3", "-nof", "q"); S("a", 1, "-x"); S("a", 1, "-flagg");
    S("az", 1, "-zz"); S("a", 1, "--abc", "-abe"); S("vo:", 1, "-verbose", "-v", "-output=f");
    S("a", 0, "--qq"); S("a", 0, "--qq1", "--qq2");
    S("ab:", 0, "-a", "--verbose", "-b", "v", "x"); S("a", 0, "-a", "--zzz", "--", "--zzz");
    return 0;
}
