/* getopt.h — getopt (see src/getopt.c). */
#ifndef MOQI_GETOPT_H
#define MOQI_GETOPT_H

/* getopt with glibc's behavior for short options: "-abc" clusters, an option argument attached ("-bval") or in the next
 * element, "::" for an optional (attached only) argument, "--" ends the options, a lone "-" is an argument. Unless the option
 * string starts with '+' or POSIXLY_CORRECT is in the environment, getopt permutes argv so the options come first (optind then
 * names the first non-option at the end); a leading '-' returns each non-option as the option character 1 with optarg set. An
 * unknown option returns '?' with optopt set; a missing argument returns '?', or ':' when the option string starts with ':'
 * (after an optional '+' or '-'), which also silences the "prog: invalid option -- 'z'" / "prog: option requires an argument
 * -- 'b'" lines written to standard error when opterr is not 0. Setting optind to 0 restarts a scan on a new argv (setting it
 * to 1 does not clear a half-processed "-ab" cluster). optopt keeps the value of the last error across successful calls, as
 * in glibc. Not provided: the optreset of the BSDs.
 *
 * getopt_long adds "--name", "--name=value" and "--name value" (required_argument) from a table of struct option ended by an
 * all-zero entry. A unique prefix of a name is accepted ("--verb" for "--verbose"); a prefix that fits several options that differ
 * in argument rule, flag or value is ambiguous (returns '?', optopt 0, and writes the list of candidates), while an exact name
 * always wins. An option with a flag pointer stores val there and returns 0; otherwise the call returns val. *longind receives the
 * table index of a long option (and is left alone for a short one). The same diagnostics as glibc are written to standard error
 * unless opterr is 0 or the option string starts with ':'; a missing required argument returns ':' with that prefix and '?'
 * without it, and optopt holds the option's val. "W;" in the option string makes "-W name" mean "--name". getopt_long_only also
 * reads a single-dash word as a long option, except that "-f" for a valid short option f stays short and "-fu" is tried as a
 * long-option abbreviation first. */
struct option {
    const char *name;
    int has_arg;
    int *flag;
    int val;
};
#define no_argument       0
#define required_argument 1
#define optional_argument 2

int getopt_long(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longind);
int getopt_long_only(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longind);
extern char *optarg;
extern int optind, opterr, optopt;
int getopt(int argc, char *const argv[], const char *optstring);

#endif /* MOQI_GETOPT_H */
