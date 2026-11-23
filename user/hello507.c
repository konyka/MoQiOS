/* hello507: getnameinfo takes a sockaddr_in6 (glibc semantics, measured). A creates /etc/hosts with IPv6 and IPv4 lines; B an
 * address on an IPv6 line gives that line's first name, also under NI_NAMEREQD; C ::1 is the /etc/hosts name and ::ffff:a.b.c.d
 * is named from the IPv4 line; D an address not in the file is inet_ntop text, NI_NAMEREQD makes it EAI_NONAME; E a non-zero
 * scope id appends "%N"; F a 27-byte address is EAI_FAMILY and a buffer one byte short is EAI_OVERFLOW; G the address of a real
 * IPv6 socket bound to ::1 reads back as "::1" and its port; H cleanup. Measured with -DHOST in a mount namespace with
 * /etc/hosts bind-mounted to a scratch file. */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define HOSTS_PATH (getenv("H507") ? getenv("H507") : "/etc/hosts")
#define SA(p) ((const struct sockaddr *)(p))
static long sk6(void) { int r = socket(AF_INET6, SOCK_STREAM, 0); return r < 0 ? -1 : r; }
static long bnd(long fd, const void *a, unsigned l) { return bind((int)fd, (const struct sockaddr *)a, l) ? -1 : 0; }
static long gsn(long fd, void *a, unsigned *l) { socklen_t n = *l; int r = getsockname((int)fd, (struct sockaddr *)a, &n); *l = n; return r ? -1 : 0; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define HOSTS_PATH "/etc/hosts"
#define SA(p) (p)
static long sk6(void) { return syscall3(SYS_socket, 10, 1, 0); }
static long bnd(long fd, const void *a, unsigned l) { return syscall3(SYS_bind, fd, (long)a, l); }
static long gsn(long fd, void *a, unsigned *l) { return syscall3(51 /* getsockname */, fd, (long)a, (long)l); }
#endif
static int failures;
static char msg[360];
static void check(int ok, const char *w) {
    print(ok ? "hello507:   ok   " : "hello507:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] = "::1 localhost6-507 ip6-localhost\n2001:DB8:0::7 Seven507.example s507\n10.5.0.7 four507\n";
static unsigned char sa[28];
static void set6(const unsigned char a[16], unsigned scope, unsigned port) {
    memset(sa, 0, sizeof sa);
    sa[0] = 10;
    sa[2] = (unsigned char)(port >> 8);
    sa[3] = (unsigned char)port;
    memcpy(sa + 8, a, 16);
    sa[24] = (unsigned char)scope;
    sa[25] = (unsigned char)(scope >> 8);
}
static int ni(unsigned len, int flags, char *h, unsigned hl, char *s, unsigned sl) {
    h[0] = 0;
    if (s) s[0] = 0;
    return getnameinfo(SA(sa), len, h, hl, s, sl, flags);
}
int main(void) {
    print("hello507: getnameinfo with sockaddr_in6\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello507:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long w = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    snprintf(msg, sizeof msg, "A: open %d, write %ld (>=0 %d)", fd, w, (int)(sizeof hosts - 1));
    check(fd >= 0 && w == (long)(sizeof hosts - 1), msg);

    static const unsigned char seven[16] = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7};
    static const unsigned char nine[16] = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9};
    static const unsigned char lo[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    static const unsigned char mapped[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 5, 0, 7};
    static const unsigned char ll[16] = {0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    char h1[80], h2[80], s1[32];
    set6(seven, 0, 443);
    int b1 = ni(28, 0, h1, sizeof h1, s1, sizeof s1), b2 = ni(28, NI_NAMEREQD, h2, sizeof h2, 0, 0);
    snprintf(msg, sizeof msg, "B: 2001:db8::7 %d '%s' '%s', NI_NAMEREQD %d '%s' (0 Seven507.example https 0 Seven507.example)", b1, h1, s1, b2, h2);
    check(b1 == 0 && strcmp(h1, "Seven507.example") == 0 && strcmp(s1, "https") == 0 && b2 == 0 && strcmp(h2, "Seven507.example") == 0, msg);

    set6(lo, 0, 80);
    int c1 = ni(28, 0, h1, sizeof h1, 0, 0);
    set6(mapped, 0, 80);
    int c2 = ni(28, 0, h2, sizeof h2, 0, 0);
    snprintf(msg, sizeof msg, "C: ::1 %d '%s', ::ffff:10.5.0.7 %d '%s' (0 localhost6-507 0 four507)", c1, h1, c2, h2);
    check(c1 == 0 && strcmp(h1, "localhost6-507") == 0 && c2 == 0 && strcmp(h2, "four507") == 0, msg);

    set6(nine, 0, 80);
    int d1 = ni(28, 0, h1, sizeof h1, 0, 0), d2 = ni(28, NI_NAMEREQD, h2, sizeof h2, 0, 0);
    snprintf(msg, sizeof msg, "D: 2001:db8::9 %d '%s', NI_NAMEREQD %d (0 2001:db8::9 -2)", d1, h1, d2);
    check(d1 == 0 && strcmp(h1, "2001:db8::9") == 0 && d2 == EAI_NONAME, msg);

    set6(ll, 3, 80);
    int e1 = ni(28, NI_NUMERICHOST, h1, sizeof h1, 0, 0);
    set6(nine, 300, 80);
    int e2 = ni(28, NI_NUMERICHOST, h2, sizeof h2, 0, 0);
    snprintf(msg, sizeof msg, "E: fe80::1 scope 3 %d '%s', 2001:db8::9 scope 300 %d '%s' (0 fe80::1%%3 0 2001:db8::9%%300)", e1, h1, e2, h2);
    check(e1 == 0 && strcmp(h1, "fe80::1%3") == 0 && e2 == 0 && strcmp(h2, "2001:db8::9%300") == 0, msg);

    set6(nine, 0, 80);
    int f1 = ni(27, NI_NUMERICHOST, h1, sizeof h1, 0, 0), f2 = ni(28, NI_NUMERICHOST, h1, 11, 0, 0), f3 = ni(28, NI_NUMERICHOST, h2, 12, 0, 0);
    snprintf(msg, sizeof msg, "F: 27 bytes %d, host buffer 11 %d, 12 %d '%s' (-6 -12 0 2001:db8::9)", f1, f2, f3, h2);
    check(f1 == EAI_FAMILY && f2 == EAI_OVERFLOW && f3 == 0 && strcmp(h2, "2001:db8::9") == 0, msg);

    long s = sk6(), g1 = -1, g2 = -1;
    unsigned char bound[28], got[28];
    unsigned gl = sizeof got;
    set6(lo, 0, 9507);
    memcpy(bound, sa, sizeof bound);
    if (s >= 0) g1 = bnd(s, bound, 28);
    if (g1 == 0) g2 = gsn(s, got, &gl);
    int g3 = -1;
    if (g2 == 0) {
        memcpy(sa, got, sizeof sa);
        g3 = ni(gl, NI_NUMERICHOST | NI_NUMERICSERV, h1, sizeof h1, s1, sizeof s1);
    }
    if (s >= 0) close((int)s);
    snprintf(msg, sizeof msg, "G: socket %ld bind %ld getsockname %ld len %u, getnameinfo %d '%s' '%s' (>=0 0 0 28 0 ::1 9507)", s, g1, g2, gl, g3, h1, s1);
    check(s >= 0 && g1 == 0 && g2 == 0 && gl == 28 && g3 == 0 && strcmp(h1, "::1") == 0 && strcmp(s1, "9507") == 0, msg);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(HOSTS_PATH);
#endif
    snprintf(msg, sizeof msg, "H: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello507: FAIL\n" : "hello507: PASS\n");
    return failures ? 1 : 0;
}
