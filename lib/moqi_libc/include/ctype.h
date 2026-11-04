/* ctype.h — character classification and case mapping for the C locale, header-only.
 *
 * Each classification is true only for ASCII characters (0..127), as in glibc's C locale; every byte above 127 is
 * "not a character" for all of them. The argument is an unsigned char value or EOF (-1), like the standard says. Values outside
 * that range, which glibc reads past its tables for, are safe here: no classification is true and the case mappings return
 * the argument unchanged. A signed char in -128..-2 is the byte 256 + c: its classifications are false and toupper/tolower
 * return 256 + c, what glibc does (host_tests/test_ctype_abi.c compares every defined argument with glibc).
 * The functions are static inline so they work as function pointers and with the (isalpha)(c) spelling; there are no macros.
 */
#ifndef MOQI_CTYPE_H
#define MOQI_CTYPE_H

static inline int isascii(int c) { return c >= 0 && c <= 127; }
static inline int isdigit(int c) { return c >= '0' && c <= '9'; }
static inline int isupper(int c) { return c >= 'A' && c <= 'Z'; }
static inline int islower(int c) { return c >= 'a' && c <= 'z'; }
static inline int isalpha(int c) { return isupper(c) || islower(c); }
static inline int isalnum(int c) { return isalpha(c) || isdigit(c); }
static inline int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
static inline int isblank(int c) { return c == ' ' || c == '\t'; }
static inline int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
static inline int iscntrl(int c) { return (c >= 0 && c < 32) || c == 127; }
static inline int isgraph(int c) { return c > 32 && c < 127; }
static inline int isprint(int c) { return c >= 32 && c < 127; }
static inline int ispunct(int c) { return isgraph(c) && !isalnum(c); }

static inline int toascii(int c) { return c & 0x7f; }

static inline int toupper(int c) {
    if (islower(c)) return c - 'a' + 'A';
    return c >= -128 && c < -1 ? c + 256 : c;
}
static inline int tolower(int c) {
    if (isupper(c)) return c - 'A' + 'a';
    return c >= -128 && c < -1 ? c + 256 : c;
}

#endif /* MOQI_CTYPE_H */
