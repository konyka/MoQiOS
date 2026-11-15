/* hello361: IPv6 UDP multicast: the IPV6_MULTICAST_* options, group membership (IPV6_ADD/DROP_MEMBERSHIP) and local delivery of a
 * datagram sent to a group this host has joined (Linux ipv6_sock_mc_join/drop, inet6_mc_check, __udp6_lib_mcast_deliver,
 * ip6_finish_output2 looping a multicast datagram back when the outgoing interface is a member). Measured on the host (build with
 * -DHOST, run in `unshare -rn` with a multicast dummy link d0, which is interface 2 there as eth0 is in MoQiOS:
 *   ip link add d0 type dummy; ip link set d0 multicast on up; ip link set lo up;
 *   ip -6 addr add 2001:db8:1::7/64 dev d0 nodad; ip -6 route add default via 2001:db8:1::1 dev d0; every socket IPV6_V6ONLY):
 *   O. a UDP socket: IPV6_MULTICAST_HOPS 1, LOOP 1, IF 0, ALL 1 by default; HOPS 7 reads 7, -1 restores 1, 256 is EINVAL;
 *      LOOP 2 is EINVAL, 0 reads 0; IF 99 is ENODEV, 2 reads 2;
 *   J. ADD_MEMBERSHIP with 19 bytes is EINVAL, of 2001:db8::1 EINVAL, on interface 99 ENODEV; ff0e::101 on 0 succeeds, again (on 0
 *      or 2) EADDRINUSE; DROP of ff0e::102 is EADDRNOTAVAIL, of ff0e::101 succeeds, again EADDRNOTAVAIL;
 *   T. a TCP socket: ADD_MEMBERSHIP is EPROTO, setting IPV6_MULTICAST_HOPS ENOPROTOOPT, reading it 1;
 *   D1. on port 19101 (all SO_REUSEADDR): s1 [::] and s2 [::] join ff0e::101, s3 [ff0e::101] joins it, s4 [ff0e::102] does not,
 *       s5 [::] sets IPV6_MULTICAST_ALL 0; a datagram to [ff0e::101]:19101 reaches s1, s2 and s3 once each, s4 and s5 not;
 *   D2. s1 leaves the group: the next one still reaches s1 (MULTICAST_ALL, the host is still a member), s2 and s3;
 *   D3. one to [ff0e::102]:19101 (nobody joined it) reaches no socket, not even s4;
 *   D4. with IPV6_MULTICAST_LOOP 0 on the sender one to ff0e::101 reaches no socket;
 *   D5. after s2 and s3 close (no member left) one to ff0e::101 reaches neither s1 nor s5. */
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
static long v6only(long s) {
    int one = 1;
    if (s >= 0) setsockopt((int)s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one); /* MoQiOS AF_INET6 sockets are always V6ONLY */
    return s;
}
static long usock(void) { return v6only(rc(socket(AF_INET6, SOCK_DGRAM, 0))); }
static long tsock(void) { return v6only(rc(socket(AF_INET6, SOCK_STREAM, 0))); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 28)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 28)); }
static long recv_(long s, char *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long setopt(long s, int level, int name, const void *v, int len) { return rc(setsockopt((int)s, level, name, v, len)); }
static long getopt6(long s, int name) { int v = -7; socklen_t l = 4; long r = rc(getsockopt((int)s, IPPROTO_IPV6, name, &v, &l)); return r < 0 ? r : v; }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET6 10
#define IPPROTO_IPV6 41
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define IPV6_MULTICAST_IF 17
#define IPV6_MULTICAST_HOPS 18
#define IPV6_MULTICAST_LOOP 19
#define IPV6_ADD_MEMBERSHIP 20
#define IPV6_DROP_MEMBERSHIP 21
#define IPV6_MULTICAST_ALL 29
static long usock(void) { return syscall3(117, AF_INET6, 2, 0); }
static long tsock(void) { return syscall3(117, AF_INET6, 1, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 28); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 28); }
static long recv_(long s, char *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long setopt(long s, int level, int name, const void *v, int len) { return syscall5(132, s, level, name, (long)v, len); }
static long getopt6(long s, int name) { int v = -7; int l = 4; long r = syscall5(133, s, IPPROTO_IPV6, name, (long)&v, (long)&l); return r < 0 ? r : v; }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello361:   ok   " : "hello361:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk(unsigned char *s, const unsigned char *addr, int port) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (addr) for (int i = 0; i < 16; i++) s[8 + i] = addr[i];
}
static long setint(long s, int name, int v) { return setopt(s, IPPROTO_IPV6, name, &v, 4); }
/* struct ipv6_mreq: the group, then the interface index. */
static long member(long s, int name, const unsigned char *group, int ifindex, int len) {
    unsigned char m[24];
    for (int i = 0; i < 24; i++) m[i] = 0;
    for (int i = 0; i < 16; i++) m[i] = group[i];
    m[16] = (unsigned char)ifindex; m[17] = (unsigned char)(ifindex >> 8);
    return setopt(s, IPPROTO_IPV6, name, m, len);
}
static long reuse_sock(const unsigned char *addr, int port) {
    long s = usock();
    int one = 1;
    setopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4);
    unsigned char a[28];
    mk(a, addr, port);
    long b = bind_(s, a);
    return b == 0 ? s : b;
}
/* How many datagrams are waiting on `s` (drains them). */
static int count(long s) {
    char b[8];
    int n = 0;
    while (recv_(s, b, sizeof b) >= 0) n++;
    return n;
}
static long sk[6];
static int got[6];
static void deliver(long tx, const unsigned char *to) {
    sendto_(tx, "mm", 2, to);
    for (int i = 1; i <= 5; i++) got[i] = 0;
    for (int t = 0; t < 10; t++) {
        pump();
        for (int i = 1; i <= 5; i++) if (sk[i] >= 0) got[i] += count(sk[i]);
    }
}

