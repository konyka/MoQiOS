/* gen_scanf_rows.c — writes test_scanf_rows.inc from the host's glibc.
 *
 *   gcc -O1 -o gen gen/gen_scanf_rows.c && ./gen | awk '!seen[$0]++' > test_scanf_rows.inc
 *
 * Every row is one fscanf call over a stream holding the input text. It records the return value, errno (starting from 0),
 * how many bytes were consumed (ftell), whether the end of file was seen (feof), and the bytes written into four 64-byte
 * slots that start filled with 0xAA (hex, up to the last byte that changed). The stream is read through the C23 entry
 * points (the default for a current compiler), so "%as" is not the GNU allocating extension and "%i" accepts 0b. */
#include <errno.h>
#include <gnu/libc-version.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t rng = 0x9e3779b97f4a7c15ULL;
static uint64_t next(void) {
    uint64_t z = (rng += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}
static unsigned rnd(unsigned n) { return (unsigned)(next() % n); }

static void esc(const char *s) {
    putchar('"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') printf("\\%c", c);
        else if (c >= 0x20 && c < 0x7f && c != '?') putchar(c);
        else printf("\\%03o", c);
    }
    putchar('"');
}

static long rows;
static void row(const char *fmt, const char *in) {
    FILE *f = tmpfile();
    fputs(in, f);
    rewind(f);
    unsigned char sl[4][64];
    memset(sl, 0xAA, sizeof sl);
    errno = 0;
    int r = fscanf(f, fmt, sl[0], sl[1], sl[2], sl[3]);
    int e = errno;
    long used = ftell(f);
    int eof = feof(f) != 0;
    fclose(f);
    printf("ROW(");
    esc(fmt);
    printf(", ");
    esc(in);
    printf(", %d, %d, %ld, %d", r, e, used, eof);
    for (int i = 0; i < 4; i++) {
        int last = -1;
        for (int j = 0; j < 64; j++)
            if (sl[i][j] != 0xAA) last = j;
        printf(", \"");
        for (int j = 0; j <= last; j++) printf("%02x", sl[i][j]);
        printf("\"");
    }
    printf(");\n");
    rows++;
}

static const char *pick(const char *const *a, unsigned n) { return a[rnd(n)]; }
#define N(a) (sizeof a / sizeof a[0])

static void rand_str(char *out, const char *alpha, unsigned maxlen) {
    unsigned n = rnd(maxlen + 1), al = (unsigned)strlen(alpha);
    for (unsigned i = 0; i < n; i++) out[i] = alpha[rnd(al)];
    out[n] = 0;
}

