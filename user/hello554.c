/* hello554: SO_PEEK_OFF on raw sockets (Linux 7.x, measured with -DHOST): a raw socket has no set_peek_off, so getsockopt and
 * setsockopt both fail with EOPNOTSUPP. A: IPv4 raw ICMP; B: IPv6 raw ICMPv6; C: IPv4 IPPROTO_RAW. Needs CAP_NET_RAW. Each case
 * prints what it saw; the expected value is in parentheses. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
typedef unsigned socklen_t;
#define AF_INET 2
#define AF_INET6 10
#define SOCK_RAW 3
#define SOL_SOCKET 1
#define IPPROTO_ICMP 1
#define IPPROTO_ICMPV6 58
#define IPPROTO_RAW 255
static long ret(long r) {
    if (r < 0) {
        errno = (int)-r;
        return -1;
    }
    return r;
}
static int socket(int d, int t, int p) { return (int)ret(syscall3(41, d, t, p)); }
static int setsockopt(int s, int l, int o, const void *v, socklen_t n) { return (int)ret(syscall5(54, s, l, o, (long)v, n)); }
static int getsockopt(int s, int l, int o, void *v, socklen_t *n) { return (int)ret(syscall5(55, s, l, o, (long)v, (long)n)); }
#endif
#ifndef SO_PEEK_OFF
#define SO_PEEK_OFF 42
#endif
static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello554:   ok   " : "hello554:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void one(const char *tag, int dom, int proto) {
    int s = socket(dom, SOCK_RAW, proto);
    int v = 7;
    socklen_t l = sizeof v;
    int g = getsockopt(s, SOL_SOCKET, SO_PEEK_OFF, &v, &l) == 0 ? 0 : -errno;
    int z = 0;
    int r = setsockopt(s, SOL_SOCKET, SO_PEEK_OFF, &z, sizeof z) == 0 ? 0 : -errno;
    snprintf(msg, sizeof msg, "%s: socket %d, get %d, set %d (>=0, %d, %d)", tag, s, g, r, -EOPNOTSUPP, -EOPNOTSUPP);
    check(s >= 0 && g == -EOPNOTSUPP && r == -EOPNOTSUPP, msg);
    if (s >= 0) close(s);
}
int main(void) {
    print("hello554: SO_PEEK_OFF on raw sockets\n");
    one("A: IPv4 raw ICMP", AF_INET, IPPROTO_ICMP);
    one("B: IPv6 raw ICMPv6", AF_INET6, IPPROTO_ICMPV6);
    one("C: IPv4 IPPROTO_RAW", AF_INET, IPPROTO_RAW);
    print(failures ? "hello554: FAIL\n" : "hello554: PASS\n");
    return failures ? 1 : 0;
}
