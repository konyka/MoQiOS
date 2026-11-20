/* hello452: IPv4 UDP datagrams larger than the path MTU are fragmented (Linux ip_append_data / ip_fragment, ip_finish_output2):
 * with IP_MTU_DISCOVER WANT (the default for UDP), DONT or OMIT the datagram leaves in pieces and the receiver reassembles it;
 * DO and PROBE refuse it with EMSGSIZE; nothing over 65507 bytes of payload is accepted. Measured on the host (build with -DHOST,
 * run in `unshare -n` with lo up and its MTU set to 1500, the MTU this kernel's lo and NIC use):
 *   A. 1473, 3000, 8000, 30000 and 65507 bytes to 127.0.0.1:4520 are sent whole (send returns the length) and received whole with
 *      the same bytes;
 *   B. 65508 bytes are EMSGSIZE;
 *   C. IP_PMTUDISC_DONT and OMIT: 3000 bytes go through; PROBE and DO: EMSGSIZE;
 *   D. a raw IPPROTO_UDP socket sees the 3000-byte datagram reassembled (it takes the datagram after ip_defrag): one 3028-byte
 *      packet whose header says 3028 and no fragment bits, not three pieces;
 *   E. on the raw socket, MSG_PEEK|MSG_TRUNC with a 100-byte buffer reports 3028; a recv into 1500 bytes returns 1500 and consumes
 *      the datagram (the next recv is EAGAIN). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static long recvf(long s, void *b, long n, int fl) { return rc(recv((int)s, b, (size_t)n, fl)); }
static long setopt_(long s, int lv, int o, int v) { return rc(setsockopt((int)s, lv, o, &v, 4)); }
static void nap(void) { struct timespec t = { 0, 30000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long recvf(long s, void *b, long n, int fl) { return syscall6(122, s, (long)b, n, fl, 0, 0); }
static long setopt_(long s, int lv, int o, int v) { return syscall5(132, s, lv, o, (long)&v, 4); }
static void nap(void) { long t[2] = { 0, 30000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello452:   ok   " : "hello452:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char out[65600];
static unsigned char in[65600];
int main(void) {
    print("hello452: IPv4 UDP datagrams over the MTU are fragmented\n");
    for (int i = 0; i < (int)sizeof out; i++) out[i] = (unsigned char)(i * 13 + 5);
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4520 >> 8; a[3] = 4520 & 0xff; a[4] = 127; a[7] = 1;
    long u = sock(2, 2, 0);
    long ub = bind_(u, a, 16);
    long s = sock(2, 2, 0);
    long raw = sock(2, 3, 17);

    static const int sizes[5] = { 1473, 3000, 8000, 30000, 65507 };
    int ok = u >= 0 && ub == 0 && s >= 0;
    int at = snprintf(msg, sizeof msg, "A: bind %ld;", ub);
    for (int k = 0; k < 5; k++) {
        long n = sendto_(s, out, sizes[k], a, 16);
        nap();
        long m = recv_(u, in, sizeof in);
        int same = m == sizes[k] && memcmp(in, out, (unsigned long)sizes[k]) == 0;
        if (n != sizes[k] || !same) ok = 0;
        at += snprintf(msg + at, sizeof msg - (unsigned long)at, " %d: sent %ld got %ld same %d;", sizes[k], n, m, same);
    }
    check(ok, msg);

    long b = sendto_(s, out, 65508, a, 16);
    snprintf(msg, sizeof msg, "B: 65508 bytes: %ld (-90)", b);
    check(b == -90, msg);

    long c[4];
    long cg[4];
    static const int modes[4] = { 0, 5, 3, 2 };
    for (int k = 0; k < 4; k++) {
        setopt_(s, 0, 10, modes[k]);
        c[k] = sendto_(s, out, 3000, a, 16);
        nap();
        cg[k] = recv_(u, in, sizeof in);
    }
    snprintf(msg, sizeof msg, "C: DONT %ld/%ld, OMIT %ld/%ld, PROBE %ld, DO %ld (3000/3000 3000/3000 -90 -90)", c[0], cg[0], c[1], cg[1], c[2], c[3]);
    check(c[0] == 3000 && cg[0] == 3000 && c[1] == 3000 && cg[1] == 3000 && c[2] == -90 && c[3] == -90, msg);

    setopt_(s, 0, 10, 1);
    while (recv_(raw, in, sizeof in) >= 0) {}
    long dn = sendto_(s, out, 3000, a, 16);
    nap();
    long d1 = recv_(raw, in, sizeof in);
    int dtot = d1 >= 20 ? (in[2] << 8 | in[3]) : -1;
    int dfrag = d1 >= 20 ? ((in[6] << 8 | in[7]) & 0x3fff) : -1;
    long d2 = recv_(raw, in, sizeof in);
    while (recv_(u, in, sizeof in) >= 0) {}
    snprintf(msg, sizeof msg, "D: raw UDP socket %d; sent %ld; it sees %ld bytes, total length %d, fragment bits %d, then %ld (1 3000 3028 3028 0 -11)", raw >= 0, dn, d1,
             dtot, dfrag, d2);
    check(raw >= 0 && dn == 3000 && d1 == 3028 && dtot == 3028 && dfrag == 0 && d2 == -11, msg);

    while (recv_(raw, in, sizeof in) >= 0) {}
    long en = sendto_(s, out, 3000, a, 16);
    nap();
    long e1 = recvf(raw, in, 100, 0x40 | 0x20 | 0x02);
    long e2 = recvf(raw, in, 1500, 0x40);
    long e3 = recv_(raw, in, sizeof in);
    while (recv_(u, in, sizeof in) >= 0) {}
    snprintf(msg, sizeof msg, "E: sent %ld; MSG_PEEK|MSG_TRUNC into 100 bytes %ld; recv into 1500 %ld; then %ld (3000 3028 1500 -11)", en, e1, e2, e3);
    check(en == 3000 && e1 == 3028 && e2 == 1500 && e3 == -11, msg);

    print(failures ? "hello452: FAIL\n" : "hello452: PASS\n");
    return failures ? 1 : 0;
}
