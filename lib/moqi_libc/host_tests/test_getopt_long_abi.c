/* test_getopt_long_abi.c — getopt_long and getopt_long_only (include/getopt.h, src/getopt.c) checked against glibc.
 *
 * test_getopt_long_rows.inc has 50 scenarios generated from glibc 2.43 (gen/gen_getopt_long_rows.c) over the option table in
 * getopt_long_table.inc: every call's {return, optarg, optind, optopt, longindex, flag variable}, the argument vector afterwards
 * and the exact text written to standard error (opterr is 1 in every row). The longindex of a short option is left untouched
 * (the row shows -77 ... or the table index; the generator pre-sets -77 and the row records what glibc left).
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

#include "getopt_long_table.inc"

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

char *moqi_getenv_stub(const char *name) { (void)name; return (char *)0; }

static char err_text[2048];
static unsigned long err_len;
long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a4; (void)a5; (void)a6;
    if (nr == 1 && a1 == 2) {
        if (err_len + (unsigned long)a3 < sizeof err_text) { memcpy(err_text + err_len, (const void *)a2, (size_t)a3); err_len += (unsigned long)a3; }
        return a3;
    }
    return -38;
}

struct res { int ret; const char *arg; int ind; int opt; int idx; int flag; };

static void scenario(int line, const char *spec, int only, int nargs, const char *const *args, const struct res *want, int nwant,
                     const char *const *argv_after, const char *want_err) {
    char store[9][40];
    char *argv[10];
    strcpy(store[0], "prog");
    argv[0] = store[0];
    for (int i = 0; i < nargs; i++) { strcpy(store[i + 1], args[i]); argv[i + 1] = store[i + 1]; }
    int argc = nargs + 1;
    argv[argc] = (char *)0;
    optind = 0; opterr = 1; optopt = 0; optarg = (char *)0; flagv = 0; err_len = 0;
    for (int k = 0; k < nwant; k++) {
        int idx = -77;
        int r = only ? getopt_long_only(argc, argv, spec, long_table, &idx) : getopt_long(argc, argv, spec, long_table, &idx);
        int last = want[k].ret == -1;
        int ok = r == want[k].ret && optind == want[k].ind;
        if (!last) {
            ok = ok && optopt == want[k].opt && idx == want[k].idx && flagv == want[k].flag;
            if (want[k].arg) ok = ok && optarg && strcmp(optarg, want[k].arg) == 0;
            else ok = ok && optarg == (char *)0;
        }
        if (!ok) {
            fprintf(stderr, "row-line %d, step %d: spec \"%s\"%s: got ret=%d arg=%s optind=%d optopt=%d idx=%d flag=%d; want ret=%d optind=%d "
                    "optopt=%d idx=%d flag=%d\n", line, k, spec, only ? " (long_only)" : "", r, optarg ? optarg : "(null)", optind, optopt, idx,
                    flagv, want[k].ret, want[k].ind, want[k].opt, want[k].idx, want[k].flag);
            bad++;
            return;
        }
    }
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], argv_after[i]) != 0) {
            fprintf(stderr, "row-line %d: spec \"%s\": argv[%d] is \"%s\", want \"%s\"\n", line, spec, i, argv[i], argv_after[i]);
            bad++;
            return;
        }
    }
    err_text[err_len] = 0;
    if (strcmp(err_text, want_err) != 0) {
        fprintf(stderr, "row-line %d: spec \"%s\": stderr is\n  %s  want\n  %s\n", line, spec, err_text, want_err);
        bad++;
    }
}

#define UNWRAP(...) __VA_ARGS__
#define SL(spec, only, nargs, a1, a2, a3, a4, a5, a6, a7, a8, results, argvafter, errtext) \
    do { \
        const char *a_[] = { a1, a2, a3, a4, a5, a6, a7, a8 }; \
        static const struct res w_[] = { UNWRAP results }; \
        static const char *const after_[] = { UNWRAP argvafter }; \
        scenario(__LINE__, spec, only, nargs, a_, w_, (int)(sizeof w_ / sizeof w_[0]), after_, errtext); \
    } while (0)

int main(void) {
#include "test_getopt_long_rows.inc"

    /* An option table with a NULL longopts is plain getopt, and a NULL longind is allowed. */
    {
        char a1[] = "--verbose", a2[] = "-v";
        char *av[] = { "prog", a1, a2, (char *)0 };
        optind = 0; opterr = 0;
        CHECK(getopt_long(3, av, "v", long_table, (int *)0) == 'v' && getopt_long(3, av, "v", long_table, (int *)0) == 'v');
        optind = 0;
        CHECK(getopt_long(3, av, "v", (const struct option *)0, (int *)0) == '?');
    }
    CHECK(no_argument == 0 && required_argument == 1 && optional_argument == 2 && sizeof(struct option) == 32);

    if (bad) { fprintf(stderr, "test_getopt_long_abi: %d failure(s)\n", bad); return 1; }
    printf("test_getopt_long_abi: ok\n");
    return 0;
}
