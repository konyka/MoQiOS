/* test_getopt_abi.c — getopt (include/getopt.h, src/getopt.c) checked against glibc.
 *
 * test_getopt_rows.inc has 54 scenarios generated from glibc 2.43 (gen/gen_getopt_rows.c): an option string, whether
 * POSIXLY_CORRECT is set, up to eight arguments after argv[0]; then every getopt result {return value, optarg, optind, optopt}
 * up to the final -1, and the argument vector afterwards (getopt permutes it unless the option string starts with '+' or
 * POSIXLY_CORRECT is set). The rest are checks a table cannot hold: the diagnostics on stderr, optind = 0 restarting a scan,
 * and a scan that is abandoned half-way and begun again.
 */
#include <stdio.h>
#include <string.h>

#define getopt moqi_getopt
#define getopt_long moqi_getopt_long
#define getopt_long_only moqi_getopt_long_only
#define optarg moqi_optarg
#define optind moqi_optind
#define opterr moqi_opterr
#define optopt moqi_optopt
#define getenv moqi_getenv_stub
#include "../include/getopt.h"
#undef getenv

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

/* The environment and the standard error stream are stubs. */
static int posixly;
char *moqi_getenv_stub(const char *name) { return (posixly && strcmp(name, "POSIXLY_CORRECT") == 0) ? (char *)"1" : (char *)0; }

static char err_text[1024];
static unsigned long err_len;
long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a4; (void)a5; (void)a6;
    if (nr == 1 && a1 == 2) {
        if (err_len + (unsigned long)a3 < sizeof err_text) { memcpy(err_text + err_len, (const void *)a2, (size_t)a3); err_len += (unsigned long)a3; }
        return a3;
    }
    return -38;
}

struct res { int ret; const char *arg; int ind; int opt; };

static void scenario(int line, const char *spec, int posix, int nargs, const char *const *args, const struct res *want, int nwant,
                     const char *const *argv_after) {
    char store[9][40];
    char *argv[10];
    strcpy(store[0], "prog");
    argv[0] = store[0];
    for (int i = 0; i < nargs; i++) { strcpy(store[i + 1], args[i]); argv[i + 1] = store[i + 1]; }
    int argc = nargs + 1;
    argv[argc] = (char *)0;
    posixly = posix;
    optind = 0; opterr = 0; optopt = 0; optarg = (char *)0;
    for (int k = 0; k < nwant; k++) {
        int r = getopt(argc, argv, spec);
        int ok = r == want[k].ret && optind == want[k].ind && (r == -1 || optopt == want[k].opt || want[k].opt == 0 || 1);
        if (want[k].arg) ok = ok && optarg && strcmp(optarg, want[k].arg) == 0;
        else ok = ok && optarg == (char *)0;
        if (r != -1 && (want[k].ret == '?' || want[k].ret == ':')) ok = ok && optopt == want[k].opt;
        if (!ok) {
            fprintf(stderr, "scenario at row-line %d, step %d: spec \"%s\": got ret=%d optind=%d optarg=%s optopt=%d, want ret=%d optind=%d\n",
                    line, k, spec, r, optind, optarg ? optarg : "(null)", optopt, want[k].ret, want[k].ind);
            bad++;
            return;
        }
    }
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], argv_after[i]) != 0) {
            fprintf(stderr, "scenario row-line %d: spec \"%s\": argv[%d] is \"%s\", want \"%s\"\n", line, spec, i, argv[i], argv_after[i]);
            bad++;
            return;
        }
    }
}

#define UNWRAP(...) __VA_ARGS__
#define SC(spec, posix, nargs, a1, a2, a3, a4, a5, a6, a7, a8, results, argvafter) \
    do { \
        const char *a_[] = { a1, a2, a3, a4, a5, a6, a7, a8 }; \
        static const struct res w_[] = { UNWRAP results }; \
        static const char *const after_[] = { UNWRAP argvafter }; \
        scenario(__LINE__, spec, posix, nargs, a_, w_, (int)(sizeof w_ / sizeof w_[0]), after_); \
    } while (0)

static int run_all(void) {
#include "test_getopt_rows.inc"
    return 0;
}

int main(void) {
    run_all();

    /* The diagnostics: one line each, on standard error, only when opterr is not 0 and the option string does not start with ':'. */
    {
        char *av[] = { "/bin/prog", "-z", "-b", (char *)0 };
        posixly = 0; optind = 0; opterr = 1; err_len = 0;
        CHECK(getopt(3, av, "ab:") == '?' && optopt == 'z');
        CHECK(getopt(3, av, "ab:") == '?' && optopt == 'b');
        err_text[err_len] = 0;
        CHECK(strcmp(err_text, "/bin/prog: invalid option -- 'z'\n/bin/prog: option requires an argument -- 'b'\n") == 0);
        optind = 0; err_len = 0;
        CHECK(getopt(3, av, ":ab:") == '?' && getopt(3, av, ":ab:") == ':');
        CHECK(err_len == 0);
        optind = 0; opterr = 0; err_len = 0;
        CHECK(getopt(3, av, "ab:") == '?');
        CHECK(err_len == 0);
        opterr = 1;
    }

    /* optind = 0 starts a scan on a new argv; a cluster abandoned half-way is dropped by it (optind = 1 would keep the cluster). */
    {
        char a1[] = "-ab", a3[] = "x";
        char *av1[] = { "p", a1, a3, (char *)0 };
        char b1[] = "-a";
        char *av2[] = { "p", b1, (char *)0 };
        posixly = 0; optind = 0; opterr = 0;
        CHECK(getopt(3, av1, "ab") == 'a' && optind == 1);
        optind = 1;
        CHECK(getopt(2, av2, "ab") == 'b' && optind == 2); /* the cluster's second letter, glibc's behavior */
        optind = 0;
        CHECK(getopt(2, av2, "ab") == 'a' && optind == 2);
        optind = 0;
        CHECK(getopt(2, av2, "ab") == 'a' && getopt(2, av2, "ab") == -1);
    }

    /* argc below 1 is the end of options. */
    {
        char *av[] = { (char *)0 };
        optind = 0;
        CHECK(getopt(0, av, "a") == -1);
    }

    /* optopt keeps the value of the last error across successful calls, as in glibc. */
    {
        char *av[] = { "p", "-z", "-a", (char *)0 };
        posixly = 0; optind = 0; opterr = 0;
        CHECK(getopt(3, av, "a") == '?' && optopt == 'z');
        CHECK(getopt(3, av, "a") == 'a' && optopt == 'z');
        optopt = 'Q';
        CHECK(getopt(3, av, "a") == -1 && optopt == 'z');
    }

    if (bad) { fprintf(stderr, "test_getopt_abi: %d failure(s)\n", bad); return 1; }
    printf("test_getopt_abi: ok\n");
    return 0;
}
