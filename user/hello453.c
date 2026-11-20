/* hello453: IPv6 fragments (Linux ip6_fragment / ipv6_frag_rcv → ip6_frag_queue / ip6_frag_reasm): a UDP datagram over the path MTU
 * leaves in pieces behind a Fragment header (next header 44) and is reassembled; pieces written by hand through a raw socket are put
 * back together too. Measured on the host (build with -DHOST, run in `unshare -n` with lo up and its MTU set to 1500):
 *   A. 1453, 3000, 30000 and 65527 bytes to [::1]:4530 are sent whole and received whole with the same bytes;
 *   B. 65528 bytes are EMSGSIZE;
 *   C. IPV6_MTU_DISCOVER DO: 3000 bytes are EMSGSIZE; DONT: they go through;
 *   D. three pieces (1232 + 1232 + 544 bytes of a 3008-byte UDP datagram, each packet within the 1280-byte IPv6 minimum MTU, so an
 *      earlier test that lowered the path MTU to ::1 cannot refuse them) sent through a raw IPPROTO_FRAGMENT socket arrive whole, in
 *      order and last-first; an atomic fragment (offset 0, no M flag) is delivered as it is;
 *   E. a middle piece overlapping the first discards the datagram;
 *   F. a non-last piece whose length is not a multiple of 8 (1228 bytes) draws a parameter problem (code 0) and is dropped;
 *   G. an ordinary datagram afterwards still arrives;
 *   H. the fragmentable part may begin with another extension header: pieces whose Fragment header names a Destination Options
 *      header (8 bytes of PadN) in front of the UDP datagram are reassembled, the options stepped over, and the 3000 bytes arrive. */
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
static long setopt_(long s, int lv, int o, int v) { return syscall5(132, s, lv, o, (long)&v, 4); }
static void nap(void) { long t[2] = { 0, 30000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello453:   ok   " : "hello453:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char out[65600];
static unsigned char in[65600];
static unsigned char dgram[3008];
static long fr, icmp;
static unsigned char dst[28];
/* A UDP datagram [::1]:4531 -> [::1]:4530 with 3000 payload bytes seeded by `seed` (checksum over the IPv6 pseudo-header). */
static void build(int seed) {
    for (int i = 0; i < 3000; i++) dgram[8 + i] = (unsigned char)(i * 5 + seed);
    dgram[0] = 4531 >> 8; dgram[1] = 4531 & 0xff; dgram[2] = 4530 >> 8; dgram[3] = 4530 & 0xff;
    dgram[4] = 3008 >> 8; dgram[5] = 3008 & 0xff; dgram[6] = 0; dgram[7] = 0;
    unsigned int s = 1 + 1 + 3008 + 17;
    for (int i = 0; i + 1 < 3008; i += 2) s += (unsigned int)(dgram[i] << 8 | dgram[i + 1]);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    unsigned short c = (unsigned short)~s;
    if (c == 0) c = 0xffff;
    dgram[6] = (unsigned char)(c >> 8); dgram[7] = (unsigned char)c;
}
/* Piece [off, off+len) of dgram behind a Fragment header (next header UDP, id `id`, M when `more`), written through the raw
 * IPPROTO_FRAGMENT socket: the kernel puts the IPv6 header in front with next header 44. */
static void piece(unsigned int id, int off, int len, int more) {
    unsigned char p[1600];
    p[0] = 17; p[1] = 0;
    int fo = off | (more ? 1 : 0);
    p[2] = (unsigned char)(fo >> 8); p[3] = (unsigned char)fo;
    p[4] = (unsigned char)(id >> 24); p[5] = (unsigned char)(id >> 16); p[6] = (unsigned char)(id >> 8); p[7] = (unsigned char)id;
    memcpy(p + 8, dgram + off, (unsigned long)len);
    sendto_(fr, p, 8 + len, dst, 28);
}
int main(void) {
    print("hello453: IPv6 fragments\n");
    for (int i = 0; i < (int)sizeof out; i++) out[i] = (unsigned char)(i * 11 + 3);
    unsigned char a[28];
    memset(a, 0, 28);
    a[0] = 10; a[2] = 4530 >> 8; a[3] = 4530 & 0xff; a[23] = 1;
    memcpy(dst, a, 28);
    dst[2] = 0; dst[3] = 0;
    long u = sock(10, 2, 0);
    long ub = bind_(u, a, 28);
    long s = sock(10, 2, 0);
    fr = sock(10, 3, 44);
    icmp = sock(10, 3, 58);

    static const int sizes[4] = { 1453, 3000, 30000, 65527 };
    int ok = u >= 0 && ub == 0 && s >= 0;
    int at = snprintf(msg, sizeof msg, "A: bind %ld;", ub);
    for (int k = 0; k < 4; k++) {
        long n = sendto_(s, out, sizes[k], a, 28);
        nap();
        long m = recv_(u, in, sizeof in);
        int same = m == sizes[k] && memcmp(in, out, (unsigned long)sizes[k]) == 0;
        if (n != sizes[k] || !same) ok = 0;
        at += snprintf(msg + at, sizeof msg - (unsigned long)at, " %d: sent %ld got %ld same %d;", sizes[k], n, m, same);
    }
    check(ok, msg);

    long b = sendto_(s, out, 65528, a, 28);
    snprintf(msg, sizeof msg, "B: 65528 bytes: %ld (-90)", b);
    check(b == -90, msg);

    setopt_(s, 41, 23, 2);
    long c1 = sendto_(s, out, 3000, a, 28);
    setopt_(s, 41, 23, 0);
    long c2 = sendto_(s, out, 3000, a, 28);
    nap();
    long c3 = recv_(u, in, sizeof in);
    snprintf(msg, sizeof msg, "C: DO %ld; DONT %ld, received %ld (-90; 3000 3000)", c1, c2, c3);
    check(c1 == -90 && c2 == 3000 && c3 == 3000, msg);

    build(1);
    piece(0x1001, 0, 1232, 1);
    piece(0x1001, 1232, 1232, 1);
    piece(0x1001, 2464, 544, 0);
    nap();
    long d1 = recv_(u, in, sizeof in);
    int s1 = d1 == 3000 && memcmp(in, dgram + 8, 3000) == 0;
    build(2);
    piece(0x1002, 2464, 544, 0);
    piece(0x1002, 0, 1232, 1);
    piece(0x1002, 1232, 1232, 1);
    nap();
    long d2 = recv_(u, in, sizeof in);
    int s2 = d2 == 3000 && memcmp(in, dgram + 8, 3000) == 0;
    /* An atomic fragment: a whole small UDP datagram behind a Fragment header with offset 0 and no M flag. */
    unsigned char small[8 + 8 + 4] = { 17, 0, 0, 0, 0, 0, 0x10, 0x03, 4531 >> 8, 4531 & 0xff, 4530 >> 8, 4530 & 0xff, 0, 12, 0, 0, 'a', 't', 'o', 'm' };
    unsigned int cs = 1 + 1 + 12 + 17;
    for (int i = 8; i < 20; i += 2) cs += (unsigned int)(small[i] << 8 | small[i + 1]);
    while (cs >> 16) cs = (cs & 0xffff) + (cs >> 16);
    small[14] = (unsigned char)(~cs >> 8); small[15] = (unsigned char)~cs;
    long d3s = sendto_(fr, small, sizeof small, dst, 28);
    nap();
    long d3 = recv_(u, in, sizeof in);
    snprintf(msg, sizeof msg, "D: fragment socket %d; in order %ld same %d; last first %ld same %d; atomic fragment sent %ld got %ld \"%.4s\" (1; 3000 1; 3000 1; 20 4 atom)",
             fr >= 0, d1, s1, d2, s2, d3s, d3, d3 == 4 ? (char *)in : "");
    check(fr >= 0 && d1 == 3000 && s1 && d2 == 3000 && s2 && d3s == 20 && d3 == 4 && memcmp(in, "atom", 4) == 0, msg);

    build(3);
    piece(0x1004, 0, 1232, 1);
    piece(0x1004, 1224, 1232, 1);
    piece(0x1004, 2464, 544, 0);
    piece(0x1004, 1232, 1232, 1);
    nap();
    long e = recv_(u, in, sizeof in);
    snprintf(msg, sizeof msg, "E: a middle piece overlapping the first: %ld (-11)", e);
    check(e == -11, msg);

    while (recv_(icmp, in, sizeof in) >= 0) {}
    build(4);
    piece(0x1005, 0, 1228, 1);
    nap();
    long f = recv_(icmp, in, sizeof in);
    int ftype = f >= 8 ? in[0] : -1, fcode = f >= 8 ? in[1] : -1;
    unsigned int fptr = f >= 8 ? (unsigned int)(in[4] << 24 | in[5] << 16 | in[6] << 8 | in[7]) : 0;
    piece(0x1005, 1232, 1232, 1);
    piece(0x1005, 2464, 544, 0);
    nap();
    long f2 = recv_(u, in, sizeof in);
    snprintf(msg, sizeof msg, "F: a 1228-byte non-last piece: ICMPv6 %ld type %d code %d pointer %u; the datagram %ld (>0 4 0 4; -11)", f, ftype, fcode, fptr, f2);
    check(f >= 8 && ftype == 4 && fcode == 0 && fptr == 4 && f2 == -11, msg);

    long g1 = sendto_(s, "whole", 5, a, 28);
    nap();
    long g = recv_(u, in, sizeof in);
    snprintf(msg, sizeof msg, "G: an ordinary datagram: sent %ld, got %ld (5 5)", g1, g);
    check(g1 == 5 && g == 5 && memcmp(in, "whole", 5) == 0, msg);

    /* H: Destination Options (next header UDP, length 0, a 6-byte PadN) then the datagram, cut into 1232 + 1232 + 552 bytes. */
    build(5);
    static unsigned char opt[3016];
    opt[0] = 17; opt[1] = 0; opt[2] = 1; opt[3] = 4; opt[4] = 0; opt[5] = 0; opt[6] = 0; opt[7] = 0;
    memcpy(opt + 8, dgram, 3008);
    static const int hoff[3] = { 0, 1232, 2464 }, hlen[3] = { 1232, 1232, 552 };
    for (int k = 0; k < 3; k++) {
        unsigned char p[1600];
        p[0] = 60; p[1] = 0;
        int fo = hoff[k] | (k < 2 ? 1 : 0);
        p[2] = (unsigned char)(fo >> 8); p[3] = (unsigned char)fo;
        p[4] = 0; p[5] = 0; p[6] = 0x10; p[7] = 0x06;
        memcpy(p + 8, opt + hoff[k], (unsigned long)hlen[k]);
        sendto_(fr, p, 8 + hlen[k], dst, 28);
    }
    nap();
    long h = recv_(u, in, sizeof in);
    int hs = h == 3000 && memcmp(in, dgram + 8, 3000) == 0;
    snprintf(msg, sizeof msg, "H: Destination Options after the Fragment header: got %ld same %d (3000 1)", h, hs);
    check(h == 3000 && hs, msg);

    print(failures ? "hello453: FAIL\n" : "hello453: PASS\n");
    return failures ? 1 : 0;
}
