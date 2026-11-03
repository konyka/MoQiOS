/* hello204: the strtol family, rand/srand, abs/div, strerror and the rest of string.h in the freestanding user build.
 * The exhaustive comparison against glibc is on the host (lib/moqi_libc/host_tests holds the measured tables); this runs
 * the same code on the target, and checks that malloc-backed strdup works against the real heap. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello204:   ok   " : "hello204:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello204: libc strtol / rand / string functions\n");

    char *e;
    errno = 0;
    check(strtol("  -123abc", &e, 10) == -123 && *e == 'a' && errno == 0, "A: strtol skips space, takes a sign, stops at the first non-digit");
    check(strtol("0x1f", &e, 0) == 31 && *e == '\0', "A: base 0 reads a 0x prefix");
    check(strtol("017", &e, 0) == 15, "A: and a leading 0 as octal");
    check(strtol("0b101", &e, 0) == 5, "A: and 0b as binary (glibc 2.38+)");
    check(strtol("0x", &e, 16) == 0 && e[0] == 'x', "A: a bare 0x is the number 0 with the end pointer after the 0");
    check(strtol("zz", &e, 36) == 1295, "A: base 36 reads letters");
    errno = 0;
    check(strtol("9223372036854775808", &e, 10) == 9223372036854775807L && errno == ERANGE, "A: overflow is LONG_MAX / ERANGE");
    errno = 0;
    check(strtol("-9223372036854775809", &e, 10) == (-9223372036854775807L - 1) && errno == ERANGE, "A: and underflow is LONG_MIN / ERANGE");
    errno = 0;
    check(strtol("-9223372036854775808", &e, 10) == (-9223372036854775807L - 1) && errno == 0, "A: LONG_MIN itself is not an error");
    errno = 0;
    char *sentinel = (char *)0x1234;
    e = sentinel;
    check(strtol("10", &e, 37) == 0 && errno == EINVAL && e == sentinel, "A: a base of 37 is EINVAL and leaves the end pointer alone");
    check(strtoul("-1", &e, 10) == 0xFFFFFFFFFFFFFFFFUL, "A: strtoul accepts a minus sign and negates");
    errno = 0;
    check(strtoul("18446744073709551616", &e, 10) == 0xFFFFFFFFFFFFFFFFUL && errno == ERANGE, "A: and still reports a magnitude that is too large");
    check(strtoll("-42", &e, 10) == -42 && strtoull("42", &e, 10) == 42, "A: the ll forms");
    check(atol("123abc") == 123 && atoll("-9") == -9 && atoi("77") == 77, "A: atol / atoll / atoi");

    srand(1);
    int r0 = rand(), r1 = rand(), r2 = rand();
    check(r0 == 1804289383 && r1 == 846930886 && r2 == 1681692777, "B: rand with seed 1 gives glibc's sequence");
    srand(42);
    check(rand() == 71876166, "B: and with seed 42");
    srand(1);
    check(rand() == r0, "B: reseeding restarts the sequence");
    srand(0);
    check(rand() == 1804289383, "B: seed 0 is seed 1");
    srand(1);
    unsigned long long sum = 0;
    for (int i = 0; i < 100000; i++) sum += (unsigned)rand();
    check(sum == 107345864261546ULL, "B: the sum of the first 100000 outputs matches glibc");

    check(abs(-5) == 5 && labs(-7L) == 7 && llabs(-9LL) == 9, "C: abs / labs / llabs");
    div_t d = div(-7, 2);
    check(d.quot == -3 && d.rem == -1, "C: div truncates toward zero");
    lldiv_t q = lldiv(7LL, -2LL);
    check(q.quot == -3 && q.rem == 1, "C: lldiv");

    check(strstr("hello world", "wor") != (char *)0 && strstr("hello", "xyz") == (char *)0 && strstr("hello", "") != (char *)0, "D: strstr");
    check(memchr("hello", 'l', 5) != (void *)0 && memrchr("hello", 'l', 5) == (void *)((char *)memchr("hello", 'l', 5) + 1), "D: memchr / memrchr");
    check(strnlen("hello", 3) == 3 && strspn("aabbcc", "ab") == 4 && strcspn("hello", "lo") == 2, "D: strnlen / strspn / strcspn");
    check(strcasecmp("HeLLo", "hello") == 0 && strncasecmp("HELlo", "helP", 3) == 0 && strncasecmp("HELlo", "helP", 4) < 0, "D: the case-insensitive compares");
    char buf[32];
    strcpy(buf, "ab");
    check(strncat(buf, "cdefg", 3) == buf && strcmp(buf, "abcde") == 0, "D: strncat");
    char *dup = strdup("a heap copy");
    check(dup != (char *)0 && strcmp(dup, "a heap copy") == 0, "D: strdup copies into the heap");
    char *nd = strndup("truncated", 5);
    check(nd != (char *)0 && strcmp(nd, "trunc") == 0, "D: strndup stops at n");
    free(dup);
    free(nd);
    char text[] = "a,b;;c";
    char *save = (char *)0;
    char *tok = strtok_r(text, ",;", &save);
    int count = 0;
    while (tok) { count++; tok = strtok_r((char *)0, ",;", &save); }
    check(count == 3, "D: strtok_r splits on any delimiter and collapses repeats");

    check(strcmp(strerror(2), "No such file or directory") == 0 && strcmp(strerror(12), "Cannot allocate memory") == 0, "E: strerror for common errno values");
    check(strcmp(strerror(0), "Success") == 0 && strcmp(strerror(110), "Connection timed out") == 0, "E: and for 0 and ETIMEDOUT");
    check(strcmp(strerror(999), "Unknown error 999") == 0 && strcmp(strerror(-1), "Unknown error -1") == 0, "E: unknown codes are 'Unknown error N'");

    print(failures == 0 ? "hello204: PASS\n" : "hello204: FAIL\n");
    return failures;
}
