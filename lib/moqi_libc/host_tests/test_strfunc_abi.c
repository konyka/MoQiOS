/* test_strfunc_abi.c — the rest of string.h (strstr, memchr, strnlen, strspn, strpbrk, strdup, strtok, strerror, the
 * case-insensitive compares, ...). The functions are compared against the host's glibc over exhaustive small-alphabet
 * inputs (every string up to a length over a three-letter alphabet), plus written-out edge cases. */
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include "../include/errno.h"
#include "../include/string.h"

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

struct erow { int code; const char *text; };
static const struct erow erows[] = {
    {0, "Success"},
    {1, "Operation not permitted"},
    {2, "No such file or directory"},
    {3, "No such process"},
    {4, "Interrupted system call"},
    {5, "Input/output error"},
    {6, "No such device or address"},
    {7, "Argument list too long"},
    {8, "Exec format error"},
    {9, "Bad file descriptor"},
    {10, "No child processes"},
    {11, "Resource temporarily unavailable"},
    {12, "Cannot allocate memory"},
    {13, "Permission denied"},
    {14, "Bad address"},
    {15, "Block device required"},
    {16, "Device or resource busy"},
    {17, "File exists"},
    {18, "Invalid cross-device link"},
    {19, "No such device"},
    {20, "Not a directory"},
    {21, "Is a directory"},
    {22, "Invalid argument"},
    {23, "Too many open files in system"},
    {24, "Too many open files"},
    {25, "Inappropriate ioctl for device"},
    {26, "Text file busy"},
    {27, "File too large"},
    {28, "No space left on device"},
    {29, "Illegal seek"},
    {30, "Read-only file system"},
    {31, "Too many links"},
    {32, "Broken pipe"},
    {33, "Numerical argument out of domain"},
    {34, "Numerical result out of range"},
    {35, "Resource deadlock avoided"},
    {36, "File name too long"},
    {37, "No locks available"},
    {38, "Function not implemented"},
    {39, "Directory not empty"},
    {40, "Too many levels of symbolic links"},
    {41, "Unknown error 41"},
    {42, "No message of desired type"},
    {43, "Identifier removed"},
    {44, "Channel number out of range"},
    {45, "Level 2 not synchronized"},
    {46, "Level 3 halted"},
    {47, "Level 3 reset"},
    {48, "Link number out of range"},
    {49, "Protocol driver not attached"},
    {50, "No CSI structure available"},
    {51, "Level 2 halted"},
    {52, "Invalid exchange"},
    {53, "Invalid request descriptor"},
    {54, "Exchange full"},
    {55, "No anode"},
    {56, "Invalid request code"},
    {57, "Invalid slot"},
    {58, "Unknown error 58"},
    {59, "Bad font file format"},
    {60, "Device not a stream"},
    {61, "No data available"},
    {62, "Timer expired"},
    {63, "Out of streams resources"},
    {64, "Machine is not on the network"},
    {65, "Package not installed"},
    {66, "Object is remote"},
    {67, "Link has been severed"},
    {68, "Advertise error"},
    {69, "Srmount error"},
    {70, "Communication error on send"},
    {71, "Protocol error"},
    {72, "Multihop attempted"},
    {73, "RFS specific error"},
    {74, "Bad message"},
    {75, "Value too large for defined data type"},
    {76, "Name not unique on network"},
    {77, "File descriptor in bad state"},
    {78, "Remote address changed"},
    {79, "Can not access a needed shared library"},
    {80, "Accessing a corrupted shared library"},
    {81, ".lib section in a.out corrupted"},
    {82, "Attempting to link in too many shared libraries"},
    {83, "Cannot exec a shared library directly"},
    {84, "Invalid or incomplete multibyte or wide character"},
    {85, "Interrupted system call should be restarted"},
    {86, "Streams pipe error"},
    {87, "Too many users"},
    {88, "Socket operation on non-socket"},
    {89, "Destination address required"},
    {90, "Message too long"},
    {91, "Protocol wrong type for socket"},
    {92, "Protocol not available"},
    {93, "Protocol not supported"},
    {94, "Socket type not supported"},
    {95, "Operation not supported"},
    {96, "Protocol family not supported"},
    {97, "Address family not supported by protocol"},
    {98, "Address already in use"},
    {99, "Cannot assign requested address"},
    {100, "Network is down"},
    {101, "Network is unreachable"},
    {102, "Network dropped connection on reset"},
    {103, "Software caused connection abort"},
    {104, "Connection reset by peer"},
    {105, "No buffer space available"},
    {106, "Transport endpoint is already connected"},
    {107, "Transport endpoint is not connected"},
    {108, "Cannot send after transport endpoint shutdown"},
    {109, "Too many references: cannot splice"},
    {110, "Connection timed out"},
    {111, "Connection refused"},
    {112, "Host is down"},
    {113, "No route to host"},
    {114, "Operation already in progress"},
    {115, "Operation now in progress"},
    {116, "Stale file handle"},
    {117, "Structure needs cleaning"},
    {118, "Not a XENIX named type file"},
    {119, "No XENIX semaphores available"},
    {120, "Is a named type file"},
    {121, "Remote I/O error"},
    {122, "Disk quota exceeded"},
    {123, "No medium found"},
    {124, "Wrong medium type"},
    {125, "Operation canceled"},
    {126, "Required key not available"},
    {127, "Key has expired"},
    {128, "Key has been revoked"},
    {129, "Key was rejected by service"},
    {130, "Owner died"},
    {131, "State not recoverable"},
    {132, "Operation not possible due to RF-kill"},
    {133, "Memory page has hardware error"},
    {134, "Inappropriate file type or format"},
    {135, "Unknown error 135"},
    {-1, "Unknown error -1"},
    {4096, "Unknown error 4096"},
    {2147483647, "Unknown error 2147483647"},
    {-2147483648, "Unknown error -2147483648"},
};

