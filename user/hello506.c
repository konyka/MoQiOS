/* hello506: getaddrinfo serves AF_INET6 (glibc semantics, measured). A creates /etc/hosts with IPv6 and IPv4 lines for one name;
 * B an IPv6 literal gives one 28-byte sockaddr_in6 and binds and listens on ::1; C getaddrinfo("ip6-loopback506") from /etc/hosts
 * connects to that listener over IPv6; D a name with both families lists IPv6 lines first, AF_INET6 only the IPv6 ones; E an IPv4
 * literal under AF_INET6 is EAI_ADDRFAMILY, under AI_V4MAPPED ::ffff:a.b.c.d; F a numeric scope sets sin6_scope_id; G a NULL node
 * under AF_INET6 is ::1 or, passive, ::; H cleanup. Measured with -DHOST in a mount namespace with /etc/hosts bind-mounted. */
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
#define HOSTS_PATH (getenv("H506") ? getenv("H506") : "/etc/hosts")
static long sk(int fam, int type) { int r = socket(fam, type, 0); return r < 0 ? -1 : r; }
static long bnd(long fd, const void *a, unsigned l) { return bind((int)fd, (const struct sockaddr *)a, l) ? -1 : 0; }
static long lsn(long fd) { return listen((int)fd, 4) ? -1 : 0; }
static long con(long fd, const void *a, unsigned l) { return connect((int)fd, (const struct sockaddr *)a, l) ? -1 : 0; }
static long acc(long fd) { return accept((int)fd, 0, 0); }
static void pump(void) {}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define HOSTS_PATH "/etc/hosts"
static long sk(int fam, int type) { return syscall3(SYS_socket, fam, type, 0); }
static long bnd(long fd, const void *a, unsigned l) { return syscall3(SYS_bind, fd, (long)a, l); }
static long lsn(long fd) { return syscall2(SYS_listen, fd, 4); }
static long con(long fd, const void *a, unsigned l) {
    long r = syscall3(SYS_connect, fd, (long)a, l);
    for (int i = 0; i < 20 && r < 0 && r != -106; i++) {
        syscall1(SYS_netpoll, 0);
        r = syscall3(SYS_connect, fd, (long)a, l);
    }
    return r == -106 ? 0 : r;
}
static long acc(long fd) { return syscall4(SYS_accept4, fd, 0, 0, 0); }
static void pump(void) { syscall1(SYS_netpoll, 0); }
#endif
static int failures;
static char msg[360];
static void check(int ok, const char *w) {
    print(ok ? "hello506:   ok   " : "hello506:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static const char hosts[] = "::1 ip6-loopback506\n2001:db8::6 both506\n10.5.0.6 both506\n2001:db8::7 both506\n";
static struct addrinfo hints;
static void set_hints(int fam, int flags) {
    memset(&hints, 0, sizeof hints);
    hints.ai_family = fam;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = flags;
}
static const unsigned char *A(const struct addrinfo *r) { return (const unsigned char *)r->ai_addr; }
int main(void) {
    print("hello506: getaddrinfo with AF_INET6\n");
#ifndef HOST
    long md = mkdir("/etc", 0755);
    snprintf(msg, sizeof msg, "setup: mkdir /etc %ld (0 or -17)", md);
    print("hello506:   .. "); print(msg); print("\n");
#endif
    int fd = (int)open(HOSTS_PATH, 0x041 | 0x200, 0644);
    long w = fd >= 0 ? (long)write(fd, hosts, sizeof hosts - 1) : -1;
    if (fd >= 0) close(fd);
    snprintf(msg, sizeof msg, "A: open %d, write %ld (>=0 %d)", fd, w, (int)(sizeof hosts - 1));
    check(fd >= 0 && w == (long)(sizeof hosts - 1), msg);

    struct addrinfo *lit = 0;
    set_hints(AF_INET6, AI_PASSIVE);
    int b0 = getaddrinfo("::1", "9506", &hints, &lit);
    long ls = -1, b1 = -1, b2 = -1;
    if (b0 == 0) {
        ls = sk(lit->ai_family, lit->ai_socktype);
        b1 = bnd(ls, lit->ai_addr, lit->ai_addrlen);
        b2 = lsn(ls);
    }
    snprintf(msg, sizeof msg, "B: ::1 %d family %d len %u port %u, socket %ld bind %ld listen %ld (0 10 28 9506 >=0 0 0)", b0,
             b0 == 0 ? lit->ai_family : -1, b0 == 0 ? lit->ai_addrlen : 0, b0 == 0 ? (unsigned)(A(lit)[2] << 8 | A(lit)[3]) : 0, ls, b1, b2);
    check(b0 == 0 && lit->ai_family == AF_INET6 && lit->ai_addrlen == 28 && A(lit)[2] == 0x25 && A(lit)[3] == 0x22 && lit->ai_next == 0 &&
              ls >= 0 && b1 == 0 && b2 == 0, msg);
    if (b0 == 0) freeaddrinfo(lit);

    struct addrinfo *named = 0;
    set_hints(AF_INET6, 0);
    int c0 = getaddrinfo("IP6-LOOPBACK506", "9506", &hints, &named);
    long cs = -1, c1 = -1, c2 = -1;
    if (c0 == 0) {
        cs = sk(named->ai_family, named->ai_socktype);
        c1 = con(cs, named->ai_addr, named->ai_addrlen);
        for (int i = 0; i < 20 && c2 < 0; i++) {
            pump();
            c2 = acc(ls);
        }
    }
    snprintf(msg, sizeof msg, "C: ip6-loopback506 %d, ::1 %d, connect %ld accept %ld (0 1 0 >=0)", c0, c0 == 0 && A(named)[23] == 1 && A(named)[8] == 0,
             c1, c2);
    check(c0 == 0 && A(named)[23] == 1 && A(named)[8] == 0 && cs >= 0 && c1 == 0 && c2 >= 0, msg);
    if (c0 == 0) freeaddrinfo(named);
    if (c2 >= 0) close((int)c2);
    if (cs >= 0) close((int)cs);
    if (ls >= 0) close((int)ls);

    struct addrinfo *both = 0, *p;
    set_hints(AF_UNSPEC, 0);
    int d0 = getaddrinfo("both506", "80", &hints, &both);
    char order[64];
    size_t n = 0;
    order[0] = 0;
    for (p = d0 == 0 ? both : 0; p && n + 4 < sizeof order; p = p->ai_next)
        n += (size_t)snprintf(order + n, sizeof order - n, "%c%u ", p->ai_family == AF_INET6 ? '6' : '4',
                              p->ai_family == AF_INET6 ? A(p)[23] : A(p)[7]);
    if (d0 == 0) freeaddrinfo(both);
    set_hints(AF_INET6, 0);
    int d1 = getaddrinfo("both506", "80", &hints, &both), d1n = 0;
    for (p = d1 == 0 ? both : 0; p; p = p->ai_next) d1n++;
    if (d1 == 0) freeaddrinfo(both);
    snprintf(msg, sizeof msg, "D: AF_UNSPEC %d [%s], AF_INET6 %d count %d (0 [66 67 46 ] 0 2)", d0, order, d1, d1n);
    check(d0 == 0 && strcmp(order, "66 67 46 ") == 0 && d1 == 0 && d1n == 2, msg);

    struct addrinfo *m = 0;
    set_hints(AF_INET6, 0);
    int e0 = getaddrinfo("10.5.0.6", "80", &hints, &m);
    if (e0 == 0) freeaddrinfo(m);
    set_hints(AF_INET6, AI_V4MAPPED);
    int e1 = getaddrinfo("10.5.0.6", "80", &hints, &m);
    int mapped = e1 == 0 && A(m)[18] == 255 && A(m)[19] == 255 && A(m)[20] == 10 && A(m)[23] == 6 && m->ai_family == AF_INET6;
    if (e1 == 0) freeaddrinfo(m);
    snprintf(msg, sizeof msg, "E: IPv4 literal under AF_INET6 %d, AI_V4MAPPED %d mapped %d (-9 0 1)", e0, e1, mapped);
    check(e0 == EAI_ADDRFAMILY && e1 == 0 && mapped, msg);

    struct addrinfo *sc = 0;
    set_hints(AF_INET6, AI_NUMERICHOST);
    int f0 = getaddrinfo("fe80::1%7", "80", &hints, &sc);
    unsigned sid = f0 == 0 ? (unsigned)(A(sc)[24] | A(sc)[25] << 8 | A(sc)[26] << 16 | (unsigned)A(sc)[27] << 24) : 0;
    if (f0 == 0) freeaddrinfo(sc);
    int f1 = getaddrinfo("fe80::1%x", "80", &hints, &sc);
    if (f1 == 0) freeaddrinfo(sc);
    snprintf(msg, sizeof msg, "F: fe80::1%%7 %d scope %u, fe80::1%%x %d (0 7 -2)", f0, sid, f1);
    check(f0 == 0 && sid == 7 && f1 == EAI_NONAME, msg);

    struct addrinfo *nl = 0;
    set_hints(AF_INET6, 0);
    int g0 = getaddrinfo(0, "80", &hints, &nl);
    int lo = g0 == 0 && A(nl)[23] == 1 && A(nl)[8] == 0 && nl->ai_next == 0;
    if (g0 == 0) freeaddrinfo(nl);
    set_hints(AF_INET6, AI_PASSIVE);
    int g1 = getaddrinfo(0, "80", &hints, &nl);
    int any = g1 == 0 && A(nl)[23] == 0 && A(nl)[8] == 0 && nl->ai_family == AF_INET6;
    if (g1 == 0) freeaddrinfo(nl);
    snprintf(msg, sizeof msg, "G: NULL node %d ::1 %d, passive %d :: %d (0 1 0 1)", g0, lo, g1, any);
    check(g0 == 0 && lo && g1 == 0 && any, msg);
#ifdef HOST
    long u = 0; /* the host file is a bind-mount target */
#else
    long u = unlink(HOSTS_PATH);
#endif
    snprintf(msg, sizeof msg, "H: unlink %ld (0)", u);
    check(u == 0, msg);
    print(failures ? "hello506: FAIL\n" : "hello506: PASS\n");
    return failures ? 1 : 0;
}
