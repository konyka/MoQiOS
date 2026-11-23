/* hello511: interface names and indexes (glibc semantics, measured). A if_nametoindex("lo") is 1 and agrees with SIOCGIFINDEX;
 * B unknown, empty, wrong-case and too-long names are 0 with ENODEV; C if_indextoname(1) writes "lo" and returns the buffer,
 * index 0 and an unknown index are NULL with ENXIO; D getaddrinfo takes "%lo" on a link-local and a link-scope multicast address
 * and puts index 1 in sin6_scope_id, a numeric scope still works on a global address; E "%lo" on a global or site-scope address,
 * an unknown interface and a trailing "%" are EAI_NONAME; F getnameinfo prints "%lo" for a link-local or link-scope multicast
 * address with scope 1, "%1" for other addresses, and "%99" for an index with no interface. Measured with -DHOST in
 * `unshare -n` (only lo). */
#ifdef HOST
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define SA(p) ((const struct sockaddr *)(p))
static long ifindex_ioctl(const char *name) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq r;
    memset(&r, 0, sizeof r);
    strncpy(r.ifr_name, name, IFNAMSIZ - 1);
    long rc = ioctl(s, SIOCGIFINDEX, &r) < 0 ? -errno : r.ifr_ifindex;
    close(s);
    return rc;
}
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define SA(p) (p)
#define inet_pton(af, text, out) ((void)(af), ipv6_from_text((text), (out)))
static long ifindex_ioctl(const char *name) {
    long s = syscall3(SYS_socket, 2, 2, 0);
    unsigned char r[40];
    memset(r, 0, sizeof r);
    strncpy((char *)r, name, 15);
    long rc = syscall3(SYS_ioctl, s, 0x8933, (long)r);
    if (rc == 0) rc = (long)((unsigned)r[16] | (unsigned)r[17] << 8 | (unsigned)r[18] << 16 | (unsigned)r[19] << 24);
    syscall1(SYS_close, s);
    return rc;
}
#endif
static int failures;
static char msg[420];
static void check(int ok, const char *w) {
    print(ok ? "hello511:   ok   " : "hello511:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int n2i(const char *name, int *err) {
    errno = 0;
    int r = (int)if_nametoindex(name);
    *err = errno;
    return r;
}
static int gai_scope(const char *node, long *scope) {
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET6;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(node, "80", &hints, &res);
    *scope = -1;
    if (rc == 0) {
        const unsigned char *a = (const unsigned char *)res->ai_addr;
        *scope = (long)((unsigned)a[24] | (unsigned)a[25] << 8 | (unsigned)a[26] << 16 | (unsigned)a[27] << 24);
        freeaddrinfo(res);
    }
    return rc;
}
static int gni_text(const char *text, unsigned scope, char *host, unsigned cap) {
    unsigned char sa[28];
    memset(sa, 0, sizeof sa);
    sa[0] = 10;
    inet_pton(AF_INET6, text, sa + 8);
    sa[24] = (unsigned char)scope;
    sa[25] = (unsigned char)(scope >> 8);
    host[0] = 0;
    return getnameinfo(SA(sa), 28, host, cap, 0, 0, NI_NUMERICHOST);
}
int main(void) {
    print("hello511: if_nametoindex, if_indextoname and interface scopes\n");
    int e0, e1, e2, e3, e4, e5;
    int a = n2i("lo", &e0);
    long io = ifindex_ioctl("lo");
    snprintf(msg, sizeof msg, "A: if_nametoindex(lo) %d errno %d, SIOCGIFINDEX %ld, IF_NAMESIZE %d (1 0 1 16)", a, e0, io, IF_NAMESIZE);
    check(a == 1 && e0 == 0 && io == 1 && IF_NAMESIZE == 16, msg);

    int b1 = n2i("nosuch0", &e1), b2 = n2i("", &e2), b3 = n2i("LO", &e3), b4 = n2i("lo ", &e4), b5 = n2i("0123456789abcdefg", &e5);
    snprintf(msg, sizeof msg, "B: nosuch0 %d/%d, empty %d/%d, LO %d/%d, 'lo ' %d/%d, 17 chars %d/%d (0/19 each)", b1, e1, b2, e2, b3, e3, b4, e4, b5,
             e5);
    check(b1 == 0 && e1 == ENODEV && b2 == 0 && e2 == ENODEV && b3 == 0 && e3 == ENODEV && b4 == 0 && e4 == ENODEV && b5 == 0 &&
              e5 == ENODEV, msg);

    char nb[IF_NAMESIZE + 8];
    memset(nb, 'X', sizeof nb);
    errno = 0;
    char *c1 = if_indextoname(1, nb);
    int ce1 = errno;
    char nb2[IF_NAMESIZE];
    errno = 0;
    char *c2 = if_indextoname(0, nb2);
    int ce2 = errno;
    errno = 0;
    char *c3 = if_indextoname(99, nb2);
    int ce3 = errno;
    snprintf(msg, sizeof msg, "C: index 1 '%s' same buffer %d errno %d; index 0 %s/%d; index 99 %s/%d (lo 1 0, NULL/6, NULL/6)", c1 ? nb : "NULL",
             c1 == nb, ce1, c2 ? "set" : "NULL", ce2, c3 ? "set" : "NULL", ce3);
    check(c1 == nb && strcmp(nb, "lo") == 0 && ce1 == 0 && !c2 && ce2 == ENXIO && !c3 && ce3 == ENXIO, msg);

    long s1, s2, s3, s4;
    int d1 = gai_scope("fe80::1%lo", &s1), d2 = gai_scope("ff02::1%lo", &s2), d3 = gai_scope("ff01::1%lo", &s3),
        d4 = gai_scope("2001:db8::1%1", &s4);
    snprintf(msg, sizeof msg, "D: fe80::1%%lo %d/%ld, ff02::1%%lo %d/%ld, ff01::1%%lo %d/%ld, 2001:db8::1%%1 %d/%ld (0/1 each)", d1, s1, d2, s2,
             d3, s3, d4, s4);
    check(d1 == 0 && s1 == 1 && d2 == 0 && s2 == 1 && d3 == 0 && s3 == 1 && d4 == 0 && s4 == 1, msg);

    long t;
    int f1 = gai_scope("2001:db8::1%lo", &t), f2 = gai_scope("fec0::1%lo", &t), f3 = gai_scope("ff05::1%lo", &t),
        f4 = gai_scope("fe80::1%nosuch0", &t), f5 = gai_scope("fe80::1%", &t), f6 = gai_scope("fe80::1%LO", &t);
    snprintf(msg, sizeof msg, "E: global %d, site %d, ff05 %d, unknown %d, empty %d, LO %d (-2 each)", f1, f2, f3, f4, f5, f6);
    check(f1 == EAI_NONAME && f2 == EAI_NONAME && f3 == EAI_NONAME && f4 == EAI_NONAME && f5 == EAI_NONAME && f6 == EAI_NONAME, msg);

    char h1[64], h2[64], h3[64], h4[64], h5[64];
    int g1 = gni_text("fe80::1", 1, h1, sizeof h1), g2 = gni_text("ff02::1", 1, h2, sizeof h2), g3 = gni_text("2001:db8::1", 1, h3, sizeof h3),
        g4 = gni_text("ff05::1", 1, h4, sizeof h4), g5 = gni_text("fe80::1", 99, h5, sizeof h5);
    snprintf(msg, sizeof msg, "F: '%s' '%s' '%s' '%s' '%s' rc %d%d%d%d%d (fe80::1%%lo ff02::1%%lo 2001:db8::1%%1 ff05::1%%1 fe80::1%%99)", h1, h2,
             h3, h4, h5, g1, g2, g3, g4, g5);
    check(g1 == 0 && strcmp(h1, "fe80::1%lo") == 0 && g2 == 0 && strcmp(h2, "ff02::1%lo") == 0 && g3 == 0 && strcmp(h3, "2001:db8::1%1") == 0 &&
              g4 == 0 && strcmp(h4, "ff05::1%1") == 0 && g5 == 0 && strcmp(h5, "fe80::1%99") == 0, msg);
    print(failures ? "hello511: FAIL\n" : "hello511: PASS\n");
    return failures ? 1 : 0;
}
