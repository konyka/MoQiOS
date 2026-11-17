/* hello404: IPV6_HDRINCL and IPPROTO_RAW on IPv6 raw sockets, and the ICMPv6 parameter problem for a next header nobody handles
 * (Linux inet6_create, do_rawv6_setsockopt, rawv6_send_hdrinc, ip6_protocol_deliver_rcu). Measured on the host (build with -DHOST,
 * run as root in `unshare --map-auto --map-root-user -n` with only lo up and its MTU set to 1500, as MoQiOS's):
 *   A. socket(AF_INET6, SOCK_RAW, 255) works and starts with IPV6_HDRINCL 1 (IPV6_CHECKSUM -1); a protocol-253 socket starts with
 *      0, setting it to 1 (or 2) reads back 1, a 2-byte optval is EINVAL; on UDP and TCP sockets it is ENOPROTOOPT both ways;
 *   S. an IPPROTO_RAW send of a whole 44-byte IPv6 packet (next header 252, payload "abcd") to ::1 returns 44 and a protocol-252
 *      socket gets the 4-byte payload; a payload length of 2 in the header delivers 2 bytes, one past the data (8) nothing; a
 *      source of :: in the header goes out as written; 39 bytes are EINVAL, 0 bytes EINVAL, 40 bytes (header only, payload length 0)
 *      deliver an empty copy;
 *      a version 4 header is dropped; a header hop limit of 7 is kept; past the MTU (1501) EMSGSIZE; no destination EDESTADDRREQ;
 *      sin6_port 17 on an IPPROTO_RAW socket is accepted, 256 is EINVAL;
 *   H. a protocol-253 socket with IPV6_HDRINCL set sends a whole packet of next header 252 the same way;
 *   P. a packet of next header 252 that no raw socket takes gets an ICMPv6 parameter problem (type 4 code 1, pointer 6, 52 bytes
 *      quoting the packet) at an ICMPv6 raw socket; with a protocol-252 socket open, it does not;
 *   N. an IPPROTO_RAW socket with IPV6_HDRINCL cleared sends "ab" as protocol 255 and receives that copy itself. */
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, a, (socklen_t *)al)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return syscall6(122, s, (long)b, n, 0x40, (long)a, (long)al); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello404:   ok   " : "hello404:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char buf[1600];
static const unsigned char lo6[28] = { 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
static long rd(long s) { unsigned char a[28]; int l = 28; return recvfrom_(s, buf, sizeof buf, a, &l); }
static void drain(long s) { while (rd(s) >= 0) {} }
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v, int l) { return setopt(s, lv, o, &v, l); }
/* A 44-byte IPv6 packet ::1 -> ::1 of next header `nh`, payload length 4, payload "abcd". */
static unsigned char pk[1600];
static void mk(int nh) {
    memset(pk, 0, 44);
    pk[0] = 0x60;
    pk[5] = 4;
    pk[6] = (unsigned char)nh;
    pk[7] = 64;
    pk[23] = 1;
    pk[39] = 1;
    memcpy(pk + 40, "abcd", 4);
}
/* The first ICMPv6 parameter problem queued at `s`: its length, or -1; code, pointer and quoted next header land in the out args. */
static long param_problem(long s, int *code, int *ptr, int *qnh) {
    for (int i = 0; i < 8; i++) {
        long n = rd(s);
        if (n < 0) return -1;
        if (n >= 48 && buf[0] == 4) {
            *code = buf[1];
            *ptr = buf[4] << 24 | buf[5] << 16 | buf[6] << 8 | buf[7];
            *qnh = buf[8 + 6];
            return n;
        }
    }
    return -1;
}
int main(void) {
    print("hello404: IPV6_HDRINCL, IPPROTO_RAW and the ICMPv6 parameter problem\n");
    long r = sock(10, 3, 255), a = sock(10, 3, 253), u = sock(10, 2, 0), t = sock(10, 1, 0);
    int r_h = geti(r, 41, 36), r_c = geti(r, 41, 7), a_h0 = geti(a, 41, 36);
    long a_s1 = seti(a, 41, 36, 1, 4);
    int a_h1 = geti(a, 41, 36);
    long a_s2 = seti(a, 41, 36, 2, 4);
    int a_h2 = geti(a, 41, 36);
    long a_short = seti(a, 41, 36, 1, 2);
    seti(a, 41, 36, 0, 4);
    int a_h3 = geti(a, 41, 36);
    long us = seti(u, 41, 36, 1, 4), ts = seti(t, 41, 36, 1, 4);
    int ug = geti(u, 41, 36), tg = geti(t, 41, 36);
    snprintf(msg, sizeof msg, "A: socket(255) %ld IPV6_HDRINCL %d IPV6_CHECKSUM %d (1 -1); 253: %d, set 1 %ld reads %d, set 2 %ld reads %d, 2 bytes %ld (-22), cleared %d; UDP set %ld get %d, TCP set %ld get %d (-92)",
             r, r_h, r_c, a_h0, a_s1, a_h1, a_s2, a_h2, a_short, a_h3, us, ug, ts, tg);
    check(r >= 0 && r_h == 1 && r_c == -1 && a_h0 == 0 && a_s1 == 0 && a_h1 == 1 && a_s2 == 0 && a_h2 == 1 && a_short == -22 && a_h3 == 0 && us == -92 && ug == -92 && ts == -92 && tg == -92, msg);
    close_(u);
    close_(t);

    long x = sock(10, 3, 252);
    drain(x);
    mk(252);
    long s44 = sendto_(r, pk, 44, lo6, 28);
    nap();
    long n44 = rd(x);
    int pay = n44 == 4 && memcmp(buf, "abcd", 4) == 0;
    pk[5] = 2;
    long s2 = sendto_(r, pk, 44, lo6, 28);
    nap();
    long n2 = rd(x);
    pk[5] = 8;
    long s8 = sendto_(r, pk, 44, lo6, 28);
    nap();
    long n8 = rd(x);
    mk(252);
    memset(pk + 8, 0, 16);
    long sz = sendto_(r, pk, 44, lo6, 28);
    nap();
    long nz = rd(x);
    mk(252);
    long s39 = sendto_(r, pk, 39, lo6, 28), s0 = sendto_(r, pk, 0, lo6, 28);
    pk[5] = 0;
    long s40 = sendto_(r, pk, 40, lo6, 28);
    nap();
    long n40 = rd(x);
    pk[0] = 0x40;
    long sv = sendto_(r, pk, 44, lo6, 28);
    nap();
    long nv = rd(x);
    mk(252);
    pk[7] = 7;
    long sh = sendto_(r, pk, 44, lo6, 28);
    nap();
    long nh = rd(x);
    mk(252);
    pk[4] = 1460 >> 8;
    pk[5] = 1460 & 255;
    long sbig = sendto_(r, pk, 1501, lo6, 28);
    long snd = sendto_(r, pk, 44, 0, 0);
    mk(252);
    unsigned char ap[28];
    memcpy(ap, lo6, 28);
    ap[3] = 17;
    long sp17 = sendto_(r, pk, 44, ap, 28);
    nap();
    drain(x);
    ap[2] = 1;
    ap[3] = 0;
    long sp256 = sendto_(r, pk, 44, ap, 28);
    snprintf(msg, sizeof msg, "S: 44 bytes %ld got %ld payload %d (44 4 1); payload length 2: %ld got %ld (2); 8: %ld got %ld (-11); source :: %ld got %ld (4); 39 %ld, 0 %ld (-22 -22); 40 %ld got %ld (0); version 4 %ld got %ld (-11); hop limit 7 %ld got %ld (4); 1501 %ld (-90); no destination %ld (-89); port 17 %ld, port 256 %ld (-22)",
             s44, n44, pay, s2, n2, s8, n8, sz, nz, s39, s0, s40, n40, sv, nv, sh, nh, sbig, snd, sp17, sp256);
    check(s44 == 44 && pay && s2 == 44 && n2 == 2 && s8 == 44 && n8 == -11 && sz == 44 && nz == 4 && s39 == -22 && s0 == -22 && s40 == 40 && n40 == 0 && sv == 44 && nv == -11 && sh == 44 && nh == 4 && sbig == -90 && snd == -89 && sp17 == 44 && sp256 == -22, msg);

    seti(a, 41, 36, 1, 4);
    drain(x);
    mk(252);
    long ha = sendto_(a, pk, 44, lo6, 28);
    nap();
    long hn = rd(x);
    seti(a, 41, 36, 0, 4);
    snprintf(msg, sizeof msg, "H: a protocol-253 socket with IPV6_HDRINCL sends a next header 252 packet %ld, the 252 socket gets %ld (44 4)", ha, hn);
    check(ha == 44 && hn == 4, msg);

    long ic = sock(10, 3, 58);
    drain(ic);
    mk(252);
    long pw = sendto_(r, pk, 44, lo6, 28);
    nap();
    int c1 = -1, p1 = -1, q1 = -1;
    long with = param_problem(ic, &c1, &p1, &q1);
    close_(x);
    drain(ic);
    long pn = sendto_(r, pk, 44, lo6, 28);
    nap();
    int c2 = -1, p2 = -1, q2 = -1;
    long none = param_problem(ic, &c2, &p2, &q2);
    snprintf(msg, sizeof msg, "P: with a 252 socket sent %ld, parameter problem %ld (-1); without: sent %ld, parameter problem %ld bytes code %d pointer %d next header %d (52 1 6 252)",
             pw, with, pn, none, c2, p2, q2);
    check(pw == 44 && with == -1 && pn == 44 && none == 52 && c2 == 1 && p2 == 6 && q2 == 252, msg);
    close_(ic);

    seti(r, 41, 36, 0, 4);
    int rh = geti(r, 41, 36);
    drain(r);
    long ns = sendto_(r, "ab", 2, lo6, 28);
    nap();
    long nn = rd(r);
    snprintf(msg, sizeof msg, "N: IPPROTO_RAW with IPV6_HDRINCL cleared (reads %d) sends \"ab\" %ld and gets its copy %ld (0 2 2)", rh, ns, nn);
    check(rh == 0 && ns == 2 && nn == 2 && memcmp(buf, "ab", 2) == 0, msg);
    close_(r);
    close_(a);

    print(failures == 0 ? "hello404: PASS\n" : "hello404: FAIL\n");
    return failures == 0 ? 0 : 1;
}
