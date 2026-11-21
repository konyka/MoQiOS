/* hello468: what getsockopt(TCP_MAXSEG) and tcpi_snd_mss report (Linux tcp_getsockopt: tp->mss_cache, or the user's value on a
 * closed or listening socket that set one). Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n`
 * with lo up, MTU 1500, timestamps on):
 *   A. a new socket and a listener report 536 (TCP_MSS_DEFAULT);
 *   B. a loopback connection: 1448 on both ends (1460 less the 12-byte timestamp option), tcpi_snd_mss and tcpi_advmss 1448;
 *   C. TCP_MAXSEG 536 set before connect: 536 read back while unconnected, 524 once connected (both ends), tcpi_snd_mss 524. */
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
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
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
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello468:   ok   " : "hello468:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int maxseg(long s) {
    int m = -1, l = 4;
    getopt_(s, 6, 2, &m, &l);
    return m;
}
/* tcpi_snd_mss (offset 16) and tcpi_advmss (offset 84) of TCP_INFO. */
static unsigned info_mss(long s, int adv) {
    static unsigned char b[104];
    int l = sizeof b;
    memset(b, 0, sizeof b);
    getopt_(s, 6, 11, b, &l);
    unsigned v;
    memcpy(&v, b + (adv ? 84 : 16), 4);
    return v;
}
int main(void) {
    print("hello468: TCP_MAXSEG reports mss_cache\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4680 >> 8; a[3] = 4680 & 0xff; a[4] = 127; a[7] = 1;
    long fresh = sock(2, 1, 0);
    long l = sock(2, 1, 0);
    int one = 1;
    setopt_(l, 1, 2, &one, 4);
    long b = bind_(l, a, 16), li = listen_(l, 8);
    int m_fresh = maxseg(fresh), m_l = maxseg(l);
    snprintf(msg, sizeof msg, "A: bind %ld listen %ld; new socket %d listener %d (0 0 536 536)", b, li, m_fresh, m_l);
    check(b == 0 && li == 0 && m_fresh == 536 && m_l == 536, msg);

    long c = sock(2, 1, 0);
    long cr = connect_(c, a, 16);
    long s = accept_(l);
    int mc = maxseg(c), ms = maxseg(s);
    unsigned ic = info_mss(c, 0), ia = info_mss(c, 1);
    snprintf(msg, sizeof msg, "B: connect %ld accept %ld; TCP_MAXSEG %d %d, tcpi_snd_mss %u tcpi_advmss %u (0 >=0 1448 1448 1448 1448)", cr, s, mc, ms, ic, ia);
    check(cr == 0 && s >= 0 && mc == 1448 && ms == 1448 && ic == 1448 && ia == 1448, msg);

    long c3 = sock(2, 1, 0);
    int v = 536;
    long sr = setopt_(c3, 6, 2, &v, 4);
    int before = maxseg(c3);
    long cr3 = connect_(c3, a, 16);
    long s3 = accept_(l);
    int after = maxseg(c3), peer = maxseg(s3);
    unsigned i3 = info_mss(c3, 0);
    snprintf(msg, sizeof msg, "C: set 536 %ld, unconnected %d; connect %ld accept %ld; TCP_MAXSEG %d peer %d tcpi_snd_mss %u (0 536 0 >=0 524 524 524)", sr, before, cr3, s3, after, peer,
             i3);
    check(sr == 0 && before == 536 && cr3 == 0 && s3 >= 0 && after == 524 && peer == 524 && i3 == 524, msg);

    print(failures ? "hello468: FAIL\n" : "hello468: PASS\n");
    return failures ? 1 : 0;
}