int main(void) {
    printf("/* Generated from glibc %s by gen/gen_scanf_rows.c: format, input, return value, errno, bytes consumed, end of file\n"
           " * seen, then the bytes written into four 64-byte slots that start filled with 0xAA (hex, up to the last byte that\n"
           " * changed). */\n",
           gnu_get_libc_version());
    static const char *hf[] = {
        "%d", "%i", "%u", "%o", "%x", "%X", "%b", "%p", "%hhd", "%hd", "%ld", "%lld", "%jd", "%zd", "%td", "%qd", "%Ld", "%hhu", "%hu", "%lu",
        "%llu", "%hhx", "%lx", "%hhi", "%3d", "%1d", "%2i", "%5x", "%3i", "%2d", "%0d", "%1x", "%4i", "%*d", "%*d%d", "%f", "%lf", "%e", "%E",
        "%g", "%G", "%F", "%a", "%A", "%hf", "%zf", "%jf", "%tf", "%3f", "%1f", "%2f", "%4f", "%5f", "%6f", "%7f", "%8f", "%*f", "%c", "%3c",
        "%1c", "%5c", "%*c", "%*3c", "%s", "%2s", "%1s", "%10s", "%*s", "%[a]", "%[a-c]", "%[^a]", "%[]a]", "%[^]a]", "%[a-]", "%[-a]", "%[c-a]",
        "%[a-c-e]", "%2[a]", "%*[a]", "%[a-z]%n", "%[", "%[a", "%[^", "%n", "%hhn", "%hn", "%ln", "%d%n", "%d%n%n", "%*d%n", "%%", "%d%%",
        "%%%d", " %%", "%5%", "%d %d", "%d,%d", "%d, %d", "%d ,%d", "%d%d", "%d%c", "%d %c", "%c%d", "%c%c", "%s%s", "%s%c", "%c%s", "a%d",
        "a %d", "a b%d", "a  b", "a b", "%da", "%d x", "%dx", "x%dy", "x%d", " a", "a", "a ", " ", "", "\n", "\t%d", "%d\n", "%d\n%d", "%c\n",
        "\xe9", "%d\xe9", "\xe9%d", "%lc", "%C", "%ls", "%S", "%l[a-c]", "%l[^a]", "%2lc", "%3lc", "%5ls", "%lc%lc", "%Ic", "%Is", "%I[a-c]",
        "%'s", "%'c", "%I%d", "%1$d%2$d", "%2$d%1$d", "%1$d%d", "%d%1$d", "%2$d", "%0$d", "%1$s", "%1$5d", "%2$*d", "%*2$d", "%$d", "%y", "%",
        "%5", "%5y", "%d%y", "%d%", "%-d", "%+d", "%#d", "% d", "%.2f", "%.d", "%hhhd", "%lhd", "%hld", "%zzd", "%B", "%D", "%O", "%U", "%'d",
        "%'f", "%Id", "%I d", "%I5d", "%*I5d", "%'5d", "%5'd", "%5*d", "%**d", "%'''d", "%w8d", "%w16d", "%w32d", "%w64d", "%wf8d", "%wf16d",
        "%wf32d", "%wf64d", "%w4d", "%w", "%wd", "%w8u", "%w16x", "%2147483647c", "%99999999999d", "%99999999999c", "%4294967297d",
        "%2147483648c", "%0c", "%0s", "%0[a-z]", "%c %c", "%1[a]", "%5[a]", "%[a]%[b]", "%[^\n]", "%[^\n]%n", "%*[^ ]", "%*s%d", "%*c%d",
        "%*[a]%d", "%*d%d", "%*s%s", "%*c%c", "%c%*c%c", "%[+--]", "%[a-a]", "%[b-a]", "%[a-b-]", "%[^^]", "%[]]", "%[^]]", "%[]-a]",
        "%[^]-a]", "%[^-a]", "%[a\\]", "%[ab]c", "%[ab]]", "a%[b]", "%[b]a", "%[a-z-]", "%[z-a]", "%d%hhn", "%d%hn", "%d%ln", "%d%n%d", "%f%f",
        "%lf%d", "%lf %f",
    };
    static const char *hi[] = {
        "", " ", "\n", "  \n\t ", "0", "1", "-", "+", "-1", "+1", "12", "123456", "12345", "99999999999999999999", "9223372036854775807",
        "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "18446744073709551615", "18446744073709551616",
        "-18446744073709551615", "-18446744073709551616", "4294967295", "4294967296", "-4294967295", "70000", "300", "255", "256", "65535",
        "65536", "0x", "0x1", "0X1F", "0xg", "0x1g", "-0x1f", "+0x1", "0x0x1", "0b", "0b1", "0B11", "0b101x", "0b2", "0bg", "0b101", "08", "09",
        "010", "017", "00x1", "0 x1", "0o7", "777", "-7", "ff", "ffffffffffffffffffff", "-1", "1 2", "1,2", "1, 2", "1 ,2", "1  x", "12 34",
        "12\n\n34", "5%", "5 %", "%5", " %5", "%", " %", "1e", "1ex", "1e+", "1e+x", "1e5", "1E5", "1e5x", "1e+5", "1e-5", "1e5e5", "1e5.5",
        ".", "-.", ".e1", ".5", "5.", "1.5", "1.5.5", "1.e", "1.e5", "0e", "0e5", "00.5", "0.e", "+-1", "--1", "1,5", "e5", "-e5",
        "inf", "INF", "iNf", "-inf", "+Inf", "infin", "infinit", "infinity", "INFINITY", "InFiNiTy", "infinityx", "infx", "infiz", "infinitz",
        "in", "i", "- inf", "-in", "-i", "nan", "NaN", "nAn", "-nan", "+nan", "nan(12)x", "nan(12)", "nan(", "nan(12", "nan(a_b)", "nan(a b)",
        "nan()", "nan(-)", "nan(0x1f)", "nan(0x7fffff)", "nan(5)", "nan(1x", "nan(1", "nanx", "nanq", "na", "nax", "0x1p", "0x1p3", "0x1p+",
        "0x1p-", "0x1p+1", "0X1P-1", "0x1P5", "0X1p5", "0x1e5", "0x1.e5p0", "0x.8", "0x.8p", "0x.p1", "0x1.8p1", "0x1.8", "0x1.8g", "0x1.", "0xp1",
        "0xx", "0x0", "0x0p", "0x0p1", "-0x", "-0xg", "0x.", "0x.g", "-0x.", "0x.e", "1e0000005", "1e99999", "1e-99999", "0x1p99999", "ab",
        "abc", "abcd", "abcde", "abcdef", "abcdefg", "a\nb", "a\t b", "a b", "a    b", "ab c", "abc def", " ab", "\n\nab cd", "  ", "aab",
        "aaa", "aaaaaaa", "aabb", "a-b", "-ab", "-aa", "aa-", "a-", "a-z", "zxa", "b", "bca", "ba", "]a]b", "bc]", "a]", "a]]", "^]b", "^_`",
        "a^", ".-/", "+,-.", "a\\]", "abc]", "(nil)", "(NIL)", "(nIl)", "(nil", "(ni", "(n", "(", "(nilx)", "(nilx", "(nil)x", "(nil))",
        "( nil)", "(z", "(nz", "-(nil)", "+(nil)", "0x(nil)", "0(nil)", "00x(nil)", "0X(NIL)", "1(nil)", "0xa(nil)", "0x(", "0x(nil", "0x(z",
        "0x0(nil)", "1f", "g", "x", "y", "5x", "5y", "5z", "1a", "1b", "a1", "b1", "a5", "a 1", "a   b1", "x5y", "x5z", "x5", "5   x", "5 y",
        "\xe9", "a\xe9z", "\xe9z", "ab\xe9", "5\xe9", "5\xe8", "\xff\xfe", "\xff\x80" "a", "1\f\r2", "1\v", "\v\fa", "a\vb", "a\rb", "\r1",
        "\t\n 12", "  -12abc", "  \n -1", "5\n\n6", "a\n\nb", "123", "12ab", "0x10", "ffff1", "1 2 3", "5 ", "0 ", "1.5 2.5", "-.5E-2",
        "1,000", "a b c d", "x y",
    };
    for (unsigned i = 0; i < N(hf); i++)
        for (unsigned j = 0; j < N(hi); j++) {
            if (((i * 31u + j * 17u) % 29u) != 0 && j % 37u != 0) continue;
            row(hf[i], hi[j]);
        }
    /* every pair below is always emitted: they pin the corners that the sampled grid above can miss */
    static const char *must[][2] = {
        {"%2x", "0x1"}, {"%2x", "0x"}, {"%2b", "0b"}, {"%2i", "0b"}, {"%2i", "0x"}, {"%3b", "0b"}, {"%1x", "0x1"}, {"%3x", "0x1"}, {"%2b", "0b1"}, {"%3b", "0b1"}, {"%2i", "0x1"}, {"%2i", "0b1"},
        {"%3i", "0b1"}, {"%3i", "-0x1"}, {"%4i", "-0x1"}, {"%2i", "-0"}, {"%2d", "-"}, {"%1d", "-5"}, {"%2o", "07"}, {"%i", "0b2"},
        {"%3p", "(nil)"}, {"%4p", "(nil)"}, {"%5p", "(nil)"}, {"%6p", "(nil)"}, {"%p", "(nil)"}, {"%5p", "(nil"}, {"%1p", "(nil)"},
        {"%4f", "nan(1)"}, {"%5f", "nan(1)"}, {"%6f", "nan(1)"}, {"%7f", "nan(1)"}, {"%3f", "nan(1)"}, {"%f", "nan(-)"}, {"%f", "nan(a-b)"},
        {"%f", "nan(a_b)"}, {"%f", "nan(a b)"}, {"%f", "nan(1"}, {"%f", "nan(1)x"}, {"%2f", "nan"}, {"%3f", "nan"},
        {"%3f", "inf"}, {"%2f", "inf"}, {"%4f", "infinity"}, {"%6f", "infinity"}, {"%7f", "infinity"}, {"%8f", "infinity"},
        {"%0$d%d", "5 6"}, {"%0$d", "5"}, {"%1$d%2$d", "5 6"}, {"%2$d%1$d", "5 6"}, {"%1$d%d", "5 6"},
        {"%2[a]", "aaa"}, {"%1[a]", "aa"}, {"%[a]", "aaa"}, {"%3[a-c]", "abcabc"}, {"%[^b]", "aab"}, {"%2[^b]", "aaab"},
        {"%hp", "0x5"}, {"%hhp", "0x5"}, {"%Lp", "0x5"}, {"%lp", "0x5"}, {"%2p", "0x1f"}, {"%4p", "0x1f"},
        {"%lc", "\x80"}, {"%lc", "\x9f"}, {"%lc", "\xa0"}, {"%lc", "\x7f"}, {"%ls", "a\x90"}, {"%ls", "a\x7f"}, {"%l[^a]", "b\x80"},
        {"%l[^a]", "b\x7f"}, {"%S", "ab\x80"}, {"%C", "\x80"}, {"%3lc", "ab\x85"}, {"%3lc", "ab\x7e"},
        {"%[a-c]", "abcd"}, {"%[a-c-e]", "abcde-"}, {"%[a-]", "a-"}, {"%[-a]", "-a"}, {"%[]a]", "]a"}, {"%[^]a]", "bc]"}, {"%[a-a]", "aa"},
        {"%[b-a]", "ab-"}, {"%[+--]", "+,-."}, {"%[--/]", ".-/"}, {"%[a-\xff]", "b\xe9"}, {"%[\xe9]", "\xe9"},
        {"%hhd", "-129"}, {"%hhd", "128"}, {"%hhu", "-1"}, {"%hhu", "256"}, {"%hd", "32768"}, {"%hu", "-1"}, {"%hu", "65537"},
        {"%d", "2147483648"}, {"%d", "-2147483649"}, {"%u", "4294967296"}, {"%ld", "9223372036854775807"}, {"%ld", "9223372036854775808"},
        {"%ld", "-9223372036854775808"}, {"%ld", "-9223372036854775809"}, {"%lu", "18446744073709551615"}, {"%lu", "18446744073709551616"},
        {"%lu", "-1"}, {"%lu", "-18446744073709551615"}, {"%lu", "-18446744073709551616"}, {"%u", "-4294967295"}, {"%u", "-4294967296"},
        {"%x", "ffffffffffffffff"}, {"%x", "10000000000000000"}, {"%lx", "-1"}, {"%llx", "ffffffffffffffff"}, {"%llx", "10000000000000000"},
        {"%o", "1777777777777777777777"}, {"%o", "2000000000000000000000"}, {"%b", "1111111111111111111111111111111111111111111111111111111111111111"},
        {"%b", "10000000000000000000000000000000000000000000000000000000000000000"},
        {"%n", "x"}, {"%hn", "x"}, {"%hhn", "x"}, {"%ln", "x"}, {"%lln", "x"}, {"%*n", "x"}, {"%d%n", "12"}, {"%d%hhn", "12345678"},
        {"%c%n", "ab"}, {" %n", "  x"}, {"a%n", "a"}, {"%*c%n", "ab"}, {"%*s%n", "ab cd"},
        {"a b", "a   b"}, {"a b", "ab"}, {"a\nb", "a \t b"}, {"a ", "a   "}, {" a", "  a"}, {"%d ", "5   "}, {"%d  x", "5 x"}, {"\t%d", " 5"},
        {"%d%%", "5%"}, {"%d%%", "5 %"}, {"%%", "%"}, {"%%", " %"}, {" %%", " %"}, {"%5%", "%"}, {"%*%", "%"}, {"%h%", "%"},
        {"%f", "1e"}, {"%f", "1e+"}, {"%f", "1ex"}, {"%f", "0x1p"}, {"%f", "0x1p+"}, {"%f", "0x"}, {"%f", "0x."}, {"%f", "0x.e"}, {"%f", "0x.8"},
        {"%f", "0x1.8p1"}, {"%f", "0X1P-1"}, {"%f", "0x1e5"}, {"%f", "1e5e5"}, {"%f", "1.5.5"}, {"%f", ".5."}, {"%f", "..5"}, {"%f", "-.5"},
        {"%f", "-."}, {"%f", "."}, {"%f", ".e1"}, {"%f", "+-1"}, {"%f", "- 1"}, {"%f", "e5"}, {"%f", "1e0000005"}, {"%f", "1e99999"},
        {"%f", "1e-99999"}, {"%f", "0x1p99999"}, {"%f", "00.5"}, {"%f", "0e"}, {"%f", "0.e"}, {"%f", "0.e5"},
        {"%2f", "1e5"}, {"%3f", "1e5"}, {"%4f", "1e10"}, {"%2f", "1.5e"}, {"%4f", "1.5e1"}, {"%3f", "-.5"}, {"%2f", "-.5"}, {"%1f", "-1"},
        {"%4f", "0x1p"}, {"%2f", "0x1"}, {"%3f", "0x1"}, {"%4f", "0x1"},
        {"%s", "a\vb"}, {"%s", "a\fb"}, {"%s", "a\rb"}, {"%s", "a\xa0" "b"}, {"%d", "\v\f\r1"}, {"%s", "\xc2\xa0" "a"},
        {"%5c", "abcde"}, {"%5c", "abcd"}, {"%1c", "ab"}, {"%c%c", "a"}, {"%c", "\n"}, {"%2147483647c", "abc"},
        {"%ms", ""}, {"%d%d", "1"}, {"%d%d", "1 "}, {"%d,%d", "1,2"}, {"%d,%d", "1 ,2"}, {"%d, %d", "1 ,2"}, {"%d ,%d", "1 ,2"},
        {"a%d", "a"}, {"a%d", ""}, {"a%d", "b"}, {"a", ""}, {"a", "b"}, {"%da", "1a"}, {"%da", "1b"},
    };
    for (unsigned i = 0; i < N(must); i++) row(must[i][0], must[i][1]);
    static const char *imods[] = {"", "h", "hh", "l", "ll", "j", "z", "t", "L", "q"};
    static const char *xflags[] = {"", "", "", "", "I", "'", "*", "I*", "*I", "'I"};
    static const char *iconv[] = {"d", "i", "u", "o", "x", "X", "b", "p"};
    static const char *widths[] = {"", "", "", "1", "2", "3", "4", "5", "8"};
    char fmt[64], in[64];
    for (int k = 0; k < 1100; k++) {
        snprintf(fmt, sizeof fmt, "%%%s%s%s%s", pick(xflags, N(xflags)), pick(widths, N(widths)), pick(imods, N(imods)), pick(iconv, N(iconv)));
        rand_str(in, rnd(3) ? "0123456789abcdefxXbB+- " : "0127fxb-+89gG.", 7);
        row(fmt, in);
    }
    static const char *fmods[] = {"", "", "l", "h", "hh", "z", "j", "t"};
    static const char *fconv[] = {"f", "e", "g", "a", "F", "E", "G", "A"};
    for (int k = 0; k < 900; k++) {
        snprintf(fmt, sizeof fmt, "%%%s%s%s%s", pick(xflags, N(xflags)), pick(widths, N(widths)), pick(fmods, N(fmods)), pick(fconv, N(fconv)));
        rand_str(in, rnd(3) ? "0123456789.eE+-" : "0x1pP.aAfF89nNiItTyY()_+- ", 9);
        row(fmt, in);
    }
    static const char *units[] = {"%d", "%i", "%x", "%u", "%f", "%s", "%c", "%2c", "%3s", "%[a-c]", "%[^ ]", "%n", "%*d", "%*s", "%ld", "%hd", "%lf",
                                  " ", "  ", ",", ":", "a", "-", "%%", "\n", " %d", "%o", "%p", "%hhd", "%5d", "%[0-9]", "%*c"};
    for (int k = 0; k < 1700; k++) {
        char *p = fmt;
        *p = 0;
        int n = 1 + (int)rnd(4);
        for (int u = 0; u < n; u++) p += snprintf(p, 24, "%s", pick(units, N(units)));
        rand_str(in, rnd(2) ? "0123456789abc ,:-.+\n" : "12 ab,x:%-.e\t", 12);
        row(fmt, in);
    }
    fprintf(stderr, "%ld rows\n", rows);
    return 0;
}
