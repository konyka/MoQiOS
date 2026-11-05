/* Generated from glibc 2.43 by gen/gen_getopt_long_rows.c (option table: getopt_long_table.inc). */
SL("vo:", 0, 2, "--verbose", "x", "", "", "", "", "", "",
   ( {118, (const char *)0, 2, 0, 0, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--verbose", "x", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 4, "--output=f", "--output", "g", "x", "", "", "", "",
   ( {111, "f", 2, 0, 1, 0}, {111, "g", 4, 0, 1, 0}, {-1, (const char *)0, 4, 0, 0, 0}),
   ( "prog", "--output=f", "--output", "g", "x", "", "", "", "",),
   "");
SL("vo:", 0, 1, "--out=f", "", "", "", "", "", "", "",
   ( {111, "f", 2, 0, 1, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--out=f", "", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 1, "--ver", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--ver", "", "", "", "", "", "", "",),
   "prog: option '--ver' is ambiguous; possibilities: '--verbose' '--version' '--verify'\n");
SL("vo:", 0, 1, "--verb", "", "", "", "", "", "", "",
   ( {118, (const char *)0, 2, 0, 0, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--verb", "", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 3, "--opt=1", "--opt", "2", "", "", "", "", "",
   ( {112, "1", 2, 0, 2, 0}, {112, (const char *)0, 3, 0, 2, 0}, {-1, (const char *)0, 3, 0, 0, 0}),
   ( "prog", "--opt=1", "--opt", "2", "", "", "", "", "",),
   "");
SL("vo:", 0, 1, "--opt", "", "", "", "", "", "", "",
   ( {112, (const char *)0, 2, 0, 2, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--opt", "", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 2, "--flag", "--flag", "", "", "", "", "", "",
   ( {0, (const char *)0, 2, 0, 3, 42}, {0, (const char *)0, 3, 0, 3, 42}, {-1, (const char *)0, 3, 0, 0, 0}),
   ( "prog", "--flag", "--flag", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 1, "--verbose=1", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 118, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--verbose=1", "", "", "", "", "", "", "",),
   "prog: option '--verbose' doesn't allow an argument\n");
SL("vo:", 0, 1, "--output", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 111, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--output", "", "", "", "", "", "", "",),
   "prog: option '--output' requires an argument\n");
SL("vo:", 0, 1, "--nosuch", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--nosuch", "", "", "", "", "", "", "",),
   "prog: unrecognized option '--nosuch'\n");
SL("vo:", 0, 1, "--=x", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--=x", "", "", "", "", "", "", "",),
   "prog: option '--=x' is ambiguous; possibilities: '--verbose' '--output' '--opt' '--flag' '--version' '--verify' '--x' '--abc' '--abd' '--abe' '--flagged' '--flagged2' '--nof' '--nof2' '--zzz' '--qq1' '--qq2'\n");
SL("vo:", 0, 2, "--", "--verbose", "", "", "", "", "", "",
   ( {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--", "--verbose", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 3, "x", "--verbose", "y", "", "", "", "", "",
   ( {118, (const char *)0, 3, 0, 0, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--verbose", "x", "y", "", "", "", "", "",),
   "");
SL("+vo:", 0, 2, "x", "--verbose", "", "", "", "", "", "",
   ( {-1, (const char *)0, 1, 0, 0, 0}),
   ( "prog", "x", "--verbose", "", "", "", "", "", "",),
   "");
SL("-vo:", 0, 2, "x", "--verbose", "", "", "", "", "", "",
   ( {1, "x", 2, 0, -77, 0}, {118, (const char *)0, 3, 0, 0, 0}, {-1, (const char *)0, 3, 0, 0, 0}),
   ( "prog", "x", "--verbose", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 1, "--verify", "", "", "", "", "", "", "",
   ( {1000, (const char *)0, 2, 0, 5, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--verify", "", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 1, "--version", "", "", "", "", "", "", "",
   ( {86, (const char *)0, 2, 0, 4, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--version", "", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 1, "--versi", "", "", "", "", "", "", "",
   ( {86, (const char *)0, 2, 0, 4, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--versi", "", "", "", "", "", "", "",),
   "");
SL(":vo:", 0, 1, "--output", "", "", "", "", "", "", "",
   ( {58, (const char *)0, 2, 111, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--output", "", "", "", "", "", "", "",),
   "");
SL(":vo:", 0, 1, "--nosuch", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--nosuch", "", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 5, "-v", "--x=a", "--x", "b", "-oq", "", "", "",
   ( {118, (const char *)0, 2, 0, -77, 0}, {120, "a", 3, 0, 6, 0}, {120, "b", 5, 0, 6, 0}, {111, "q", 6, 0, -77, 0}, {-1, (const char *)0, 6, 0, 0, 0}),
   ( "prog", "-v", "--x=a", "--x", "b", "-oq", "", "", "",),
   "");
SL("vo:", 0, 1, "--out", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 111, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--out", "", "", "", "", "", "", "",),
   "prog: option '--output' requires an argument\n");
SL("vo:", 0, 1, "--o", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--o", "", "", "", "", "", "", "",),
   "prog: option '--o' is ambiguous; possibilities: '--output' '--opt'\n");
SL("vo:", 0, 1, "--p=9", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--p=9", "", "", "", "", "", "", "",),
   "prog: unrecognized option '--p=9'\n");
SL("W;", 0, 2, "-W", "verbose", "", "", "", "", "", "",
   ( {118, (const char *)0, 3, 0, 0, 0}, {-1, (const char *)0, 3, 0, 0, 0}),
   ( "prog", "-W", "verbose", "", "", "", "", "", "",),
   "");
SL("W;", 0, 2, "-W", "nosuch", "", "", "", "", "", "",
   ( {63, (const char *)0, 3, 0, -77, 0}, {-1, (const char *)0, 3, 0, 0, 0}),
   ( "prog", "-W", "nosuch", "", "", "", "", "", "",),
   "prog: unrecognized option '-W nosuch'\n");
SL("W;n", 0, 2, "-W", "nosuch", "", "", "", "", "", "",
   ( {63, (const char *)0, 3, 0, -77, 0}, {-1, (const char *)0, 3, 0, 0, 0}),
   ( "prog", "-W", "nosuch", "", "", "", "", "", "",),
   "prog: unrecognized option '-W nosuch'\n");
SL("W;", 0, 1, "-Wverbose", "", "", "", "", "", "", "",
   ( {118, (const char *)0, 2, 0, 0, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "-Wverbose", "", "", "", "", "", "", "",),
   "");
SL("W;", 0, 1, "-W", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 87, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "-W", "", "", "", "", "", "", "",),
   "prog: option requires an argument -- 'W'\n");
SL("vo:", 0, 1, "---x", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "---x", "", "", "", "", "", "", "",),
   "prog: unrecognized option '---x'\n");
SL("vo:", 0, 1, "--x=", "", "", "", "", "", "", "",
   ( {120, "", 2, 0, 6, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--x=", "", "", "", "", "", "", "",),
   "");
SL("vo:", 0, 1, "--opt=", "", "", "", "", "", "", "",
   ( {112, "", 2, 0, 2, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--opt=", "", "", "", "", "", "", "",),
   "");
SL("a", 0, 1, "--ab", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--ab", "", "", "", "", "", "", "",),
   "prog: option '--ab' is ambiguous; possibilities: '--abc' '--abe'\n");
SL("a", 0, 1, "--abc", "", "", "", "", "", "", "",
   ( {97, (const char *)0, 2, 0, 7, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--abc", "", "", "", "", "", "", "",),
   "");
SL("a", 0, 1, "--flagged", "", "", "", "", "", "", "",
   ( {0, (const char *)0, 2, 0, 10, 5}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--flagged", "", "", "", "", "", "", "",),
   "");
SL("a", 0, 1, "--flagg", "", "", "", "", "", "", "",
   ( {0, (const char *)0, 2, 0, 10, 5}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--flagg", "", "", "", "", "", "", "",),
   "");
SL("a", 0, 1, "--no", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--no", "", "", "", "", "", "", "",),
   "prog: option '--no' is ambiguous; possibilities: '--nof' '--nof2'\n");
SL("a", 0, 1, "-abc", "", "", "", "", "", "", "",
   ( {97, (const char *)0, 1, 0, -77, 0}, {63, (const char *)0, 1, 98, -77, 0}, {63, (const char *)0, 2, 99, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "-abc", "", "", "", "", "", "", "",),
   "prog: invalid option -- 'b'\nprog: invalid option -- 'c'\n");
SL("az", 1, 5, "-abc", "-zzz", "-z", "-a", "-ab", "", "", "",
   ( {97, (const char *)0, 2, 99, 7, 0}, {122, (const char *)0, 3, 99, 14, 0}, {122, (const char *)0, 4, 99, -77, 0}, {97, (const char *)0, 5, 99, -77, 0}, {63, (const char *)0, 6, 0, -77, 0}, {-1, (const char *)0, 6, 0, 0, 0}),
   ( "prog", "-abc", "-zzz", "-z", "-a", "-ab", "", "", "",),
   "prog: option '-ab' is ambiguous; possibilities: '-abc' '-abd' '-abe'\n");
SL("az", 1, 4, "-abc=1", "-nof=3", "-nof", "q", "", "", "", "",
   ( {63, (const char *)0, 2, 97, -77, 0}, {110, "3", 3, 97, 12, 0}, {110, "q", 5, 97, 12, 0}, {-1, (const char *)0, 5, 0, 0, 0}),
   ( "prog", "-abc=1", "-nof=3", "-nof", "q", "", "", "", "",),
   "prog: option '-abc' doesn't allow an argument\n");
SL("a", 1, 1, "-x", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 120, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "-x", "", "", "", "", "", "", "",),
   "prog: option '-x' requires an argument\n");
SL("a", 1, 1, "-flagg", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "-flagg", "", "", "", "", "", "", "",),
   "prog: option '-flagg' is ambiguous; possibilities: '-flagged' '-flagged2'\n");
SL("az", 1, 1, "-zz", "", "", "", "", "", "", "",
   ( {122, (const char *)0, 2, 0, 14, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "-zz", "", "", "", "", "", "", "",),
   "");
SL("a", 1, 2, "--abc", "-abe", "", "", "", "", "", "",
   ( {97, (const char *)0, 2, 0, 7, 0}, {101, (const char *)0, 3, 0, 9, 0}, {-1, (const char *)0, 3, 0, 0, 0}),
   ( "prog", "--abc", "-abe", "", "", "", "", "", "",),
   "");
SL("vo:", 1, 3, "-verbose", "-v", "-output=f", "", "", "", "", "",
   ( {118, (const char *)0, 2, 0, 0, 0}, {118, (const char *)0, 3, 0, -77, 0}, {111, "f", 4, 0, 1, 0}, {-1, (const char *)0, 4, 0, 0, 0}),
   ( "prog", "-verbose", "-v", "-output=f", "", "", "", "", "",),
   "");
SL("a", 0, 1, "--qq", "", "", "", "", "", "", "",
   ( {63, (const char *)0, 2, 0, -77, 0}, {-1, (const char *)0, 2, 0, 0, 0}),
   ( "prog", "--qq", "", "", "", "", "", "", "",),
   "prog: option '--qq' is ambiguous; possibilities: '--qq1' '--qq2'\n");
SL("a", 0, 2, "--qq1", "--qq2", "", "", "", "", "", "",
   ( {0, (const char *)0, 2, 0, 15, 7}, {7, (const char *)0, 3, 0, 16, 7}, {-1, (const char *)0, 3, 0, 0, 0}),
   ( "prog", "--qq1", "--qq2", "", "", "", "", "", "",),
   "");
SL("ab:", 0, 5, "-a", "--verbose", "-b", "v", "x", "", "", "",
   ( {97, (const char *)0, 2, 0, -77, 0}, {118, (const char *)0, 3, 0, 0, 0}, {98, "v", 5, 0, -77, 0}, {-1, (const char *)0, 5, 0, 0, 0}),
   ( "prog", "-a", "--verbose", "-b", "v", "x", "", "", "",),
   "");
SL("a", 0, 4, "-a", "--zzz", "--", "--zzz", "", "", "", "",
   ( {97, (const char *)0, 2, 0, -77, 0}, {122, (const char *)0, 3, 0, 14, 0}, {-1, (const char *)0, 4, 0, 0, 0}),
   ( "prog", "-a", "--zzz", "--", "--zzz", "", "", "", "",),
   "");
