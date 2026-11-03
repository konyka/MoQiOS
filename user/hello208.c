/* hello208: the printf family in the freestanding user build: width, precision, flags, length modifiers, %n, %m, wide
 * characters, asprintf, dprintf into a pipe, and output longer than the 512-byte staging chunk. The exhaustive comparison
 * against glibc (2400+ rows) is on the host. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello208:   ok   " : "hello208:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int is(const char *got, const char *want) { return strcmp(got, want) == 0; }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello208: libc printf family\n");

    char b[128];
    snprintf(b, sizeof b, "[%5d][%-5d][%05d][%+d][% d]", 42, 42, 42, 42, 42);
    check(is(b, "[   42][42   ][00042][+42][ 42]"), "A: width, left, zero, plus and space flags");
    snprintf(b, sizeof b, "[%.5d][%8.3d][%-8.3d][%.0d]", 42, 7, 7, 0);
    check(is(b, "[00042][     007][007     ][]"), "A: precision on integers, and %.0d of 0 prints nothing");
    snprintf(b, sizeof b, "[%x][%#x][%#X][%#o][%o][%#b]", 255, 255, 255, 8, 8, 5);
    check(is(b, "[ff][0xff][0XFF][010][10][0b101]"), "A: hex, octal and binary with the alternate form");
    snprintf(b, sizeof b, "[%10s][%-10s][%.3s][%10.3s][%s]", "abc", "abc", "abcdef", "abcdef", (char *)0);
    check(is(b, "[       abc][abc       ][abc][       abc][(null)]"), "A: string width and precision, and a NULL string");
    snprintf(b, sizeof b, "[%*d][%-*d][%.*d][%*.*d]", 6, 42, 6, 42, 4, 42, 8, 4, 42);
    check(is(b, "[    42][42    ][0042][    0042]"), "A: width and precision taken from the arguments");
    snprintf(b, sizeof b, "[%*d][%.*d]", -6, 42, -4, 42);
    check(is(b, "[42    ][42]"), "A: a negative * width is left alignment, a negative * precision is none");

    snprintf(b, sizeof b, "%zu %zd %jd %td %hhd %hd %hhu %hu %lld %llu", (size_t)7, (long)-7, (long)-8, (long)-9, 300, 70000, 300, 70000, -1LL, 5ULL);
    check(is(b, "7 -7 -8 -9 44 4464 44 4464 -1 5"), "B: z j t hh h ll length modifiers, including truncation to a byte and a short");
    snprintf(b, sizeof b, "%lu %lx %lo", ~0UL, ~0UL, ~0UL);
    check(is(b, "18446744073709551615 ffffffffffffffff 1777777777777777777777"), "B: 64-bit values in all bases");
    snprintf(b, sizeof b, "%d %u", (-2147483647 - 1), 4294967295u);
    check(is(b, "-2147483648 4294967295"), "B: the int extremes");

    snprintf(b, sizeof b, "[%p][%20p][%-20p][%p]", (void *)0x1f2e, (void *)0x1f2e, (void *)0x1f2e, (void *)0);
    check(is(b, "[0x1f2e][              0x1f2e][0x1f2e              ][(nil)]"), "C: %p with width, left alignment and NULL");
    snprintf(b, sizeof b, "[%c][%5c][%-5c]", 'x', 'x', 'x');
    check(is(b, "[x][    x][x    ]"), "C: %c with width");

    int n1 = -1;
    short n2 = -1;
    snprintf(b, sizeof b, "abcdef%nxyz%hn", &n1, &n2);
    check(is(b, "abcdefxyz") && n1 == 6 && n2 == 9, "D: %n stores the count so far, with h narrowing");
    int r = snprintf(b, 5, "%d%s", 123456, "abc");
    check(r == 9 && is(b, "1234"), "D: a truncated snprintf returns the full length and ends with a NUL");
    check(snprintf((char *)0, 0, "%5d|", 1) == 6, "D: snprintf(NULL, 0, ...) counts");

    errno = 2;
    snprintf(b, sizeof b, "%m|%-14m|", errno);
    check(is(b, "No such file or directory|No such file or directory|"), "E: %m is strerror(errno)");
    errno = 0;
    check(snprintf(b, sizeof b, "ab%") == -1 && errno == EINVAL, "E: a format that ends inside a conversion is -1 and EINVAL");
    errno = 0;
    check(snprintf(b, sizeof b, "%lc", 233) == -1 && errno == EILSEQ, "E: a non-ASCII wide character is -1 and EILSEQ");
    snprintf(b, sizeof b, "[%lc][%ls][%5.2ls]", 65, (const int *)(const int[]){'h', 'i', 0}, (const int *)(const int[]){'a', 'b', 'c', 0});
    check(is(b, "[A][hi][   ab]"), "E: ASCII wide characters and strings");
    snprintf(b, sizeof b, "[%y][%5.3y][%#+-5.3y]", 1, 1, 1);
    check(is(b, "[%y][%5.3y][%#+-5.3y]"), "E: an unknown conversion is written back as it was meant to be read");

    char *s = (char *)0;
    int an = asprintf(&s, "%s-%05d-%lx", "id", 42, 255UL);
    check(an == 11 && s && is(s, "id-00042-ff"), "F: asprintf allocates exactly the result");
    free(s);
    char big[1100];
    memset(big, 'k', sizeof big - 1);
    big[sizeof big - 1] = 0;
    an = asprintf(&s, "<%s>", big);
    check(an == 1101 && s && s[0] == '<' && s[1100] == '>' && strlen(s) == 1101, "F: asprintf of a result longer than the staging chunk");
    free(s);

    int p[2];
    check(pipe(p) == 0, "G: a pipe for dprintf");
    char rd[2400];
    int dn = dprintf(p[1], "<%s>", big);
    long got = 0;
    while (got < 1101) {
        long k = read(p[0], rd + got, (size_t)(1101 - got));
        if (k <= 0) break;
        got += k;
    }
    check(dn == 1101 && got == 1101 && rd[0] == '<' && rd[1100] == '>' && rd[600] == 'k', "G: dprintf writes all 1101 bytes of a long result to the descriptor");
    errno = 0;
    check(dprintf(-1, "abc") == -1 && errno == EBADF, "G: dprintf to a bad descriptor fails with the kernel's error");
    errno = 0;
    check(dprintf(p[1], "x%") == -1 && errno == EINVAL, "G: and a bad format writes nothing");
    close(p[0]);
    close(p[1]);

    int pn = printf("hello208: printf %s %5d|%-4s|%lu\n", "ok", 42, "ab", 123456789UL);
    check(pn == 41, "H: printf returns the length");
    check(puts("hello208: puts line") == 20, "H: puts returns length plus one");
    check(putchar('\n') == 10, "H: putchar returns the byte");

    print(failures == 0 ? "hello208: PASS\n" : "hello208: FAIL\n");
    return failures;
}
