/* The option table shared by gen/gen_getopt_long_rows.c (run against glibc) and test_getopt_long_abi.c (run against src/getopt.c). */
static int flagv;
static const struct option long_table[] = {
    {"verbose", no_argument, 0, 'v'},   {"output", required_argument, 0, 'o'}, {"opt", optional_argument, 0, 'p'},
    {"flag", no_argument, &flagv, 42},  {"version", no_argument, 0, 'V'},      {"verify", no_argument, 0, 1000},
    {"x", required_argument, 0, 'x'},   {"abc", no_argument, 0, 'a'},          {"abd", no_argument, 0, 'a'},
    {"abe", no_argument, 0, 'e'},       {"flagged", no_argument, &flagv, 5},   {"flagged2", no_argument, &flagv, 5},
    {"nof", required_argument, 0, 'n'}, {"nof2", optional_argument, 0, 'n'},   {"zzz", no_argument, 0, 'z'},
    {"qq1", no_argument, &flagv, 7},    {"qq2", no_argument, 0, 7},
    {0, 0, 0, 0}};
