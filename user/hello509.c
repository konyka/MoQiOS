/* hello509: gethostbyaddr reverse lookups in /etc/hosts (glibc semantics, measured). A creates the file; B an IPv4 address
 * returns the first matching line's canonical name and aliases; C IPv6 does the same; D a mapped IPv6 address uses the IPv4 line
 * but keeps its original 16-byte address; E loopback names resolve; F unknown addresses are HOST_NOT_FOUND; G bad families and
 * short lengths are NETDB_INTERNAL/EAFNOSUPPORT while long lengths are TRY_AGAIN; H AF_UNSPEC selects a family by length;
 * I cleanup. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define HOSTS_PATH (getenv("H509") ? getenv("H509") : "/etc/hosts")
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define HOSTS_PATH "/etc/hosts"
#endif
static int failures;
static char msg[420];
static void check(int ok, const char *w) {
    print(ok ? "hello509:   ok   " : "hello509:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] =
    "127.0.0.1 localhost\n::1 localhost6 ip6-localhost\n"
    "10.5.0.9 First509.example alias509 other509\n10.5.0.9 second509\n"
    "2001:db8::9 Six509.example s509\n10.5.0.6 Four509 f509\n";
static const unsigned char v4[4] = {10, 5, 0, 9};
static const unsigned char v6[16] = {0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9};
static const unsigned char mapped[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 10, 5, 0, 6};
static const unsigned char loop4[4] = {127, 0, 0, 1};
static const unsigned char loop6[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
static void bad(const void *addr, unsigned int len, int family, char *out, size_t cap) {
    errno = 0;
    h_errno = 0;
    struct hostent *h = gethostbyaddr(addr, len, family);
    snprintf(out, cap, "%s/%d/%d", h ? "NONNULL" : "NULL", h_errno, errno);
}
int main(void) {
    print("hello509: gethostbyaddr from /etc/hosts\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello509:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long w = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    snprintf(msg, sizeof msg, "A: open %d, write %ld (>=0 %d)", fd, w, (int)(sizeof hosts - 1));
    check(fd >= 0 && w == (long)(sizeof hosts - 1), msg);

    struct hostent *h = gethostbyaddr(v4, 4, AF_INET);
    int b = h && strcmp(h->h_name, "First509.example") == 0 && h->h_addrtype == AF_INET && h->h_length == 4 &&
            h->h_aliases[0] && strcmp(h->h_aliases[0], "alias509") == 0 && h->h_aliases[1] &&
            strcmp(h->h_aliases[1], "other509") == 0 && !h->h_aliases[2] && h->h_addr_list[0] &&
            memcmp(h->h_addr_list[0], v4, 4) == 0 && !h->h_addr_list[1] && h_errno == 0;
    snprintf(msg, sizeof msg, "B: IPv4 %s, alias %s/%s, type/len %d/%d (First509.example alias509/other509 2/4)",
             h ? h->h_name : "NULL", h && h->h_aliases[0] ? h->h_aliases[0] : "NULL",
             h && h->h_aliases[1] ? h->h_aliases[1] : "NULL", h ? h->h_addrtype : -1, h ? h->h_length : -1);
    check(b, msg);

    h = gethostbyaddr(v6, 16, AF_INET6);
    int c = h && strcmp(h->h_name, "Six509.example") == 0 && h->h_addrtype == AF_INET6 && h->h_length == 16 &&
            h->h_aliases[0] && strcmp(h->h_aliases[0], "s509") == 0 && !h->h_aliases[1] && h->h_addr_list[0] &&
            memcmp(h->h_addr_list[0], v6, 16) == 0 && !h->h_addr_list[1];
    snprintf(msg, sizeof msg, "C: IPv6 %s, alias %s, type/len %d/%d (Six509.example s509 10/16)",
             h ? h->h_name : "NULL", h && h->h_aliases[0] ? h->h_aliases[0] : "NULL",
             h ? h->h_addrtype : -1, h ? h->h_length : -1);
    check(c, msg);

    h = gethostbyaddr(mapped, 16, AF_INET6);
    int d = h && strcmp(h->h_name, "Four509") == 0 && h->h_addrtype == AF_INET6 && h->h_length == 16 &&
            h->h_aliases[0] && strcmp(h->h_aliases[0], "f509") == 0 && !h->h_aliases[1] &&
            h->h_addr_list[0] && memcmp(h->h_addr_list[0], mapped, 16) == 0 && !h->h_addr_list[1];
    snprintf(msg, sizeof msg, "D: mapped %s, alias %s, type/len %d/%d (Four509 f509 10/16)",
             h ? h->h_name : "NULL", h && h->h_aliases[0] ? h->h_aliases[0] : "NULL",
             h ? h->h_addrtype : -1, h ? h->h_length : -1);
    check(d, msg);

    h = gethostbyaddr(loop4, 4, AF_INET);
    int e1 = h && strcmp(h->h_name, "localhost") == 0;
    h = gethostbyaddr(loop6, 16, AF_INET6);
    int e2 = h && strcmp(h->h_name, "localhost6") == 0 && h->h_aliases[0] && strcmp(h->h_aliases[0], "ip6-localhost") == 0;
    snprintf(msg, sizeof msg, "E: loopback IPv4 %d, IPv6 %d (1 1)", e1, e2);
    check(e1 && e2, msg);

    unsigned char unknown4[4] = {10, 5, 0, 99};
    unsigned char unknown6[16] = {0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 99};
    char f1[48], f2[48];
    bad(unknown4, 4, AF_INET, f1, sizeof f1);
    bad(unknown6, 16, AF_INET6, f2, sizeof f2);
    snprintf(msg, sizeof msg, "F: unknown IPv4 %s, IPv6 %s (NULL/1/0 twice)", f1, f2);
    check(strcmp(f1, "NULL/1/0") == 0 && strcmp(f2, "NULL/1/0") == 0, msg);

    char g1[48], g2[48], g3[48], g4[48], g5[48];
    bad(v4, 3, AF_INET, g1, sizeof g1);
    bad(v4, 5, AF_INET, g2, sizeof g2);
    bad(v6, 4, AF_INET6, g3, sizeof g3);
    bad(v6, 17, AF_INET6, g4, sizeof g4);
    bad(v4, 4, 1, g5, sizeof g5);
    snprintf(msg, sizeof msg, "G: short4 %s, long4 %s, short6 %s, long6 %s, family1 %s", g1, g2, g3, g4, g5);
    check(strcmp(g1, "NULL/-1/97") == 0 && strcmp(g2, "NULL/2/0") == 0 && strcmp(g3, "NULL/-1/97") == 0 &&
          strcmp(g4, "NULL/2/0") == 0 && strcmp(g5, "NULL/-1/97") == 0, msg);

    h = gethostbyaddr(v4, 4, AF_UNSPEC);
    int h1 = h && h->h_addrtype == AF_INET && strcmp(h->h_name, "First509.example") == 0;
    h = gethostbyaddr(v6, 16, AF_UNSPEC);
    int h2 = h && h->h_addrtype == AF_INET6 && strcmp(h->h_name, "Six509.example") == 0;
    char h3[48];
    unsigned char ambiguous[16] = {10, 5, 0, 9};
    bad(ambiguous, 16, AF_UNSPEC, h3, sizeof h3);
    snprintf(msg, sizeof msg, "H: AF_UNSPEC IPv4 %d, IPv6 %d, ambiguous %s (1 1 NULL/-1/97)", h1, h2, h3);
    check(h1 && h2 && strcmp(h3, "NULL/-1/97") == 0, msg);
#ifdef HOST
    long u = 0;
#else
    long u = unlink(HOSTS_PATH);
#endif
    snprintf(msg, sizeof msg, "I: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello509: FAIL\n" : "hello509: PASS\n");
    return failures ? 1 : 0;
}
