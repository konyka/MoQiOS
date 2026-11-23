/* hello499: connect on an IPv6 raw socket follows __ip6_datagram_connect.
 * A: IPV6_V6ONLY on a raw socket is EINVAL, and a link-local peer with no scope and no bound interface is EINVAL; B: ::1 connects
 * and send goes there; C: fe80::1 scoped to lo has no route (ENETUNREACH) and the ::1 peer stays (ip6_datagram_dst_update restores
 * it); D: a v4-mapped peer connects (the socket is not v6-only) and sending then fails ENETUNREACH. Measured with -DHOST in a new
 * network namespace with lo up. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long send_(long s, const void *b, long n) { return rc(send((int)s, b, (size_t)n, 0)); }
static long setopt_(long s, int lv, int o, int v) { return rc(setsockopt((int)s, lv, o, &v, 4)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long send_(long s, const void *b, long n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long setopt_(long s, int lv, int o, int v) { return syscall5(132, s, lv, o, (long)&v, 4); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello499:   ok   " : "hello499:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk6(unsigned char *a, const unsigned char *addr, unsigned int scope) {
    memset(a, 0, 28);
    a[0] = 10;
    memcpy(a + 8, addr, 16);
    a[24] = (unsigned char)scope; a[25] = (unsigned char)(scope >> 8);
}
int main(void) {
    print("hello499: IPv6 raw connect checks scope and route\n");
    static const unsigned char lo6[16] = { [15] = 1 };
    static const unsigned char ll6[16] = { 0xfe, 0x80, [15] = 1 };
    static const unsigned char mapped[16] = { [10] = 0xff, [11] = 0xff, 127, 0, 0, 1 };
    static const unsigned char echo[8] = { 128, 0, 0, 0, 0, 1, 0, 1 };
    unsigned char a[28];
    long s = sock(10, 3, 58);
    long only = setopt_(s, 41, 26, 1);
    mk6(a, ll6, 0);
    long ll = connect_(s, a, 28);
    snprintf(msg, sizeof msg, "A: socket %ld, IPV6_V6ONLY on raw %ld; link-local without scope %ld (>=0 -22 -22)", s, only, ll);
    check(s >= 0 && only == -22 && ll == -22, msg);
    mk6(a, lo6, 0);
    long lc = connect_(s, a, 28), ls = send_(s, echo, 8);
    snprintf(msg, sizeof msg, "B: ::1 connect %ld, send %ld (0 8)", lc, ls);
    check(lc == 0 && ls == 8, msg);
    mk6(a, ll6, 1);
    long sc = connect_(s, a, 28), ss = send_(s, echo, 8);
    snprintf(msg, sizeof msg, "C: fe80::1%%lo has no route %ld; the ::1 peer is kept, send %ld (-101 8)", sc, ss);
    check(sc == -101 && ss == 8, msg);
    mk6(a, mapped, 0);
    long mc = connect_(s, a, 28), ms = send_(s, echo, 8);
    snprintf(msg, sizeof msg, "D: v4-mapped connect %ld, then send %ld (0 -101)", mc, ms);
    check(mc == 0 && ms == -101, msg);
    close_(s);
    print(failures ? "hello499: FAIL\n" : "hello499: PASS\n");
    return failures ? 1 : 0;
}
