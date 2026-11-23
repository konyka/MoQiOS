/* hello508: gethostbyname2 and multi-address /etc/hosts answers (glibc semantics, measured). A creates /etc/hosts with two IPv4 and
 * two IPv6 lines for one name; B gethostbyname lists both IPv4 addresses in file order; C gethostbyname2(AF_INET6) lists both IPv6
 * addresses, 16 bytes each; D gethostbyname2(AF_INET6) of an IPv6 literal answers it, of an IPv4 literal is HOST_NOT_FOUND;
 * E gethostbyname2(AF_INET) of an IPv6 literal is HOST_NOT_FOUND, an unknown name under AF_INET6 is HOST_NOT_FOUND and another
 * family is NO_DATA; F cleanup. Measured with -DHOST in a mount namespace with /etc/hosts bind-mounted to a scratch file. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define HOSTS_PATH (getenv("H508") ? getenv("H508") : "/etc/hosts")
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define HOSTS_PATH "/etc/hosts"
#endif
static int failures;
static char msg[360];
static void check(int ok, const char *w) {
    print(ok ? "hello508:   ok   " : "hello508:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] = "2001:db8::6 dup508\n10.5.0.6 dup508\n2001:db8::7 dup508\n10.5.0.7 dup508\n";
/* "type/len:last-byte,last-byte..." of a lookup, or "NULL/h_errno". */
static void describe(struct hostent *h, char *out, size_t cap) {
    if (!h) { snprintf(out, cap, "NULL/%d", h_errno); return; }
    size_t n = (size_t)snprintf(out, cap, "%d/%d:", h->h_addrtype, h->h_length);
    for (char **a = h->h_addr_list; a && *a && n < cap; a++)
        n += (size_t)snprintf(out + n, cap - n, "%u,", (unsigned)(unsigned char)(*a)[h->h_length - 1]);
}
int main(void) {
    print("hello508: gethostbyname2 and multi-address /etc/hosts\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello508:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long w = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    snprintf(msg, sizeof msg, "A: open %d, write %ld (>=0 %d)", fd, w, (int)(sizeof hosts - 1));
    check(fd >= 0 && w == (long)(sizeof hosts - 1), msg);
    char b[80], c[80], d1[80], d2[80], e1[80], e2[80], e3[80];
    describe(gethostbyname("dup508"), b, sizeof b);
    snprintf(msg, sizeof msg, "B: gethostbyname %s (2/4:6,7,)", b);
    check(strcmp(b, "2/4:6,7,") == 0, msg);
    describe(gethostbyname2("DUP508", AF_INET6), c, sizeof c);
    snprintf(msg, sizeof msg, "C: gethostbyname2 AF_INET6 %s (10/16:6,7,)", c);
    check(strcmp(c, "10/16:6,7,") == 0, msg);
    describe(gethostbyname2("2001:db8::9", AF_INET6), d1, sizeof d1);
    describe(gethostbyname2("10.1.1.1", AF_INET6), d2, sizeof d2);
    snprintf(msg, sizeof msg, "D: IPv6 literal %s, IPv4 literal under AF_INET6 %s (10/16:9, NULL/1)", d1, d2);
    check(strcmp(d1, "10/16:9,") == 0 && strcmp(d2, "NULL/1") == 0, msg);
    describe(gethostbyname2("2001:db8::9", AF_INET), e1, sizeof e1);
    describe(gethostbyname2("nosuch508.invalid", AF_INET6), e2, sizeof e2);
    describe(gethostbyname2("dup508", 1), e3, sizeof e3);
    snprintf(msg, sizeof msg, "E: IPv6 literal under AF_INET %s, unknown %s, family 1 %s (NULL/1 NULL/1 NULL/4)", e1, e2, e3);
    check(strcmp(e1, "NULL/1") == 0 && strcmp(e2, "NULL/1") == 0 && strcmp(e3, "NULL/4") == 0, msg);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(HOSTS_PATH);
#endif
    snprintf(msg, sizeof msg, "F: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello508: FAIL\n" : "hello508: PASS\n");
    return failures ? 1 : 0;
}
