/* hello546: the "myhostname" source of /etc/nsswitch.conf (systemd nss-myhostname through glibc 2.44, measured in
 * `unshare -r -u -m -n` with the host name set to moqios and no address but loopback). A: "localhost", "foo.localhost" and
 * "localhost.localdomain" (any case) are 127.0.0.1 and ::1, named localhost; B: the host name is 127.0.0.2 and ::1 when the host
 * has no address of its own, getaddrinfo lists ::1 first, the canonical name is the host name, "MOQIOS" (case matters) and
 * "localhost6" are not known (only the names and the first family are compared: on MoQiOS eth0's own addresses, its link-local
 * one at least, take the place of 127.0.0.2 and ::1); C: in reverse 127.0.0.1 and ::1 are localhost, 127.0.0.2 the host name, 127.0.0.3 has no name;
 * D: "myhostname files" goes on to /etc/hosts for other names, [NOTFOUND=return] does not; E: cleanup. Needs root (/etc). */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define SA(p) ((const struct sockaddr *)(p))
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/netdb.h"
#define SA(p) ((const uint8_t *)(p))
#endif
static int failures;
static char msg[1400];
static void check(int ok, const char *w) {
    print(ok ? "hello546:   ok   " : "hello546:   FAIL ");
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
/* gethostbyname, gethostbyname2(AF_INET6) and getaddrinfo(AF_UNSPEC, AI_CANONNAME) of `name`, appended to `out`; the addresses
 * only when `addrs` (the host name's are the host's own, which depend on the network). */
static void fwd(const char *name, int addrs, char *out, size_t cap) {
    char a[200];
    struct hostent *h = gethostbyname(name);
    if (h && !addrs) snprintf(a, sizeof a, "%s", h->h_name);
    else if (h) snprintf(a, sizeof a, "%s %u.%u.%u.%u", h->h_name, (unsigned char)h->h_addr_list[0][0], (unsigned char)h->h_addr_list[0][1],
                    (unsigned char)h->h_addr_list[0][2], (unsigned char)h->h_addr_list[0][3]);
    else snprintf(a, sizeof a, "NULL/%d", h_errno);
    h = gethostbyname2(name, AF_INET6);
    char b[100];
    if (h && !addrs) snprintf(b, sizeof b, "%s", h->h_name);
    else if (h) snprintf(b, sizeof b, "%s ::%u", h->h_name, (unsigned char)h->h_addr_list[0][15]);
    else snprintf(b, sizeof b, "NULL/%d", h_errno);
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_CANONNAME;
    int e = getaddrinfo(name, 0, &hints, &res);
    char c[200];
    if (e == 0) {
        int n = snprintf(c, sizeof c, "0 %s", res->ai_canonname ? res->ai_canonname : "-");
        for (struct addrinfo *p = res; p && n < (int)sizeof c - 8 && (addrs || p == res); p = p->ai_next)
            n += snprintf(c + n, sizeof c - (size_t)n, " %s", p->ai_family == AF_INET6 ? "v6" : "v4");
        freeaddrinfo(res);
    } else {
        snprintf(c, sizeof c, "%d", e);
    }
    size_t l = strlen(out);
    snprintf(out + l, cap - l, "%s | %s | %s; ", a, b, c);
}
/* getnameinfo(NI_NAMEREQD) of an IPv4 or IPv6 loopback address, appended to `out`. */
static void rev4(unsigned d, char *out, size_t cap) {
    unsigned char sa[16];
    memset(sa, 0, sizeof sa);
    sa[0] = AF_INET; sa[4] = 127; sa[7] = (unsigned char)d;
    char host[100];
    int e = getnameinfo(SA(sa), 16, host, sizeof host, 0, 0, NI_NAMEREQD);
    size_t l = strlen(out);
    snprintf(out + l, cap - l, "%d %s; ", e, e ? "-" : host);
}
int main(void) {
    print("hello546: nsswitch.conf myhostname source\n");
#ifndef HOST
    mkdir("/etc", 0755);
#endif
    int wn = write_file("/etc/nsswitch.conf", "hosts: myhostname\n");
    int wh = write_file("/etc/hosts", "");
    char got[600] = "", want[600];
    fwd("localhost", 1, got, sizeof got);
    fwd("Foo.LocalHost", 1, got, sizeof got);
    fwd("localhost.localdomain", 1, got, sizeof got);
    snprintf(want, sizeof want, "localhost 127.0.0.1 | localhost ::1 | 0 localhost v6 v4; localhost 127.0.0.1 | localhost ::1 | 0 localhost v6 v4; "
                                "localhost 127.0.0.1 | localhost ::1 | 0 localhost v6 v4; ");
    snprintf(msg, sizeof msg, "A: localhost names (nsswitch %d hosts %d): '%s' ('%s')", wn, wh, got, want);
    check(wn == 0 && wh == 0 && strcmp(got, want) == 0, msg);

    got[0] = 0;
    fwd("moqios", 0, got, sizeof got);
    fwd("moqios.", 0, got, sizeof got);
    fwd("MOQIOS", 0, got, sizeof got);
    fwd("localhost6", 0, got, sizeof got);
    snprintf(want, sizeof want, "moqios | moqios | 0 moqios v6; moqios | moqios | 0 moqios v6; "
                                "NULL/1 | NULL/1 | %d; NULL/1 | NULL/1 | %d; ", EAI_NONAME, EAI_NONAME);
    snprintf(msg, sizeof msg, "B: the host name: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    got[0] = 0;
    rev4(1, got, sizeof got);
    rev4(2, got, sizeof got);
    rev4(3, got, sizeof got);
    unsigned char s6[28];
    memset(s6, 0, sizeof s6);
    s6[0] = AF_INET6;
    s6[23] = 1;
    char host[100];
    int e6 = getnameinfo(SA(s6), 28, host, sizeof host, 0, 0, NI_NAMEREQD);
    size_t l = strlen(got);
    snprintf(got + l, sizeof got - l, "%d %s; ", e6, e6 ? "-" : host);
    snprintf(want, sizeof want, "0 localhost; 0 moqios; %d -; 0 localhost; ", EAI_NONAME);
    snprintf(msg, sizeof msg, "C: reverse: '%s' ('%s')", got, want);
    check(strcmp(got, want) == 0, msg);

    write_file("/etc/nsswitch.conf", "hosts: myhostname files\n");
    write_file("/etc/hosts", "10.5.46.1 other.test\n");
    got[0] = 0;
    struct hostent *h = gethostbyname("other.test");
    snprintf(got, sizeof got, "%s", h ? h->h_name : "NULL");
    write_file("/etc/nsswitch.conf", "hosts: myhostname [NOTFOUND=return] files\n");
    h = gethostbyname("other.test");
    l = strlen(got);
    snprintf(got + l, sizeof got - l, " %s/%d", h ? h->h_name : "NULL", h ? 0 : h_errno);
    snprintf(msg, sizeof msg, "D: myhostname then files: '%s' ('other.test NULL/1')", got);
    check(strcmp(got, "other.test NULL/1") == 0, msg);

#ifdef HOST
    long u = 0, u2 = 0; /* the host files are bind-mount targets */
#else
    long u = unlink("/etc/hosts"), u2 = unlink("/etc/nsswitch.conf");
#endif
    snprintf(msg, sizeof msg, "E: unlink %ld %ld (0 0)", u, u2);
    check(u == 0 && u2 == 0, msg);
    print(failures ? "hello546: FAIL\n" : "hello546: PASS\n");
    return failures ? 1 : 0;
}
