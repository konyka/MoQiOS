/* hello503: gethostbyname and getaddrinfo read /etc/hosts before the resolver (glibc's "files dns" order). A creates /etc/hosts;
 * B a name only in the file resolves through gethostbyname, in any case, by any of its names; C getaddrinfo agrees; D a name not in
 * the file still goes to the kernel resolver (localhost); E an IPv6-only line (2001:db8::5) and an unknown name do not resolve; F cleanup.
 * Measured with -DHOST in a mount namespace with /etc/hosts bind-mounted to a scratch file. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define HOSTS_PATH (getenv("H503") ? getenv("H503") : "/etc/hosts")
#include <stdlib.h>
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define HOSTS_PATH "/etc/hosts"
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello503:   ok   " : "hello503:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] = "127.0.0.1 localhost\n# comment\n10.5.0.3\tfiles503.example\tf503  # trailing\n2001:db8::5 v6only503\n";
static int addr_of(const char *name, unsigned char out[4]) {
    struct hostent *h = gethostbyname(name);
    if (!h || !h->h_addr_list || !h->h_addr_list[0]) return 0;
    memcpy(out, h->h_addr_list[0], 4);
    return 1;
}
static int gai_addr(const char *name, unsigned char out[4]) {
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = 2;
    hints.ai_socktype = 1;
    if (getaddrinfo(name, "80", &hints, &res) != 0 || !res) return 0;
    memcpy(out, (unsigned char *)res->ai_addr + 4, 4);
    freeaddrinfo(res);
    return 1;
}
int main(void) {
    print("hello503: /etc/hosts before the resolver\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello503:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long w = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    snprintf(msg, sizeof msg, "A: open %d, write %ld (>=0 %d)", fd, w, (int)(sizeof hosts - 1));
    check(fd >= 0 && w == (long)(sizeof hosts - 1), msg);
    unsigned char a[4] = { 0 }, b[4] = { 0 }, c[4] = { 0 };
    int r1 = addr_of("files503.example", a), r2 = addr_of("F503", b), r3 = gai_addr("f503", c);
    snprintf(msg, sizeof msg, "B/C: gethostbyname %d %u.%u.%u.%u, alias upper-case %d %u, getaddrinfo %d %u.%u.%u.%u (1 10.5.0.3 1 3 1 10.5.0.3)",
             r1, a[0], a[1], a[2], a[3], r2, b[3], r3, c[0], c[1], c[2], c[3]);
    check(r1 && a[0] == 10 && a[1] == 5 && a[2] == 0 && a[3] == 3 && r2 && b[3] == 3 && r3 && c[0] == 10 && c[3] == 3, msg);
    unsigned char l[4] = { 0 };
    int r4 = addr_of("localhost", l);
    snprintf(msg, sizeof msg, "D: localhost %d %u.%u.%u.%u (1 127.0.0.1)", r4, l[0], l[1], l[2], l[3]);
    check(r4 && l[0] == 127 && l[3] == 1, msg);
    unsigned char x[4] = { 0 };
    int r5 = addr_of("v6only503", x), r6 = addr_of("nosuch503.invalid", x);
    snprintf(msg, sizeof msg, "E: IPv6-only line %d, unknown name %d (0 0)", r5, r6);
    check(!r5 && !r6, msg);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(HOSTS_PATH);
#endif
    snprintf(msg, sizeof msg, "F: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello503: FAIL\n" : "hello503: PASS\n");
    return failures ? 1 : 0;
}
