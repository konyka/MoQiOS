/* hello410: IPv6 extension headers on input (Linux ipv6_parse_hopopts, ipv6_destopt_rcv, ip6_parse_tlv, ip6_protocol_deliver_rcu).
 * Hop-by-hop and destination-options headers in front of the upper-layer header are stepped over; an unknown option acts on its
 * top two bits; a raw socket of the extension header sees the packet from that header on. Packets are sent whole through an
 * IPPROTO_RAW socket to ::1. Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with
 * lo up and its MTU set to 1500):
 *   D. a UDP datagram behind a destination-options header (PadN) reaches the bound UDP socket ("data"); a protocol-60 raw socket
 *      gets 20 bytes starting with next header 17; a protocol-17 raw socket gets the 12-byte UDP datagram;
 *   H. the same behind a hop-by-hop header reaches the UDP socket; Pad1 options and an unknown option with top bits 00 are skipped;
 *   O. an unknown option with top bits 01 drops the packet silently; with top bits 10 it is dropped and a parameter problem
 *      (type 4 code 2, pointer 42: the option) comes back;
 *   N. "no next header" (59) after destination options is dropped without an answer;
 *   P. an unknown next header 252 after destination options gets a parameter problem code 1 pointing at the destination-options
 *      header's next-header field (40). */
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
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, a, (socklen_t *)al)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return syscall6(122, s, (long)b, n, 0x40, (long)a, (long)al); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello410:   ok   " : "hello410:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char buf[1600];
static unsigned char lo6[28] = { 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
static long rd(long s) { unsigned char a[28]; int l = 28; return recvfrom_(s, buf, sizeof buf, a, &l); }
static void drain(long s) { while (rd(s) >= 0) {} }
static unsigned char pk[64];
/* ::1 -> ::1, next header `nh`, then one 8-byte extension header (its next header `inner`, option bytes `o`) and a UDP datagram
 * 12345 -> 8080 carrying "data". */
static int mk(int nh, int inner, const unsigned char *o) {
    memset(pk, 0, sizeof pk);
    pk[0] = 0x60; pk[5] = 20; pk[6] = (unsigned char)nh; pk[7] = 64; pk[23] = 1; pk[39] = 1;
    unsigned char *e = pk + 40;
    e[0] = (unsigned char)inner;
    memcpy(e + 2, o, 6);
    unsigned char *u = pk + 48;
    u[0] = 0x30; u[1] = 0x39; u[2] = 0x1f; u[3] = 0x90; u[5] = 12;
    memcpy(u + 8, "data", 4);
    unsigned long s = 2 + 12 + 17;
    for (int i = 0; i < 12; i += 2) s += (unsigned long)(u[i] << 8 | u[i + 1]);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    s = ~s & 0xffff;
    u[6] = (unsigned char)(s >> 8); u[7] = (unsigned char)s;
    return 60;
}
/* The first parameter problem at `s`: its code and pointer, or -1. */
static long pp(long s, int *code) {
    for (int i = 0; i < 8; i++) {
        long n = rd(s);
        if (n < 0) return -1;
        if (buf[0] == 4) { *code = buf[1]; return buf[4] << 24 | buf[5] << 16 | buf[6] << 8 | buf[7]; }
    }
    return -1;
}
int main(void) {
    print("hello410: IPv6 extension headers on input\n");
    static const unsigned char padn[6] = { 1, 4, 0, 0, 0, 0 }, pad1[6] = { 0, 0, 0, 0, 0, 0 };
    static const unsigned char u00[6] = { 0x01, 4, 0, 0, 0, 0 }, u01[6] = { 0x40, 4, 0, 0, 0, 0 }, u10[6] = { 0x80, 4, 0, 0, 0, 0 };
    long r = sock(10, 3, 255), u = sock(10, 2, 0), r60 = sock(10, 3, 60), r17 = sock(10, 3, 17), ic = sock(10, 3, 58);
    unsigned char ua[28];
    memcpy(ua, lo6, 28);
    ua[2] = 0x1f; ua[3] = 0x90;
    long ub = bind_(u, ua, 28);
    drain(u); drain(r60); drain(r17); drain(ic);

    long sd = sendto_(r, pk, mk(60, 17, padn), lo6, 28);
    nap();
    long du = rd(u);
    int dok = du == 4 && memcmp(buf, "data", 4) == 0;
    long d60 = rd(r60);
    int d60nh = d60 > 0 ? buf[0] : -1;
    long d17 = rd(r17);
    int d17p = d17 >= 2 ? (buf[0] << 8 | buf[1]) : -1;
    snprintf(msg, sizeof msg, "D: bind %ld send %ld; UDP got %ld \"data\" %d; raw 60 got %ld starting %d; raw 17 got %ld from port %d (0 60 4 1 20 17 12 12345)", ub, sd, du, dok, d60, d60nh, d17, d17p);
    check(ub == 0 && sd == 60 && dok && d60 == 20 && d60nh == 17 && d17 == 12 && d17p == 12345, msg);
    drain(r17);

    sendto_(r, pk, mk(0, 17, padn), lo6, 28);
    nap();
    long hu = rd(u);
    sendto_(r, pk, mk(60, 17, pad1), lo6, 28);
    nap();
    long hp1 = rd(u);
    sendto_(r, pk, mk(60, 17, u00), lo6, 28);
    nap();
    long h00 = rd(u);
    snprintf(msg, sizeof msg, "H: behind hop-by-hop UDP got %ld; Pad1 %ld; unknown option 00 %ld (4 4 4)", hu, hp1, h00);
    check(hu == 4 && hp1 == 4 && h00 == 4, msg);

    drain(ic);
    sendto_(r, pk, mk(60, 17, u01), lo6, 28);
    nap();
    long o01 = rd(u);
    int c01 = -1;
    long p01 = pp(ic, &c01);
    sendto_(r, pk, mk(60, 17, u10), lo6, 28);
    nap();
    long o10 = rd(u);
    int c10 = -1;
    long p10 = pp(ic, &c10);
    snprintf(msg, sizeof msg, "O: option 01: UDP %ld, parameter problem %ld; option 10: UDP %ld, parameter problem code %d pointer %ld (-11 -1 -11 2 42)", o01, p01, o10, c10, p10);
    check(o01 == -11 && p01 == -1 && o10 == -11 && c10 == 2 && p10 == 42, msg);

    drain(ic);
    sendto_(r, pk, mk(60, 59, padn), lo6, 28);
    nap();
    long nu = rd(u);
    int nc = -1;
    long np = pp(ic, &nc);
    snprintf(msg, sizeof msg, "N: no next header: UDP %ld, parameter problem %ld (-11 -1)", nu, np);
    check(nu == -11 && np == -1, msg);

    drain(ic);
    sendto_(r, pk, mk(60, 252, padn), lo6, 28);
    nap();
    int pc = -1;
    long ptr = pp(ic, &pc);
    snprintf(msg, sizeof msg, "P: next header 252 after destination options: parameter problem code %d pointer %ld (1 40)", pc, ptr);
    check(pc == 1 && ptr == 40, msg);

    close_(r); close_(u); close_(r60); close_(r17); close_(ic);
    print(failures == 0 ? "hello410: PASS\n" : "hello410: FAIL\n");
    return failures == 0 ? 0 : 1;
}
