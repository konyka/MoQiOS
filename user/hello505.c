/* hello505: a name found in /etc/hosts comes back canonicalised, as glibc does. A creates /etc/hosts; B gethostbyname of an alias
 * gives the line's first name as h_name and the other names as h_aliases; C the canonical name asked in another case gives the same;
 * D a line with one name has no aliases; E getaddrinfo with AI_CANONNAME gives the first name; F a literal keeps itself as h_name;
 * G cleanup. Measured with -DHOST in a mount namespace with /etc/hosts bind-mounted to a scratch file. */
#ifdef HOST
#define _GNU_SOURCE
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define HOSTS_PATH (getenv("H505") ? getenv("H505") : "/etc/hosts")
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
    print(ok ? "hello505:   ok   " : "hello505:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] = "127.0.0.1 localhost\n10.5.0.5\tCanon505.example  alias505\tbis505 # note\n10.5.0.6 solo505\n";
/* "name|alias1|alias2" of a lookup, or "NULL". */
static void describe(const char *q, char *out, size_t cap) {
    struct hostent *h = gethostbyname(q);
    if (!h) { snprintf(out, cap, "NULL"); return; }
    size_t n = (size_t)snprintf(out, cap, "%s", h->h_name);
    for (char **a = h->h_aliases; a && *a && n < cap; a++) n += (size_t)snprintf(out + n, cap - n, "|%s", *a);
}
int main(void) {
    print("hello505: canonical names from /etc/hosts\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello505:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long w = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    snprintf(msg, sizeof msg, "A: open %d, write %ld (>=0 %d)", fd, w, (int)(sizeof hosts - 1));
    check(fd >= 0 && w == (long)(sizeof hosts - 1), msg);
    char b[120], c[120], d[120], f[120];
    describe("ALIAS505", b, sizeof b);
    snprintf(msg, sizeof msg, "B: alias -> %s (Canon505.example|alias505|bis505)", b);
    check(strcmp(b, "Canon505.example|alias505|bis505") == 0, msg);
    describe("canon505.EXAMPLE", c, sizeof c);
    snprintf(msg, sizeof msg, "C: canonical in another case -> %s (Canon505.example|alias505|bis505)", c);
    check(strcmp(c, "Canon505.example|alias505|bis505") == 0, msg);
    describe("SOLO505", d, sizeof d);
    snprintf(msg, sizeof msg, "D: one-name line -> %s (solo505)", d);
    check(strcmp(d, "solo505") == 0, msg);
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = 2;
    hints.ai_socktype = 1;
    hints.ai_flags = AI_CANONNAME;
    int g = getaddrinfo("bis505", 0, &hints, &res);
    snprintf(msg, sizeof msg, "E: getaddrinfo AI_CANONNAME %d '%s' (0 Canon505.example)", g, g == 0 && res && res->ai_canonname ? res->ai_canonname : "-");
    check(g == 0 && res && res->ai_canonname && strcmp(res->ai_canonname, "Canon505.example") == 0, msg);
    if (g == 0) freeaddrinfo(res);
    describe("10.5.0.5", f, sizeof f);
    snprintf(msg, sizeof msg, "F: literal -> %s (10.5.0.5)", f);
    check(strcmp(f, "10.5.0.5") == 0, msg);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(HOSTS_PATH);
#endif
    snprintf(msg, sizeof msg, "G: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello505: FAIL\n" : "hello505: PASS\n");
    return failures ? 1 : 0;
}