int main(void) {
    print("hello361: IPv6 UDP multicast options, membership and local delivery\n");
    unsigned char g1[16] = { 0xff, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x01 };
    unsigned char g2[16] = { 0xff, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02 };
    unsigned char uni[16] = { 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    long o = usock();
    long h0 = getopt6(o, IPV6_MULTICAST_HOPS), l0 = getopt6(o, IPV6_MULTICAST_LOOP), i0 = getopt6(o, IPV6_MULTICAST_IF), a0 = getopt6(o, IPV6_MULTICAST_ALL);
    long h7 = setint(o, IPV6_MULTICAST_HOPS, 7), h7r = getopt6(o, IPV6_MULTICAST_HOPS);
    long hm = setint(o, IPV6_MULTICAST_HOPS, -1), hmr = getopt6(o, IPV6_MULTICAST_HOPS), hb = setint(o, IPV6_MULTICAST_HOPS, 256);
    long lb = setint(o, IPV6_MULTICAST_LOOP, 2), lz = setint(o, IPV6_MULTICAST_LOOP, 0), lzr = getopt6(o, IPV6_MULTICAST_LOOP);
    long ib = setint(o, IPV6_MULTICAST_IF, 99), i2 = setint(o, IPV6_MULTICAST_IF, 2), i2r = getopt6(o, IPV6_MULTICAST_IF);
    snprintf(msg, sizeof msg, "O: defaults hops %ld loop %ld if %ld all %ld (1 1 0 1); hops 7 %ld->%ld, -1 %ld->%ld, 256 %ld; loop 2 %ld, 0 %ld->%ld; if 99 %ld, 2 %ld->%ld",
             h0, l0, i0, a0, h7, h7r, hm, hmr, hb, lb, lz, lzr, ib, i2, i2r);
    check(h0 == 1 && l0 == 1 && i0 == 0 && a0 == 1 && h7 == 0 && h7r == 7 && hm == 0 && hmr == 1 && hb == -22 && lb == -22 && lz == 0 && lzr == 0 &&
              ib == -19 && i2 == 0 && i2r == 2, msg);

    long j19 = member(o, IPV6_ADD_MEMBERSHIP, g1, 0, 19), ju = member(o, IPV6_ADD_MEMBERSHIP, uni, 0, 20), j99 = member(o, IPV6_ADD_MEMBERSHIP, g1, 99, 20);
    long j = member(o, IPV6_ADD_MEMBERSHIP, g1, 0, 20), jj = member(o, IPV6_ADD_MEMBERSHIP, g1, 0, 20), j2 = member(o, IPV6_ADD_MEMBERSHIP, g1, 2, 20);
    long d2 = member(o, IPV6_DROP_MEMBERSHIP, g2, 0, 20), d1 = member(o, IPV6_DROP_MEMBERSHIP, g1, 0, 20), dd = member(o, IPV6_DROP_MEMBERSHIP, g1, 0, 20);
    snprintf(msg, sizeof msg, "J: add 19 bytes %ld, unicast %ld, if 99 %ld, ff0e::101 %ld, again %ld, on 2 %ld; drop ff0e::102 %ld, ff0e::101 %ld, again %ld",
             j19, ju, j99, j, jj, j2, d2, d1, dd);
    check(j19 == -22 && ju == -22 && j99 == -19 && j == 0 && jj == -98 && j2 == -98 && d2 == -99 && d1 == 0 && dd == -99, msg);
    close_(o);

    long t = tsock();
    long tj = member(t, IPV6_ADD_MEMBERSHIP, g1, 0, 20), th = setint(t, IPV6_MULTICAST_HOPS, 3), thr = getopt6(t, IPV6_MULTICAST_HOPS);
    snprintf(msg, sizeof msg, "T: a TCP socket's ADD_MEMBERSHIP %ld (EPROTO), set MULTICAST_HOPS %ld (ENOPROTOOPT), read %ld (1)", tj, th, thr);
    check(tj == -71 && th == -92 && thr == 1, msg);
    close_(t);

    sk[1] = reuse_sock(0, 19101); sk[2] = reuse_sock(0, 19101); sk[3] = reuse_sock(g1, 19101); sk[4] = reuse_sock(g2, 19101); sk[5] = reuse_sock(0, 19101);
    long m1 = member(sk[1], IPV6_ADD_MEMBERSHIP, g1, 0, 20), m2 = member(sk[2], IPV6_ADD_MEMBERSHIP, g1, 2, 20), m3 = member(sk[3], IPV6_ADD_MEMBERSHIP, g1, 0, 20);
    long m5 = setint(sk[5], IPV6_MULTICAST_ALL, 0);
    long tx = usock();
    unsigned char to1[28], to2[28];
    mk(to1, g1, 19101);
    mk(to2, g2, 19101);
    deliver(tx, to1);
    snprintf(msg, sizeof msg, "D1: sockets %ld %ld %ld %ld %ld, joins %ld %ld %ld, all=0 %ld; to ff0e::101 s1..s5 got %d %d %d %d %d (1 1 1 0 0)",
             sk[1], sk[2], sk[3], sk[4], sk[5], m1, m2, m3, m5, got[1], got[2], got[3], got[4], got[5]);
    check(sk[1] >= 0 && sk[2] >= 0 && sk[3] >= 0 && sk[4] >= 0 && sk[5] >= 0 && m1 == 0 && m2 == 0 && m3 == 0 && m5 == 0 &&
              got[1] == 1 && got[2] == 1 && got[3] == 1 && got[4] == 0 && got[5] == 0, msg);

    long lv = member(sk[1], IPV6_DROP_MEMBERSHIP, g1, 0, 20);
    deliver(tx, to1);
    snprintf(msg, sizeof msg, "D2: s1 leaves (%ld); to ff0e::101 s1..s5 got %d %d %d %d %d (1 1 1 0 0)", lv, got[1], got[2], got[3], got[4], got[5]);
    check(lv == 0 && got[1] == 1 && got[2] == 1 && got[3] == 1 && got[4] == 0 && got[5] == 0, msg);

    deliver(tx, to2);
    snprintf(msg, sizeof msg, "D3: to ff0e::102 (no member) s1..s5 got %d %d %d %d %d (0 0 0 0 0)", got[1], got[2], got[3], got[4], got[5]);
    check(got[1] == 0 && got[2] == 0 && got[3] == 0 && got[4] == 0 && got[5] == 0, msg);

    long nl = setint(tx, IPV6_MULTICAST_LOOP, 0);
    deliver(tx, to1);
    snprintf(msg, sizeof msg, "D4: sender LOOP 0 (%ld); to ff0e::101 s1..s5 got %d %d %d %d %d (0 0 0 0 0)", nl, got[1], got[2], got[3], got[4], got[5]);
    check(nl == 0 && got[1] == 0 && got[2] == 0 && got[3] == 0 && got[4] == 0 && got[5] == 0, msg);
    setint(tx, IPV6_MULTICAST_LOOP, 1);

    close_(sk[2]); close_(sk[3]);
    sk[2] = sk[3] = -1;
    deliver(tx, to1);
    snprintf(msg, sizeof msg, "D5: no member left; to ff0e::101 s1 got %d, s5 got %d (0 0)", got[1], got[5]);
    check(got[1] == 0 && got[5] == 0, msg);
    close_(sk[1]); close_(sk[4]); close_(sk[5]); close_(tx);

    print(failures ? "hello361: FAIL\n" : "hello361: PASS\n");
    return failures ? 1 : 0;
}
