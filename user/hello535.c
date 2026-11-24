/* hello535: a line of a known database whose sources do not parse voids the whole /etc/nsswitch.conf (glibc 2.44, measured:
 * nss_database_reload_1 stops at the first __nss_action_parse failure and keeps no services). A: "hosts: files" plus a bad
 * passwd line: gethostbyname, gethostbyaddr are NETDB_INTERNAL with errno EINVAL, gethostbyname_r returns EINVAL, getaddrinfo
 * without AI_CANONNAME and getnameinfo are EAI_SYSTEM, getaddrinfo AF_INET6 is EAI_NONAME; B: the bad line before the hosts line, a bad hosts line, and a bad line of group, services,
 * shadow or aliases do the same; C: a database glibc does not know (sudoers, automount), a comment and an empty "passwd:" do
 * not void it; D: cleanup. Measured with -DHOST through glibc in `unshare -r -m -n` with a tmpfs on /etc, so both builds
 * create and remove the same files. */
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
#define SA(p) ((const struct sockaddr *)(p))
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define SA(p) ((const uint8_t *)(p))
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello535:   ok   " : "hello535:   FAIL ");
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
static unsigned char addr4[4] = {10, 5, 35, 1};
static unsigned char sa4[16];
/* The five lookups under the current nsswitch.conf, as one string. */
static void probe(char *out, size_t cap) {
    struct hostent he, *rp = (struct hostent *)1;
    char buf[600], host[80];
    int herr = 0;
    h_errno = 0;
    errno = 0;
    struct hostent *h1 = gethostbyname("late535.test");
    int e1 = errno, g1 = h_errno;
    h_errno = 0;
    errno = 0;
    struct hostent *h2 = gethostbyaddr(addr4, 4, AF_INET);
    int e2 = errno, g2 = h_errno;
    errno = 0;
    int rc = gethostbyname_r("late535.test", &he, buf, sizeof buf, &rp, &herr);
    struct addrinfo hints, *r = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    int g = getaddrinfo("late535.test", 0, &hints, &r);
    if (g == 0) freeaddrinfo(r);
    hints.ai_family = AF_INET6;
    r = 0;
    h_errno = 0; /* the AF_INET call leaves NETDB_INTERNAL, which glibc would turn into EAI_SYSTEM here */
    int g6 = getaddrinfo("late535.test", 0, &hints, &r);
    if (g6 == 0) freeaddrinfo(r);
    int ni = getnameinfo(SA(sa4), 16, host, sizeof host, 0, 0, 0);
    snprintf(out, cap, "%s/%d/%d %s/%d/%d r=%d/%d/%s gai=%d/%d gni=%d", h1 ? "hit" : "N", g1, e1, h2 ? "hit" : "N", g2, e2, rc,
             herr, rp ? "hit" : "N", g, g6, ni);
}
int main(void) {
    print("hello535: a bad line voids nsswitch.conf\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    memset(sa4, 0, sizeof sa4);
    sa4[0] = AF_INET;
    sa4[3] = 80;
    memcpy(sa4 + 4, addr4, 4);
    int wh = write_file("/etc/hosts", "10.5.35.1 late535.test\n");
    char got[200], want[200];
    snprintf(want, sizeof want, "N/%d/%d N/%d/%d r=%d/%d/N gai=%d/%d gni=%d", NETDB_INTERNAL, EINVAL, NETDB_INTERNAL, EINVAL,
             EINVAL, NETDB_INTERNAL, EAI_SYSTEM, EAI_NONAME, EAI_SYSTEM);

    int wn = write_file("/etc/nsswitch.conf", "hosts: files\npasswd: files [\n");
    probe(got, sizeof got);
    snprintf(msg, sizeof msg, "A: a bad passwd line (%d %d): '%s' ('%s')", wh, wn, got, want);
    check(wh == 0 && wn == 0 && strcmp(got, want) == 0, msg);

    static const char *const voids[] = {
        "passwd: files [\nhosts: files\n", "hosts: dns []\nhosts: files\n", "hosts: files\ngroup: x [FOO=bar]\n",
        "hosts: files\nservices: files [\n", "hosts: files\nshadow: files [UNAVAIL=return\n",
        "hosts: files\naliases: files [NOTFOUND=foo]\n",
    };
    int bad = -1;
    for (unsigned i = 0; i < sizeof voids / sizeof voids[0]; i++) {
        if (write_file("/etc/nsswitch.conf", voids[i]) != 0) { bad = (int)i; break; }
        probe(got, sizeof got);
        if (strcmp(got, want) != 0) { bad = (int)i; break; }
    }
    snprintf(msg, sizeof msg, "B: %u more bad lines, first wrong %d: '%s' (-1, all '%s')",
             (unsigned)(sizeof voids / sizeof voids[0]), bad, got, want);
    check(bad == -1, msg);

    static const char *const kept[] = {"hosts: files\nsudoers: files [\n", "hosts: files\nautomount: x [\n",
                                       "hosts: files\n#passwd: files [\n", "hosts: files\npasswd:\n"};
    bad = -1;
    for (unsigned i = 0; i < sizeof kept / sizeof kept[0]; i++) {
        if (write_file("/etc/nsswitch.conf", kept[i]) != 0) { bad = (int)i; break; }
        probe(got, sizeof got);
        if (strcmp(got, "hit/0/0 hit/0/0 r=0/0/hit gai=0/-2 gni=0") != 0) { bad = (int)i; break; }
    }
    snprintf(msg, sizeof msg, "C: %u lines that do not void it, first wrong %d: '%s' (-1, all 'hit/0/0 hit/0/0 r=0/0/hit gai=0/-2 gni=0')",
             (unsigned)(sizeof kept / sizeof kept[0]), bad, got);
    check(bad == -1, msg);

    long u1 = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf");
    snprintf(msg, sizeof msg, "D: unlink %ld %ld (0 0)", u1, u2);
    check(u1 == 0 && u2 == 0, msg);
    print(failures ? "hello535: FAIL\n" : "hello535: PASS\n");
    return failures ? 1 : 0;
}
