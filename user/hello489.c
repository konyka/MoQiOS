/* hello489: IP_LOCAL_PORT_RANGE (SOL_IP 51) limits automatic local-port allocation (inet_sk_get_local_port_range).
 * A: a UDP socket that has not named itself yet sends to a bound peer, then getsockname reports a port in its requested range.
 * B: a TCP client connects to a listener and gets a local port in its requested range. Both use ranges inside the default one.
 * Measured on the host (build with -DHOST, run in unshare --map-auto --map-root-user -n with lo up). */
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
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long name_(long s, void *a) { socklen_t l = 16; return rc(getsockname((int)s, a, &l)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long name_(long s, void *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello489:   ok   " : "hello489:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static int port_of(const unsigned char *a) { return (a[2] << 8) | a[3]; }
static long range(long s, int lo, int hi) {
    unsigned int r = (unsigned int)lo | ((unsigned int)hi << 16);
    return setopt_(s, 0, 51, &r, 4);
}
int main(void) {
    print("hello489: IP_LOCAL_PORT_RANGE limits automatic local-port allocation\n");
    unsigned char dst[16], local[16];
    mk4(dst, 51020);
    long ur = sock(2, 2, 0);
    long ub = bind_(ur, dst, 16);
    long us = sock(2, 2, 0);
    long urs = range(us, 51000, 51010);
    long sent = sendto_(us, "x", 1, dst, 16);
    long un = name_(us, local);
    int up = port_of(local);
    snprintf(msg, sizeof msg, "A: UDP bind peer %ld; set range %ld send %ld name %ld port %d (0 0 1 0 51000..51010)", ub, urs, sent, un, up);
    check(ub == 0 && urs == 0 && sent == 1 && un == 0 && up >= 51000 && up <= 51010, msg);
    close_(us);
    close_(ur);

    mk4(dst, 51120);
    long tl = sock(2, 1, 0);
    int one = 1;
    setopt_(tl, 1, 2, &one, 4);
    long tb = bind_(tl, dst, 16), tli = listen_(tl, 4);
    long tc = sock(2, 1, 0);
    long trs = range(tc, 51100, 51110);
    long cr = connect_(tc, dst, 16);
    long tn = name_(tc, local);
    int tp = port_of(local);
    long ta = cr == 0 ? accept_(tl) : -1000;
    snprintf(msg, sizeof msg, "B: TCP bind %ld listen %ld; set range %ld connect %ld name %ld port %d accept %ld (0 0 0 0 0 51100..51110 >=0)",
             tb, tli, trs, cr, tn, tp, ta);
    check(tb == 0 && tli == 0 && trs == 0 && cr == 0 && tn == 0 && tp >= 51100 && tp <= 51110 && ta >= 0, msg);
    close_(ta);
    close_(tc);
    close_(tl);
    print(failures ? "hello489: FAIL\n" : "hello489: PASS\n");
    return failures ? 1 : 0;
}
