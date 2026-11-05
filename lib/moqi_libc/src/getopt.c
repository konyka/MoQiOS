/* getopt.c — getopt, getopt_long and getopt_long_only (see include/getopt.h), with glibc's behavior.
 *
 * The algorithm, the argument permutation, the long-option matching and the diagnostics follow glibc (checked scenario by scenario against glibc 2.43 in
 * host_tests/test_getopt_abi.c). One glibc quirk is kept on purpose because programs observe it: optopt is not cleared by a
 * successful call, it keeps the value of the last error until the next error (the library holds its own copy and publishes it
 * after every call, so a program that sets optopt itself does not change what the next call reports).
 */
#include "../include/stdlib.h"
#include "../include/getopt.h"
#include "../include/unistd.h"
#include "hostsys.h"

char *optarg;
int optind = 1;
int opterr = 1;
int optopt;

enum { REQUIRE_ORDER, PERMUTE, RETURN_IN_ORDER };

static int initialized;
static int first_nonopt;
static int last_nonopt;
static int ordering;
static char *nextchar;
static int st_optopt;

#define NONOPTION_P(argv, i) ((argv)[i][0] != '-' || (argv)[i][1] == '\0')

static void go_exchange(char **argv) {
    int bottom = first_nonopt;
    int middle = last_nonopt;
    int top = optind;
    char *tem;
    /* The shorter segment is swapped with the far end of the longer one until the options precede the non-options. */
    while (top > middle && middle > bottom) {
        if (top - middle > middle - bottom) {
            int len = middle - bottom;
            for (int i = 0; i < len; i++) {
                tem = argv[bottom + i];
                argv[bottom + i] = argv[top - (middle - bottom) + i];
                argv[top - (middle - bottom) + i] = tem;
            }
            top -= len;
        } else {
            int len = top - middle;
            for (int i = 0; i < len; i++) {
                tem = argv[bottom + i];
                argv[bottom + i] = argv[middle + i];
                argv[middle + i] = tem;
            }
            bottom += len;
        }
    }
    first_nonopt += optind - last_nonopt;
    last_nonopt = optind;
}

static const char *go_strchr(const char *s, int c) {
    for (; *s; s++)
        if (*s == (char)c) return s;
    return (const char *)0;
}

/* Diagnostics are built in one buffer and written with one write, so another thread's output cannot split a line. */
struct go_msg {
    char buf[512];
    unsigned long n;
};

static void msg_add(struct go_msg *m, const char *s) {
    for (; *s && m->n < sizeof m->buf - 2; s++) m->buf[m->n++] = *s;
}

static void msg_addc(struct go_msg *m, char c) {
    if (m->n < sizeof m->buf - 2) m->buf[m->n++] = c;
}

static void msg_flush(struct go_msg *m) {
    m->buf[m->n++] = '\n';
    MSYS3(SYS_write, STDERR_FILENO, m->buf, m->n);
}

/* "<prog>: <what> -- '<c>'" */
static void go_report(const char *prog, const char *what, char c) {
    struct go_msg m;
    m.n = 0;
    msg_add(&m, prog);
    msg_add(&m, ": ");
    msg_add(&m, what);
    msg_add(&m, " -- '");
    msg_addc(&m, c);
    msg_addc(&m, '\'');
    msg_flush(&m);
}

/* "<prog>: option '<prefix><name>' <what>" */
static void go_report_long(const char *prog, const char *prefix, const char *name, const char *what) {
    struct go_msg m;
    m.n = 0;
    msg_add(&m, prog);
    msg_add(&m, ": ");
    if (what[0] == 'u') { /* "unrecognized option '--x'" */
        msg_add(&m, what);
        msg_add(&m, " '");
        msg_add(&m, prefix);
        msg_add(&m, name);
        msg_addc(&m, '\'');
    } else {
        msg_add(&m, "option '");
        msg_add(&m, prefix);
        msg_add(&m, name);
        msg_add(&m, "' ");
        msg_add(&m, what);
    }
    msg_flush(&m);
}

static int go_strncmp(const char *a, const char *b, unsigned long n) {
    for (; n; n--, a++, b++) {
        if (*a != *b) return (unsigned char)*a - (unsigned char)*b;
        if (*a == '\0') return 0;
    }
    return 0;
}

static unsigned long go_strlen(const char *s) {
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}

/* A name that is a prefix of the option text before any '=', for the abbreviation rule. */
static int is_prefix_match(const struct option *p, const char *text, unsigned long len) {
    return go_strncmp(p->name, text, len) == 0;
}

/* Handles the text after "--" (or "-" for getopt_long_only, or the argument of -W) as a long option. Returns the value to hand
 * back to the caller, or -1 when getopt_long_only decides the text is a cluster of short options after all. */