/* Reference implementations written for the test, deliberately naive. */
static const char *ref_strstr(const char *h, const char *n) {
    size_t hl = 0, nl = 0;
    while (h[hl]) hl++;
    while (n[nl]) nl++;
    if (nl == 0) return h;
    for (size_t i = 0; i + nl <= hl; i++) {
        size_t k = 0;
        while (k < nl && h[i + k] == n[k]) k++;
        if (k == nl) return h + i;
    }
    return (const char *)0;
}
static int ref_lower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

int main(void) {
    /* Every string over {a, b, B} up to length 5 against every one up to length 3, for the searching functions. */
    static const char alpha[] = "abB";
    char hay[8], ndl[8];
    unsigned long total = 0;
    for (unsigned hn = 0; hn <= 5; hn++) {
        unsigned hcount = 1;
        for (unsigned i = 0; i < hn; i++) hcount *= 3;
        for (unsigned hi = 0; hi < hcount; hi++) {
            unsigned x = hi;
            for (unsigned i = 0; i < hn; i++) { hay[i] = alpha[x % 3]; x /= 3; }
            hay[hn] = 0;
            for (unsigned nn = 0; nn <= 3; nn++) {
                unsigned ncount = 1;
                for (unsigned i = 0; i < nn; i++) ncount *= 3;
                for (unsigned ni = 0; ni < ncount; ni++) {
                    unsigned y = ni;
                    for (unsigned i = 0; i < nn; i++) { ndl[i] = alpha[y % 3]; y /= 3; }
                    ndl[nn] = 0;
                    total++;
                    CHECK(strstr(hay, ndl) == ref_strstr(hay, ndl));
                    /* strspn / strcspn / strpbrk against first-principles scans */
                    size_t sp = 0;
                    while (hay[sp]) { int in = 0; for (size_t k = 0; ndl[k]; k++) if (hay[sp] == ndl[k]) in = 1; if (!in) break; sp++; }
                    CHECK(strspn(hay, ndl) == sp);
                    size_t cs = 0;
                    while (hay[cs]) { int in = 0; for (size_t k = 0; ndl[k]; k++) if (hay[cs] == ndl[k]) in = 1; if (in) break; cs++; }
                    CHECK(strcspn(hay, ndl) == cs);
                    CHECK(strpbrk(hay, ndl) == (hay[cs] ? hay + cs : (char *)0));
                    /* case-insensitive compares: sign of the first difference after lower-casing */
                    int want = 0;
                    { size_t k = 0; while (hay[k] && ref_lower((unsigned char)hay[k]) == ref_lower((unsigned char)ndl[k])) k++;
                      want = ref_lower((unsigned char)hay[k]) - ref_lower((unsigned char)ndl[k]); }
                    int got = strcasecmp(hay, ndl);
                    CHECK((want == 0) == (got == 0) && (want < 0) == (got < 0));
                    for (size_t n = 0; n <= 4; n++) {
                        int w = 0;
                        for (size_t k = 0; k < n; k++) {
                            int a = ref_lower((unsigned char)hay[k]), b = ref_lower((unsigned char)ndl[k]);
                            if (a != b) { w = a - b; break; }
                            if (a == 0) break;
                        }
                        int g = strncasecmp(hay, ndl, n);
                        CHECK((w == 0) == (g == 0) && (w < 0) == (g < 0));
                    }
                }
            }
        }
    }
    CHECK(total > 10000);

    /* memchr / memrchr / strnlen over every length and every position. */
    const char *buf = "abcabc";
    for (size_t n = 0; n <= 6; n++) {
        for (int c = 'a'; c <= 'd'; c++) {
            const void *first = (const void *)0, *last = (const void *)0;
            for (size_t i = 0; i < n; i++) if (buf[i] == c) { if (!first) first = buf + i; last = buf + i; }
            CHECK(memchr(buf, c, n) == first);
            CHECK(memrchr(buf, c, n) == last);
        }
    }
    { static const char nul[] = {'a', 0, 'b'}; CHECK(memchr(nul, 'b', 3) == nul + 2); } /* memchr does not stop at NUL */
    CHECK(memchr("abc", 'a' + 256, 3) != (void *)0); /* the byte is taken as an unsigned char */
    { static const char hay2[] = "abca"; CHECK(memrchr(hay2, 'a' + 256, 4) == hay2 + 3); CHECK(memrchr(hay2, 'a' + 512, 3) == hay2); }
    { static const char hay3[] = "xyz"; CHECK(memchr(hay3, 'y' + 256, 3) == hay3 + 1); }
    CHECK(strnlen("hello", 3) == 3 && strnlen("hello", 10) == 5 && strnlen("", 5) == 0 && strnlen("abc", 0) == 0);

    /* strncat always terminates and copies at most n characters. */
    { char d[16]; memset(d, 'Z', sizeof d); d[0] = 'a'; d[1] = 'b'; d[2] = 0;
      CHECK(strncat(d, "cdefg", 3) == d && strcmp(d, "abcde") == 0 && d[6] == 'Z'); /* terminated after exactly n characters */
      memset(d, 'Z', sizeof d); d[0] = 'a'; d[1] = 0;
      CHECK(strncat(d, "xy", 5) == d && d[3] == 0 && strcmp(d, "axy") == 0); /* fewer than n: stops at the source NUL */
      memset(d, 'Z', sizeof d); d[0] = 'a'; d[1] = 0;
      CHECK(strncat(d, "xyz", 0) == d && d[1] == 0 && strcmp(d, "a") == 0); }
    { char d[16] = "ab"; CHECK(strncat(d, "cdefg", 3) == d && strcmp(d, "abcde") == 0);
      char e[16] = "ab"; strncat(e, "c", 5); CHECK(strcmp(e, "abc") == 0);
      char f[16] = "ab"; strncat(f, "xyz", 0); CHECK(strcmp(f, "ab") == 0); }
    /* stpcpy returns a pointer to the terminator. */
    { char d[8]; char *e = stpcpy(d, "abc"); CHECK(e == d + 3 && strcmp(d, "abc") == 0); }

    /* strdup copies including the NUL, strndup at most n characters and always terminates. */
    { char *a = strdup("copy"); CHECK(a && strcmp(a, "copy") == 0); free(a);
      char *b = strndup("copy", 2); CHECK(b && strcmp(b, "co") == 0); free(b);
      char *c = strndup("co", 10); CHECK(c && strcmp(c, "co") == 0); free(c);
      char *d = strdup(""); CHECK(d && d[0] == 0); free(d); }

    /* strtok / strtok_r: leading and repeated delimiters collapse; strtok_r keeps its position in the caller's pointer. */
    { char t[] = "a,b;;c"; char *sv; char *p = strtok_r(t, ",;", &sv);
      CHECK(p && strcmp(p, "a") == 0); p = strtok_r((char *)0, ",;", &sv); CHECK(p && strcmp(p, "b") == 0);
      p = strtok_r((char *)0, ",;", &sv); CHECK(p && strcmp(p, "c") == 0); CHECK(strtok_r((char *)0, ",;", &sv) == (char *)0); }
    { char t[] = "  x  y "; char *p = strtok(t, " "); CHECK(p && strcmp(p, "x") == 0); p = strtok((char *)0, " "); CHECK(p && strcmp(p, "y") == 0);
      CHECK(strtok((char *)0, " ") == (char *)0); }
    { char t[] = ",,,"; CHECK(strtok(t, ",") == (char *)0); }
    { char t[] = ""; CHECK(strtok(t, ",") == (char *)0); }
    { char t[] = "a:b"; char *p = strtok(t, ":"); CHECK(p && strcmp(p, "a") == 0); p = strtok((char *)0, "-"); CHECK(p && strcmp(p, "b") == 0); } /* the delimiter set may change */

    /* The existing functions keep treating bytes as unsigned. */
    CHECK(strcmp("\xff", "a") > 0 && memcmp("\xff", "a", 1) > 0 && strncmp("\xff", "a", 1) > 0);

    /* strerror, glibc's text for 0..135, and "Unknown error N" beyond. */
    for (unsigned i = 0; i < sizeof erows / sizeof erows[0]; i++) {
        const char *got = strerror(erows[i].code);
        if (!got || strcmp(got, erows[i].text) != 0) {
            fprintf(stderr, "strerror(%d): want \"%s\" got \"%s\"\n", erows[i].code, erows[i].text, got ? got : "(null)");
            bad++;
        }
    }
    CHECK(strerror(-1) != (char *)0);
    CHECK(strerror(2) == strerror(2)); /* known codes point at constant text */

    assert(bad == 0);
    return 0;
}
