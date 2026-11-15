/* hello363: the outgoing interface of a multicast datagram and per-socket send options on a shared port. IP_MULTICAST_IF naming
 * lo sends the datagram out lo only, where every member on lo takes it whatever IP_MULTICAST_LOOP and IP_MULTICAST_TTL say (Linux
 * ip_mc_output transmits it on the loopback device); IPV6_MULTICAST_IF naming lo has no multicast route (ENETUNREACH); and two
 * sockets sharing a port through SO_REUSEADDR each send with their own options (Linux reads them from the sending sock). Whether the
 * host takes a looped-back group datagram depends on membership on the interface it arrived on. Measured on
 * the host (build with -DHOST, run in `unshare -rn` with a multicast dummy link d0, which is interface 2 there as eth0 is in MoQiOS:
 *   ip link set lo up; ip link add d0 type dummy; ip link set d0 multicast on up; ip addr add 10.0.2.15/24 dev d0;
 *   ip -6 addr add 2001:db8:1::7/64 dev d0 nodad; ip route add default via 10.0.2.2 dev d0;
 *   ip -6 route add default via 2001:db8:1::1 dev d0; every IPv6 socket IPV6_V6ONLY):
 *   F1. a receiver on port 19301 joins 239.1.3.1 on lo (ip_mreqn index 1); a sender with IP_MULTICAST_IF 127.0.0.1 and LOOP 0
 *       reaches it once, from 127.0.0.1 (the IP_MULTICAST_IF address is the source);
 *   F2. the same with TTL 0 and LOOP 1 (IF through ip_mreqn index 1) reaches it once;
 *   F3. a receiver on 19302 that joined 239.1.3.1 on the NIC (index 2) only: a sender with IF lo and LOOP 1 does not reach it;
 *   F4. a receiver on 19303 that joined nothing: a sender with IF lo and LOOP 0 reaches it through 224.0.0.1 (all hosts) once;
 *   F5. a receiver on 19304 that joined 239.1.3.1 on lo only: a sender with the default interface (the NIC) and LOOP 1 does not reach it;
 *   F6. on 19308 A joins 239.1.3.1 on the NIC and B on lo with IP_MULTICAST_ALL 0: a datagram looped back from the NIC reaches A, not
 *       B (ip_mc_sf_allow matches the membership's interface against the one the datagram arrived on);
 *   K4. two SO_REUSEADDR senders share port 19310; the second sets IP_MULTICAST_LOOP 0. To 239.1.3.1:19305, joined on the NIC by a
 *       receiver, the second one's datagram does not come back, the first one's does;
 *   K6. the IPv6 counterpart on port 19311 to [ff0e::131]:19306 with IPV6_MULTICAST_LOOP: the second one's does not come back, the
 *       first one's does;
 *   N6. a socket with IPV6_MULTICAST_IF 1 (lo): sending to ff0e::131 and to ff02::1 is ENETUNREACH; to [::1]:19307 it still arrives. */
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
static long usock4(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long usock6(void) { return v6only(rc(socket(AF_INET6, SOCK_DGRAM, 0))); }
static long bind_(long s, const unsigned char *a, int len) { return rc(bind((int)s, (const void *)a, len)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to, int len) { return rc(sendto((int)s, b, n, 0, (const void *)to, len)); }
static long recv_(long s, char *b, int n, unsigned char *from) { socklen_t l = 28; return rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l)); }
static long setopt(long s, int level, int name, const void *v, int len) { return rc(setsockopt((int)s, level, name, v, len)); }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM4(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#define FAM6(a) do { unsigned short fam = AF_INET6; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
#define AF_INET6 10
#define IPPROTO_IP 0
#define IPPROTO_IPV6 41
#define SOL_SOCKET 1
#define SO_REUSEADDR 2
#define IP_MULTICAST_IF 32
#define IP_MULTICAST_TTL 33
#define IP_MULTICAST_LOOP 34
#define IP_ADD_MEMBERSHIP 35
#define IP_MULTICAST_ALL 49
#define IPV6_MULTICAST_IF 17
#define IPV6_MULTICAST_LOOP 19
#define IPV6_ADD_MEMBERSHIP 20
static long usock4(void) { return syscall3(117, AF_INET, 2, 0); }
static long usock6(void) { return syscall3(117, AF_INET6, 2, 0); }
static long bind_(long s, const unsigned char *a, int len) { return syscall3(118, s, (long)a, len); }
static long sendto_(long s, const char *b, int n, const unsigned char *to, int len) { return syscall6(121, s, (long)b, n, 0, (long)to, len); }
static long recv_(long s, char *b, int n, unsigned char *from) { int l = 28; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static long setopt(long s, int level, int name, const void *v, int len) { return syscall5(132, s, level, name, (long)v, len); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM4(a) do { (a)[0] = AF_INET; (a)[1] = 0; } while (0)
#define FAM6(a) do { (a)[0] = AF_INET6; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello363:   ok   " : "hello363:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, const unsigned char *addr, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM4(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (addr) for (int i = 0; i < 4; i++) s[4 + i] = addr[i];
}
static void mk6(unsigned char *s, const unsigned char *addr, int port) {
    for (int i = 0; i < 28; i++) s[i] = 0;
    FAM6(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (addr) for (int i = 0; i < 16; i++) s[8 + i] = addr[i];
}
static long setint4(long s, int name, int v) { return setopt(s, IPPROTO_IP, name, &v, 4); }
static long setint6(long s, int name, int v) { return setopt(s, IPPROTO_IPV6, name, &v, 4); }
/* struct ip_mreqn: group, interface address, interface index. */
static long join4(long s, const unsigned char *group, int ifindex) {
    unsigned char m[12];
    for (int i = 0; i < 12; i++) m[i] = 0;
    for (int i = 0; i < 4; i++) m[i] = group[i];
    m[8] = (unsigned char)ifindex;
    return setopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, m, 12);
}
static long if4_index(long s, int ifindex) {
    unsigned char m[12];
    for (int i = 0; i < 12; i++) m[i] = 0;
    m[8] = (unsigned char)ifindex;
    return setopt(s, IPPROTO_IP, IP_MULTICAST_IF, m, 12);
}
static long join6(long s, const unsigned char *group, int ifindex) {
    unsigned char m[20];
    for (int i = 0; i < 20; i++) m[i] = 0;
    for (int i = 0; i < 16; i++) m[i] = group[i];
    m[16] = (unsigned char)ifindex;
    return setopt(s, IPPROTO_IPV6, IPV6_ADD_MEMBERSHIP, m, 20);
}
static long reuse_bind(long s, const unsigned char *sa, int len) {
    int one = 1;
    setopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4);
    return bind_(s, sa, len);
}
static long rx4(int port) {
    long s = usock4();
    unsigned char a[16];
    mk4(a, 0, port);
    long b = reuse_bind(s, a, 16);
    return b == 0 ? s : b;
}
static long rx6(int port) {
    long s = usock6();
    unsigned char a[28];
    mk6(a, 0, port);
    long b = reuse_bind(s, a, 28);
    return b == 0 ? s : b;
}
/* The IPv4 source address of the last datagram copies() saw. */
static unsigned char src4[4];
/* Send one datagram and count the copies `r` takes within about 200 ms. */
static int copies(long tx, long r, const unsigned char *to, int len, long *sent) {
    *sent = sendto_(tx, "mc", 2, to, len);
    int n = 0;
    char b[8];
    unsigned char from[28];
    for (int i = 0; i < 4; i++) src4[i] = 0;
    for (int t = 0; t < 10; t++) {
        pump();
        while (recv_(r, b, sizeof b, from) >= 0) {
            n++;
            for (int i = 0; i < 4; i++) src4[i] = from[4 + i];
        }
    }
    return n;
}

int main(void) {
    print("hello363: multicast outgoing interface and per-socket send options\n");
    unsigned char g[4] = { 239, 1, 3, 1 }, allhosts[4] = { 224, 0, 0, 1 }, loop4[4] = { 127, 0, 0, 1 };
    unsigned char g6[16] = { 0xff, 0x0e, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x31 };
    unsigned char an6[16] = { 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };
    unsigned char lo6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    unsigned char to[28];
    long sent = 0;

    long r1 = rx4(19301), j1 = join4(r1, g, 1);
    long tx = usock4();
    long sif = setopt(tx, IPPROTO_IP, IP_MULTICAST_IF, loop4, 4), sl0 = setint4(tx, IP_MULTICAST_LOOP, 0);
    mk4(to, g, 19301);
    int c1 = copies(tx, r1, to, 16, &sent);
    snprintf(msg, sizeof msg, "F1: receiver %ld joins 239.1.3.1 on lo (%ld); sender IF 127.0.0.1 (%ld), LOOP 0 (%ld) sends %ld; copies %d (1) from %d.%d.%d.%d (127.0.0.1)",
             r1, j1, sif, sl0, sent, c1, src4[0], src4[1], src4[2], src4[3]);
    check(r1 >= 0 && j1 == 0 && sif == 0 && sl0 == 0 && sent == 2 && c1 == 1 && src4[0] == 127 && src4[1] == 0 && src4[2] == 0 && src4[3] == 1, msg);
    close_(tx);

    tx = usock4();
    long sifn = if4_index(tx, 1), st0 = setint4(tx, IP_MULTICAST_TTL, 0);
    int c2 = copies(tx, r1, to, 16, &sent);
    snprintf(msg, sizeof msg, "F2: sender IF index 1 (%ld), TTL 0 (%ld), LOOP 1 sends %ld; copies %d (1)", sifn, st0, sent, c2);
    check(sifn == 0 && st0 == 0 && sent == 2 && c2 == 1, msg);
    close_(r1);

    long r3 = rx4(19302), j3 = join4(r3, g, 2);
    mk4(to, g, 19302);
    int c3 = copies(tx, r3, to, 16, &sent);
    snprintf(msg, sizeof msg, "F3: receiver joined on the NIC only (%ld); sender IF lo, LOOP 1 sends %ld; copies %d (0)", j3, sent, c3);
    check(r3 >= 0 && j3 == 0 && sent == 2 && c3 == 0, msg);
    close_(r3);

    long r4 = rx4(19303);
    setint4(tx, IP_MULTICAST_LOOP, 0);
    mk4(to, allhosts, 19303);
    int c4 = copies(tx, r4, to, 16, &sent);
    snprintf(msg, sizeof msg, "F4: receiver %ld joined nothing; sender IF lo, LOOP 0 to 224.0.0.1 sends %ld; copies %d (1)", r4, sent, c4);
    check(r4 >= 0 && sent == 2 && c4 == 1, msg);
    close_(tx);
    close_(r4);

    long r5 = rx4(19304), j5 = join4(r5, g, 1);
    tx = usock4();
    mk4(to, g, 19304);
    int c5 = copies(tx, r5, to, 16, &sent);
    snprintf(msg, sizeof msg, "F5: receiver joined on lo only (%ld); sender on the default interface, LOOP 1 sends %ld; copies %d (0)", j5, sent, c5);
    check(r5 >= 0 && j5 == 0 && sent == 2 && c5 == 0, msg);
    close_(r5);

    long ra = rx4(19308), rb = rx4(19308), ja = join4(ra, g, 2), jb = join4(rb, g, 1), nb = setint4(rb, IP_MULTICAST_ALL, 0);
    mk4(to, g, 19308);
    int ca = copies(tx, ra, to, 16, &sent);
    int cb = copies(tx, rb, to, 16, &sent);
    snprintf(msg, sizeof msg, "F6: on 19308 A joins on the NIC (%ld), B on lo with MULTICAST_ALL 0 (%ld %ld); two sends on the default interface: A got %d, B got %d (1 0)",
             ja, jb, nb, ca, cb);
    check(ra >= 0 && rb >= 0 && ja == 0 && jb == 0 && nb == 0 && sent == 2 && ca == 1 && cb == 0, msg);
    close_(ra); close_(rb); close_(tx);

    long r6 = rx4(19305), j6 = join4(r6, g, 2);
    long a1 = rx4(19310), a2 = rx4(19310);
    long al = setint4(a2, IP_MULTICAST_LOOP, 0);
    mk4(to, g, 19305);
    long sent1 = 0;
    int k2 = copies(a2, r6, to, 16, &sent);
    int k1 = copies(a1, r6, to, 16, &sent1);
    snprintf(msg, sizeof msg, "K4: senders %ld %ld share port 19310, the second LOOP 0 (%ld); receiver joined on the NIC (%ld); second sends %ld -> copies %d (0), first sends %ld -> copies %d (1)",
             a1, a2, al, j6, sent, k2, sent1, k1);
    check(r6 >= 0 && j6 == 0 && a1 >= 0 && a2 >= 0 && al == 0 && sent == 2 && k2 == 0 && sent1 == 2 && k1 == 1, msg);
    close_(r6); close_(a1); close_(a2);

    long r7 = rx6(19306), j7 = join6(r7, g6, 2);
    long b1 = rx6(19311), b2 = rx6(19311);
    long bl = setint6(b2, IPV6_MULTICAST_LOOP, 0);
    mk6(to, g6, 19306);
    int m2 = copies(b2, r7, to, 28, &sent);
    int m1 = copies(b1, r7, to, 28, &sent1);
    snprintf(msg, sizeof msg, "K6: senders %ld %ld share port 19311, the second LOOP 0 (%ld); receiver joined ff0e::131 on the NIC (%ld); second sends %ld -> copies %d (0), first sends %ld -> copies %d (1)",
             b1, b2, bl, j7, sent, m2, sent1, m1);
    check(r7 >= 0 && j7 == 0 && b1 >= 0 && b2 >= 0 && bl == 0 && sent == 2 && m2 == 0 && sent1 == 2 && m1 == 1, msg);
    close_(r7); close_(b1); close_(b2);

    long r8 = rx6(19307), n = usock6();
    long nif = setint6(n, IPV6_MULTICAST_IF, 1);
    mk6(to, g6, 19307);
    long ng = sendto_(n, "nn", 2, to, 28);
    mk6(to, an6, 19307);
    long na = sendto_(n, "nn", 2, to, 28);
    mk6(to, lo6, 19307);
    int nu = copies(n, r8, to, 28, &sent);
    snprintf(msg, sizeof msg, "N6: IPV6_MULTICAST_IF 1 (%ld); to ff0e::131 %ld, to ff02::1 %ld (-101 -101); to [::1]:19307 sends %ld, copies %d (1)", nif, ng, na, sent, nu);
    check(r8 >= 0 && nif == 0 && ng == -101 && na == -101 && sent == 2 && nu == 1, msg);
    close_(r8); close_(n);

    print(failures ? "hello363: FAIL\n" : "hello363: PASS\n");
    return failures ? 1 : 0;
}