static int process_long_option(int argc, char **argv, const char *optstring, const struct option *longopts, int *longind,
                               int long_only, int print_errors, const char *prefix) {
    char *nameend;
    for (nameend = nextchar; *nameend && *nameend != '='; nameend++) {}
    unsigned long namelen = (unsigned long)(nameend - nextchar);

    const struct option *p;
    const struct option *pfound = (const struct option *)0;
    int n_options = 0;
    int option_index = 0;

    /* An exact match wins over any abbreviation. */
    for (p = longopts; p->name; p++, n_options++) {
        if (is_prefix_match(p, nextchar, namelen) && namelen == go_strlen(p->name)) {
            pfound = p;
            option_index = n_options;
            break;
        }
    }

    if (pfound == (const struct option *)0) {
        int indfound = -1;
        int ambiguous = 0;
        for (p = longopts, option_index = 0; p->name; p++, option_index++) {
            if (!is_prefix_match(p, nextchar, namelen)) continue;
            if (pfound == (const struct option *)0) {
                pfound = p;
                indfound = option_index;
            } else if (long_only || pfound->has_arg != p->has_arg || pfound->flag != p->flag || pfound->val != p->val) {
                /* Abbreviations of options that are the same thing (same argument rule, flag and value) are not ambiguous. */
                ambiguous = 1;
            }
        }
        if (ambiguous) {
            if (print_errors) {
                struct go_msg m;
                m.n = 0;
                msg_add(&m, argv[0]);
                msg_add(&m, ": option '");
                msg_add(&m, prefix);
                msg_add(&m, nextchar);
                msg_add(&m, "' is ambiguous; possibilities:");
                const struct option *first = (const struct option *)0;
                for (p = longopts; p->name; p++) {
                    if (!is_prefix_match(p, nextchar, namelen)) continue;
                    if (first == (const struct option *)0 || long_only || first->has_arg != p->has_arg || first->flag != p->flag ||
                        first->val != p->val) {
                        msg_add(&m, " '");
                        msg_add(&m, prefix);
                        msg_add(&m, p->name);
                        msg_addc(&m, '\'');
                    }
                    if (first == (const struct option *)0) first = p;
                }
                msg_flush(&m);
            }
            nextchar += go_strlen(nextchar);
            optind++;
            optopt = st_optopt = 0;
            return '?';
        }
        option_index = indfound;
    }

    if (pfound == (const struct option *)0) {
        /* Not a long option. With getopt_long_only a single-dash text that starts with a valid short option is read as short
         * options; anything else is an error. */
        if (!long_only || argv[optind][1] == '-' || go_strchr(optstring, *nextchar) == (const char *)0) {
            if (print_errors) go_report_long(argv[0], prefix, nextchar, "unrecognized option");
            nextchar = (char *)0;
            optind++;
            optopt = st_optopt = 0;
            return '?';
        }
        return -1;
    }

    /* A long option was found: consume it. */
    optind++;
    nextchar = (char *)0;
    if (*nameend) {
        if (pfound->has_arg) {
            optarg = nameend + 1;
        } else {
            if (print_errors) go_report_long(argv[0], prefix, pfound->name, "doesn't allow an argument");
            optopt = st_optopt = pfound->val;
            return '?';
        }
    } else if (pfound->has_arg == 1) {
        if (optind < argc) {
            optarg = argv[optind++];
        } else {
            if (print_errors) go_report_long(argv[0], prefix, pfound->name, "requires an argument");
            optopt = st_optopt = pfound->val;
            return optstring[0] == ':' ? ':' : '?';
        }
    }

    if (longind != (int *)0) *longind = option_index;
    if (pfound->flag) {
        *(pfound->flag) = pfound->val;
        return 0;
    }
    return pfound->val;
}

