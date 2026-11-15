/* hello362: IPv4 UDP multicast: the IP_MULTICAST_* options, group membership (IP_ADD/DROP_MEMBERSHIP) and local delivery of a
 * datagram sent to a group this host has joined (Linux do_ip_setsockopt, ip_mc_join_group, ip_mc_leave_group, ip_mc_sf_allow,
 * __udp4_lib_mcast_deliver, ip_mc_output looping a copy back when the outgoing interface is a member). Measured on the host (build
 * with -DHOST, run in `unshare -rn` with a multicast dummy link d0, which is interface 2 there as eth0 is in MoQiOS:
 *   ip link set lo up; ip link add d0 type dummy; ip link set d0 multicast on up;
 *   ip addr add 10.0.2.15/24 dev d0; ip route add default via 10.0.2.2 dev d0):
 *   L. a UDP socket connected to 10.0.2.2:9 names the host's address A;
 *   O. a UDP socket: IP_MULTICAST_TTL 1, LOOP 1, IF 0.0.0.0, ALL 1 by default; TTL 7 reads 7, -1 restores 1, 256 is EINVAL, a one-byte
 *      9 reads 9; LOOP 5 reads 1; ALL 3 is EINVAL; IF A reads A, 10.9.9.9 is EADDRNOTAVAIL, a 3-byte value EINVAL;
 *   J. ADD_MEMBERSHIP with 7 bytes is EINVAL, of 10.0.0.1 EINVAL, on interface address 10.9.9.9 ENODEV; 239.1.1.1 succeeds, again (on
 *      0.0.0.0, or on interface 2 through ip_mreqn) EADDRINUSE, on interface 99 ENODEV; DROP of 239.1.1.2 and of 10.0.0.1 is
 *      EADDRNOTAVAIL, of 239.1.1.1 succeeds, again EADDRNOTAVAIL;
 *   T. a TCP socket: ADD_MEMBERSHIP is EPROTO, setting IP_MULTICAST_TTL EINVAL, reading it 1, setting IP_MULTICAST_LOOP 0 succeeds;
 *   D1. on port 19201 (all SO_REUSEADDR): s1 [0.0.0.0] and s2 [0.0.0.0] join 239.1.1.1, s3 [239.1.1.1] joins it, s4 [239.1.1.2] does
 *       not, s5 [0.0.0.0] sets IP_MULTICAST_ALL 0; a datagram to 239.1.1.1:19201 reaches s1, s2 and s3 once each, s4 and s5 not;
 *   D2. s1 leaves the group: the next one still reaches s1 (MULTICAST_ALL, the host is still a member), s2 and s3;
 *   D3. one to 239.1.1.2:19201 (nobody joined it) reaches no socket, not even s4;
 *   D4. one to 224.0.0.1:19201 (all-hosts, joined by every interface) reaches s1 and s2 only;
 *   D5. with IP_MULTICAST_LOOP 0 on the sender one to 239.1.1.1 reaches no socket;
 *   D6. after s2 and s3 close (no member left) one to 239.1.1.1 reaches neither s1 nor s5;
 *   S. a socket bound to [239.1.1.1]:19202 sends to 127.0.0.1:19203; it arrives from 127.0.0.1:19202. */
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
static long usock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long tsock(void) { return rc(socket(AF_INET, SOCK_STREAM, 0)); }
static long bind_(long s, const unsigned char *a) { return rc(bind((int)s, (const void *)a, 16)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long name_(long s, unsigned char *a) { socklen_t l = 16; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 16)); }
static long recv_(long s, char *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { socklen_t l = 16; return rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l)); }
static long setopt(long s, int level, int name, const void *v, int len) { return rc(setsockopt((int)s, level, name, v, len)); }
static long getopt4(long s, int name) { int v = -7; socklen_t l = 4; long r = rc(getsockopt((int)s, IPPROTO_IP, name, &v, &l)); return r < 0 ? r : v; }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
#define IPPROTO_IP 0
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define IP_MULTICAST_IF 32
#define IP_MULTICAST_TTL 33
#define IP_MULTICAST_LOOP 34
#define IP_ADD_MEMBERSHIP 35
#define IP_DROP_MEMBERSHIP 36
#define IP_MULTICAST_ALL 49
static long usock(void) { return syscall3(117, AF_INET, 2, 0); }
static long tsock(void) { return syscall3(117, AF_INET, 1, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 16); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long name_(long s, unsigned char *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
static long recv_(long s, char *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { int l = 16; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static long setopt(long s, int level, int name, const void *v, int len) { return syscall5(132, s, level, name, (long)v, len); }
static long getopt4(long s, int name) { int v = -7; int l = 4; long r = syscall5(133, s, IPPROTO_IP, name, (long)&v, (long)&l); return r < 0 ? r : v; }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a) do { (a)[0] = AF_INET; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello362:   ok   " : "hello362:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk(unsigned char *s, const unsigned char *addr, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (addr) for (int i = 0; i < 4; i++) s[4 + i] = addr[i];
}
static long setint(long s, int name, int v) { return setopt(s, IPPROTO_IP, name, &v, 4); }
/* struct ip_mreqn: the group, the interface address, then a 32-bit interface index; `len` 8 is the older struct ip_mreq. */
static long member(long s, int name, const unsigned char *group, const unsigned char *ifaddr, int ifindex, int len) {
    unsigned char m[12];
    for (int i = 0; i < 12; i++) m[i] = 0;
    for (int i = 0; i < 4; i++) m[i] = group[i];
    if (ifaddr) for (int i = 0; i < 4; i++) m[4 + i] = ifaddr[i];
    m[8] = (unsigned char)ifindex;
    return setopt(s, IPPROTO_IP, name, m, len);
}
static int same4(long v, const unsigned char *a) {
    unsigned char b[4];
    unsigned int u = (unsigned int)v;
    b[0] = (unsigned char)u; b[1] = (unsigned char)(u >> 8); b[2] = (unsigned char)(u >> 16); b[3] = (unsigned char)(u >> 24);
    return b[0] == a[0] && b[1] == a[1] && b[2] == a[2] && b[3] == a[3];
}
static long reuse_sock(const unsigned char *addr, int port) {
    long s = usock();
    int one = 1;
    setopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4);
    unsigned char a[16];
    mk(a, addr, port);
    long b = bind_(s, a);
    return b == 0 ? s : b;
}
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
    print("hello362: IPv4 UDP multicast options, membership and local delivery\n");
    unsigned char g1[4] = { 239, 1, 1, 1 }, g2[4] = { 239, 1, 1, 2 }, allhosts[4] = { 224, 0, 0, 1 };
    unsigned char uni[4] = { 10, 0, 0, 1 }, gw[4] = { 10, 0, 2, 2 }, bogus[4] = { 10, 9, 9, 9 }, loop[4] = { 127, 0, 0, 1 };
    unsigned char sa[16], nm[16];

    long probe = usock();
    mk(sa, gw, 9);
    long cp = connect_(probe, sa), np = name_(probe, nm);
    unsigned char me[4] = { nm[4], nm[5], nm[6], nm[7] };
    snprintf(msg, sizeof msg, "L: a UDP socket connected to 10.0.2.2:9 (%ld, getsockname %ld) names %d.%d.%d.%d", cp, np, me[0], me[1], me[2], me[3]);
    check(cp == 0 && np == 0 && me[0] != 0 && me[0] != 127, msg);
    close_(probe);

    long o = usock();
    long t0 = getopt4(o, IP_MULTICAST_TTL), l0 = getopt4(o, IP_MULTICAST_LOOP), i0 = getopt4(o, IP_MULTICAST_IF), a0 = getopt4(o, IP_MULTICAST_ALL);
    long t7 = setint(o, IP_MULTICAST_TTL, 7), t7r = getopt4(o, IP_MULTICAST_TTL);
    long tm = setint(o, IP_MULTICAST_TTL, -1), tmr = getopt4(o, IP_MULTICAST_TTL), tb = setint(o, IP_MULTICAST_TTL, 256);
    unsigned char nine = 9;
    long t9 = setopt(o, IPPROTO_IP, IP_MULTICAST_TTL, &nine, 1), t9r = getopt4(o, IP_MULTICAST_TTL);
    long l5 = setint(o, IP_MULTICAST_LOOP, 5), l5r = getopt4(o, IP_MULTICAST_LOOP);
    long ab = setint(o, IP_MULTICAST_ALL, 3);
    long ia = setopt(o, IPPROTO_IP, IP_MULTICAST_IF, me, 4), iar = getopt4(o, IP_MULTICAST_IF);
    long ib = setopt(o, IPPROTO_IP, IP_MULTICAST_IF, bogus, 4), i3 = setopt(o, IPPROTO_IP, IP_MULTICAST_IF, me, 3);
    snprintf(msg, sizeof msg, "O: defaults ttl %ld loop %ld if %ld all %ld (1 1 0 1); ttl 7 %ld->%ld, -1 %ld->%ld, 256 %ld, byte 9 %ld->%ld; loop 5 %ld->%ld; all 3 %ld; if A %ld (%s), 10.9.9.9 %ld, 3 bytes %ld",
             t0, l0, i0, a0, t7, t7r, tm, tmr, tb, t9, t9r, l5, l5r, ab, ia, same4(iar, me) ? "reads A" : "reads another", ib, i3);
    check(t0 == 1 && l0 == 1 && i0 == 0 && a0 == 1 && t7 == 0 && t7r == 7 && tm == 0 && tmr == 1 && tb == -22 && t9 == 0 && t9r == 9 &&
              l5 == 0 && l5r == 1 && ab == -22 && ia == 0 && same4(iar, me) && ib == -99 && i3 == -22, msg);

    long j7 = member(o, IP_ADD_MEMBERSHIP, g1, 0, 0, 7), ju = member(o, IP_ADD_MEMBERSHIP, uni, 0, 0, 8), jb = member(o, IP_ADD_MEMBERSHIP, g1, bogus, 0, 8);
    long j = member(o, IP_ADD_MEMBERSHIP, g1, 0, 0, 8), jj = member(o, IP_ADD_MEMBERSHIP, g1, 0, 0, 8), j2 = member(o, IP_ADD_MEMBERSHIP, g1, 0, 2, 12);
    long j99 = member(o, IP_ADD_MEMBERSHIP, g1, 0, 99, 12);
    long d2 = member(o, IP_DROP_MEMBERSHIP, g2, 0, 0, 8), du = member(o, IP_DROP_MEMBERSHIP, uni, 0, 0, 8);
    long d1 = member(o, IP_DROP_MEMBERSHIP, g1, 0, 0, 8), dd = member(o, IP_DROP_MEMBERSHIP, g1, 0, 0, 8);
    snprintf(msg, sizeof msg, "J: add 7 bytes %ld, unicast %ld, on 10.9.9.9 %ld, 239.1.1.1 %ld, again %ld, on index 2 %ld, on 99 %ld; drop 239.1.1.2 %ld, unicast %ld, 239.1.1.1 %ld, again %ld",
             j7, ju, jb, j, jj, j2, j99, d2, du, d1, dd);
    check(j7 == -22 && ju == -22 && jb == -19 && j == 0 && jj == -98 && j2 == -98 && j99 == -19 && d2 == -99 && du == -99 && d1 == 0 && dd == -99, msg);
    close_(o);

    long t = tsock();
    long tj = member(t, IP_ADD_MEMBERSHIP, g1, 0, 0, 8), tt = setint(t, IP_MULTICAST_TTL, 3), ttr = getopt4(t, IP_MULTICAST_TTL), tl = setint(t, IP_MULTICAST_LOOP, 0);
    snprintf(msg, sizeof msg, "T: a TCP socket's ADD_MEMBERSHIP %ld (EPROTO), set MULTICAST_TTL %ld (EINVAL), read %ld (1), set MULTICAST_LOOP 0 %ld", tj, tt, ttr, tl);
    check(tj == -71 && tt == -22 && ttr == 1 && tl == 0, msg);
    close_(t);

    sk[1] = reuse_sock(0, 19201); sk[2] = reuse_sock(0, 19201); sk[3] = reuse_sock(g1, 19201); sk[4] = reuse_sock(g2, 19201); sk[5] = reuse_sock(0, 19201);
    long m1 = member(sk[1], IP_ADD_MEMBERSHIP, g1, 0, 0, 8), m2 = member(sk[2], IP_ADD_MEMBERSHIP, g1, 0, 2, 12), m3 = member(sk[3], IP_ADD_MEMBERSHIP, g1, 0, 0, 8);
    long m5 = setint(sk[5], IP_MULTICAST_ALL, 0);
    long tx = usock();
    unsigned char to1[16], to2[16], toa[16];
    mk(to1, g1, 19201);
    mk(to2, g2, 19201);
    mk(toa, allhosts, 19201);
    deliver(tx, to1);
    snprintf(msg, sizeof msg, "D1: sockets %ld %ld %ld %ld %ld, joins %ld %ld %ld, all=0 %ld; to 239.1.1.1 s1..s5 got %d %d %d %d %d (1 1 1 0 0)",
             sk[1], sk[2], sk[3], sk[4], sk[5], m1, m2, m3, m5, got[1], got[2], got[3], got[4], got[5]);
    check(sk[1] >= 0 && sk[2] >= 0 && sk[3] >= 0 && sk[4] >= 0 && sk[5] >= 0 && m1 == 0 && m2 == 0 && m3 == 0 && m5 == 0 &&
              got[1] == 1 && got[2] == 1 && got[3] == 1 && got[4] == 0 && got[5] == 0, msg);

    long lv = member(sk[1], IP_DROP_MEMBERSHIP, g1, 0, 0, 8);
    deliver(tx, to1);
    snprintf(msg, sizeof msg, "D2: s1 leaves (%ld); to 239.1.1.1 s1..s5 got %d %d %d %d %d (1 1 1 0 0)", lv, got[1], got[2], got[3], got[4], got[5]);
    check(lv == 0 && got[1] == 1 && got[2] == 1 && got[3] == 1 && got[4] == 0 && got[5] == 0, msg);

    deliver(tx, to2);
    snprintf(msg, sizeof msg, "D3: to 239.1.1.2 (no member) s1..s5 got %d %d %d %d %d (0 0 0 0 0)", got[1], got[2], got[3], got[4], got[5]);
    check(got[1] == 0 && got[2] == 0 && got[3] == 0 && got[4] == 0 && got[5] == 0, msg);

    deliver(tx, toa);
    snprintf(msg, sizeof msg, "D4: to 224.0.0.1 s1..s5 got %d %d %d %d %d (1 1 0 0 0)", got[1], got[2], got[3], got[4], got[5]);
    check(got[1] == 1 && got[2] == 1 && got[3] == 0 && got[4] == 0 && got[5] == 0, msg);

    long nl = setint(tx, IP_MULTICAST_LOOP, 0);
    deliver(tx, to1);
    snprintf(msg, sizeof msg, "D5: sender LOOP 0 (%ld); to 239.1.1.1 s1..s5 got %d %d %d %d %d (0 0 0 0 0)", nl, got[1], got[2], got[3], got[4], got[5]);
    check(nl == 0 && got[1] == 0 && got[2] == 0 && got[3] == 0 && got[4] == 0 && got[5] == 0, msg);
    setint(tx, IP_MULTICAST_LOOP, 1);

    close_(sk[2]); close_(sk[3]);
    sk[2] = sk[3] = -1;
    deliver(tx, to1);
    snprintf(msg, sizeof msg, "D6: no member left; to 239.1.1.1 s1 got %d, s5 got %d (0 0)", got[1], got[5]);
    check(got[1] == 0 && got[5] == 0, msg);
    close_(sk[1]); close_(sk[4]); close_(sk[5]); close_(tx);

    long gs = reuse_sock(g1, 19202), rx = reuse_sock(loop, 19203);
    unsigned char tol[16], from[16];
    mk(tol, loop, 19203);
    long ss = sendto_(gs, "ss", 2, tol), rr = -11;
    char b[8];
    for (int i = 0; i < 20 && rr == -11; i++) { pump(); rr = recvfrom_(rx, b, sizeof b, from); }
    snprintf(msg, sizeof msg, "S: from [239.1.1.1]:19202 to 127.0.0.1:19203 (%ld, %ld) arrives (%ld) from %d.%d.%d.%d:%d (want 127.0.0.1:19202)", gs, ss, rr,
             from[4], from[5], from[6], from[7], (from[2] << 8) | from[3]);
    check(gs >= 0 && ss == 2 && rr == 2 && from[4] == 127 && from[5] == 0 && from[6] == 0 && from[7] == 1 && ((from[2] << 8) | from[3]) == 19202, msg);
    close_(gs); close_(rx);

    print(failures ? "hello362: FAIL\n" : "hello362: PASS\n");
    return failures ? 1 : 0;
}
