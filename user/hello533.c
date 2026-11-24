/* hello533: getaddrinfo when the files source decides without an /etc/hosts (glibc 2.44, "hosts: files"). The module leaves
 * h_errno alone, so the result follows the h_errno the call started with: A AF_INET (EAI_NODATA unless TRY_AGAIN or
 * NETDB_INTERNAL); B AF_INET with AI_CANONNAME and AF_INET6 (EAI_NONAME unless NO_DATA, TRY_AGAIN or NETDB_INTERNAL);
 * C AF_UNSPEC is EAI_NODATA; D errno is ENOENT; E an empty /etc/hosts is EAI_NONAME; F cleanup. Measured with -DHOST through
 * glibc in `unshare -r -m -n` with a tmpfs on /etc, so both builds create and remove the same files. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello533:   ok   " : "hello533:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int write_file(const char *path, const char *text) {
    int fd = (int)open(path, 0x041 | 0x200, 0644);
    if (fd < 0) return -1;
    long w = (long)write(fd, text, strlen(text));
    close(fd);
    return w == (long)strlen(text) ? 0 : -1;
}
static int last_errno;
static int gai(int h0, int family, int flags) {
    struct addrinfo h, *r = 0;
    memset(&h, 0, sizeof h);
    h.ai_family = family;
    h.ai_flags = flags;
    h_errno = h0;
    errno = 0;
    int g = getaddrinfo("nosuch533.test", 0, &h, &r);
    last_errno = errno;
    if (g == 0) freeaddrinfo(r);
    return g;
}
/* The results for h_errno 0, HOST_NOT_FOUND, TRY_AGAIN, NO_DATA and NETDB_INTERNAL, as one string. */
static void row(char *out, size_t cap, int family, int flags) {
    snprintf(out, cap, "%d %d %d %d %d", gai(0, family, flags), gai(HOST_NOT_FOUND, family, flags), gai(TRY_AGAIN, family, flags),
             gai(NO_DATA, family, flags), gai(NETDB_INTERNAL, family, flags));
}
int main(void) {
    print("hello533: getaddrinfo without /etc/hosts\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    unlink("/etc/hosts");
    int wn = write_file("/etc/nsswitch.conf", "hosts: files\n");
    char got[120], want[120];

    row(got, sizeof got, AF_INET, 0);
    snprintf(want, sizeof want, "%d %d %d %d %d", EAI_NODATA, EAI_NODATA, EAI_AGAIN, EAI_NODATA, EAI_SYSTEM);
    snprintf(msg, sizeof msg, "A: AF_INET (nsswitch %d): '%s' ('%s')", wn, got, want);
    check(wn == 0 && strcmp(got, want) == 0, msg);

    char got6[120];
    row(got, sizeof got, AF_INET, AI_CANONNAME);
    row(got6, sizeof got6, AF_INET6, 0);
    snprintf(want, sizeof want, "%d %d %d %d %d", EAI_NONAME, EAI_NONAME, EAI_AGAIN, EAI_NODATA, EAI_SYSTEM);
    snprintf(msg, sizeof msg, "B: AF_INET+AI_CANONNAME '%s', AF_INET6 '%s' ('%s' both)", got, got6, want);
    check(strcmp(got, want) == 0 && strcmp(got6, want) == 0, msg);

    row(got, sizeof got, AF_UNSPEC, 0);
    snprintf(want, sizeof want, "%d %d %d %d %d", EAI_NODATA, EAI_NODATA, EAI_NODATA, EAI_NODATA, EAI_NODATA);
    snprintf(msg, sizeof msg, "C: AF_UNSPEC '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    int g = gai(0, AF_INET6, 0);
    snprintf(msg, sizeof msg, "D: errno after AF_INET6 %d: %d (%d)", g, last_errno, ENOENT);
    check(last_errno == ENOENT, msg);

    int wh = write_file("/etc/hosts", "");
    int e1 = gai(TRY_AGAIN, AF_INET, 0), e2 = gai(NO_DATA, AF_INET6, 0);
    snprintf(msg, sizeof msg, "E: empty /etc/hosts (%d): AF_INET %d, AF_INET6 %d (%d %d)", wh, e1, e2, EAI_NONAME, EAI_NONAME);
    check(wh == 0 && e1 == EAI_NONAME && e2 == EAI_NONAME, msg);

    long u1 = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf");
    snprintf(msg, sizeof msg, "F: unlink %ld %ld (0 0)", u1, u2);
    check(u1 == 0 && u2 == 0, msg);
    print(failures ? "hello533: FAIL\n" : "hello533: PASS\n");
    return failures ? 1 : 0;
}