static int getopt_scan(int argc, char *const argv_const[], const char *optstring, const struct option *longopts, int *longind,
                       int long_only) {
    char **argv = (char **)argv_const;
    optarg = (char *)0;
    if (argc < 1) return -1;

    int print_errors = opterr;
    if (optind == 0 || !initialized) {
        if (optind == 0) optind = 1;
        first_nonopt = last_nonopt = optind;
        nextchar = (char *)0;
        int posix = getenv("POSIXLY_CORRECT") != (char *)0;
        if (optstring[0] == '-') {
            ordering = RETURN_IN_ORDER;
            optstring++;
        } else if (optstring[0] == '+') {
            ordering = REQUIRE_ORDER;
            optstring++;
        } else if (posix) {
            ordering = REQUIRE_ORDER;
        } else {
            ordering = PERMUTE;
        }
        initialized = 1;
    } else if (optstring[0] == '-' || optstring[0] == '+') {
        optstring++;
    }
    if (optstring[0] == ':') print_errors = 0;

    if (nextchar == (char *)0 || *nextchar == '\0') {
        /* Keep first_nonopt and last_nonopt sensible if the program moved optind back. */
        if (last_nonopt > optind) last_nonopt = optind;
        if (first_nonopt > optind) first_nonopt = optind;

        if (ordering == PERMUTE) {
            /* Options that follow skipped non-options are moved in front of them. */
            if (first_nonopt != last_nonopt && last_nonopt != optind)
                go_exchange(argv);
            else if (last_nonopt != optind)
                first_nonopt = optind;
            while (optind < argc && NONOPTION_P(argv, optind)) optind++;
            last_nonopt = optind;
        }

        /* "--" ends the options: it is skipped, and everything after it is a non-option. */
        if (optind != argc && argv[optind][0] == '-' && argv[optind][1] == '-' && argv[optind][2] == '\0') {
            optind++;
            if (first_nonopt != last_nonopt && last_nonopt != optind)
                go_exchange(argv);
            else if (first_nonopt == last_nonopt)
                first_nonopt = optind;
            last_nonopt = argc;
            optind = argc;
        }

        if (optind == argc) {
            /* Back over the non-options that were skipped and permuted, so the caller sees them. */
            if (first_nonopt != last_nonopt) optind = first_nonopt;
            optopt = st_optopt;
            return -1;
        }

        if (NONOPTION_P(argv, optind)) {
            if (ordering == REQUIRE_ORDER) {
                optopt = st_optopt;
                return -1;
            }
            optarg = argv[optind++];
            optopt = st_optopt;
            return 1;
        }

        if (longopts) {
            if (argv[optind][1] == '-') {
                /* "--name" is always a long option. */
                nextchar = argv[optind] + 2;
                return process_long_option(argc, argv, optstring, longopts, longind, long_only, print_errors, "--");
            }
            /* "-f" where f is a valid short option stays a short option, so that it can still be given; "-fu" with a long
             * option "fubar" is an abbreviation of it, like "--fu". */
            if (long_only && (argv[optind][2] || go_strchr(optstring, argv[optind][1]) == (const char *)0)) {
                nextchar = argv[optind] + 1;
                int code = process_long_option(argc, argv, optstring, longopts, longind, long_only, print_errors, "-");
                if (code != -1) return code;
            }
        }

        nextchar = argv[optind] + 1;
    }

    char c = *nextchar++;
    const char *temp = go_strchr(optstring, c);
    if (*nextchar == '\0') ++optind;

    if (temp == (const char *)0 || c == ':' || c == ';') {
        if (print_errors) go_report(argv[0], "invalid option", c);
        st_optopt = (unsigned char)c;
        optopt = st_optopt;
        return '?';
    }

    /* "W;" in the option string: -W name is the long option --name. */
    if (temp[0] == 'W' && temp[1] == ';' && longopts != (const struct option *)0) {
        if (*nextchar != '\0') {
            optarg = nextchar;
        } else if (optind == argc) {
            if (print_errors) go_report(argv[0], "option requires an argument", c);
            st_optopt = (unsigned char)c;
            optopt = st_optopt;
            return optstring[0] == ':' ? ':' : '?';
        } else {
            optarg = argv[optind];
        }
        nextchar = optarg;
        optarg = (char *)0;
        return process_long_option(argc, argv, optstring, longopts, longind, 0, print_errors, "-W ");
    }

    int ret = (unsigned char)c;
    if (temp[1] == ':') {
        if (temp[2] == ':') {
            /* An argument is allowed but not required: only the rest of this element counts. */
            if (*nextchar != '\0') {
                optarg = nextchar;
                optind++;
            } else {
                optarg = (char *)0;
            }
            nextchar = (char *)0;
        } else {
            if (*nextchar != '\0') {
                optarg = nextchar;
                optind++;
            } else if (optind == argc) {
                if (print_errors) go_report(argv[0], "option requires an argument", c);
                st_optopt = (unsigned char)c;
                ret = (optstring[0] == ':') ? ':' : '?';
            } else {
                optarg = argv[optind++];
            }
            nextchar = (char *)0;
        }
    }
    optopt = st_optopt;
    return ret;
}

/* Every call ends by publishing the library's own copy of optopt, as glibc's wrappers do. */
static int getopt_internal(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longind,
                           int long_only) {
    int r = getopt_scan(argc, argv, optstring, longopts, longind, long_only);
    optopt = st_optopt;
    return r;
}

int getopt(int argc, char *const argv[], const char *optstring) {
    return getopt_internal(argc, argv, optstring, (const struct option *)0, (int *)0, 0);
}

int getopt_long(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longind) {
    return getopt_internal(argc, argv, optstring, longopts, longind, 0);
}

int getopt_long_only(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longind) {
    return getopt_internal(argc, argv, optstring, longopts, longind, 1);
}
