/* test_errno_abi.c -- the errno constants of include/errno.h against glibc's values on Linux x86-64 (measured with an equivalent program:
 * every name below printed from <errno.h> on glibc 2.43). The kernel returns -errno, so a wrong number here would turn a correct
 * failure into a different one. Each constant must also have a strerror text that is not "Unknown error N". */
/* No host header is included: the host's <errno.h> (pulled in by <string.h> and <stdio.h>) defines the same names, and a value that
 * differs would then show up as a macro-redefinition error from the compiler instead of as a failed CHECK. */
#include "../include/errno.h"

extern int strncmp(const char *, const char *, unsigned long);

extern int fprintf(void *, const char *, ...);
extern int printf(const char *, ...);
extern void *stderr;

/* The host's strerror is not the library's: the library's is compiled as moqi_strerror (see run_tests.sh). */
extern char *moqi_strerror(int);

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

#define E(name, value) CHECK((name) == (value)); CHECK(strncmp(moqi_strerror(name), "Unknown error", 13) != 0)

int main(void) {
    E(EPERM, 1); E(ENOENT, 2); E(ESRCH, 3); E(EINTR, 4); E(EIO, 5); E(ENXIO, 6); E(E2BIG, 7); E(ENOEXEC, 8); E(EBADF, 9);
    E(ECHILD, 10); E(EAGAIN, 11); E(ENOMEM, 12); E(EACCES, 13); E(EFAULT, 14); E(ENOTBLK, 15); E(EBUSY, 16); E(EEXIST, 17);
    E(EXDEV, 18); E(ENODEV, 19); E(ENOTDIR, 20); E(EISDIR, 21); E(EINVAL, 22); E(ENFILE, 23); E(EMFILE, 24); E(ENOTTY, 25);
    E(ETXTBSY, 26); E(EFBIG, 27); E(ENOSPC, 28); E(ESPIPE, 29); E(EROFS, 30); E(EMLINK, 31); E(EPIPE, 32); E(EDOM, 33);
    E(ERANGE, 34); E(EDEADLK, 35); E(ENAMETOOLONG, 36); E(ENOLCK, 37); E(ENOSYS, 38); E(ENOTEMPTY, 39); E(ELOOP, 40);
    E(ENOMSG, 42); E(EIDRM, 43); E(ENOSTR, 60); E(ENODATA, 61); E(ETIME, 62); E(ENOSR, 63); E(ENOLINK, 67); E(EPROTO, 71);
    E(EBADMSG, 74); E(EOVERFLOW, 75); E(EILSEQ, 84); E(EUSERS, 87); E(ENOTSOCK, 88); E(EDESTADDRREQ, 89); E(EMSGSIZE, 90);
    E(EPROTOTYPE, 91); E(ENOPROTOOPT, 92); E(EPROTONOSUPPORT, 93); E(ESOCKTNOSUPPORT, 94); E(EOPNOTSUPP, 95);
    E(EPFNOSUPPORT, 96); E(EAFNOSUPPORT, 97); E(EADDRINUSE, 98); E(EADDRNOTAVAIL, 99); E(ENETDOWN, 100); E(ENETUNREACH, 101);
    E(ENETRESET, 102); E(ECONNABORTED, 103); E(ECONNRESET, 104); E(ENOBUFS, 105); E(EISCONN, 106); E(ENOTCONN, 107);
    E(ESHUTDOWN, 108); E(ETOOMANYREFS, 109); E(ETIMEDOUT, 110); E(ECONNREFUSED, 111); E(EHOSTDOWN, 112); E(EHOSTUNREACH, 113);
    E(EALREADY, 114); E(EINPROGRESS, 115); E(ESTALE, 116); E(EDQUOT, 122); E(ECANCELED, 125); E(EOWNERDEAD, 130);
    E(ENOTRECOVERABLE, 131);
    /* aliases: the same number as their primary name */
    CHECK(EWOULDBLOCK == EAGAIN && EWOULDBLOCK == 11);
    CHECK(ENOTSUP == EOPNOTSUPP && ENOTSUP == 95);
    CHECK(EDEADLOCK == EDEADLK && EDEADLOCK == 35);

    if (bad) { fprintf(stderr, "%d check(s) failed\n", bad); return 1; }
    printf("test_errno_abi: ok\n");
    return 0;
}
