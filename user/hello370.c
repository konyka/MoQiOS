/* hello370: datagrams and segments to this host's own IPv4 address (the NIC's 10.0.2.15) go over lo rather than out of the NIC
 * (Linux routes a local address through the local table to lo), and come from that address. Measured on the host (build with -DHOST,
 * run in `unshare -rn` with a veth pair whose far end has no address, so nothing on the wire answers:
 *   ip link set lo up; ip link add v0 type veth peer name v1; ip link set v1 up; ip link set v0 up;
 *   ip addr add 10.0.2.15/24 dev v0; ip route add default via 10.0.2.2 dev v0):
 *   U. a datagram to 10.0.2.15 reaches a socket bound to the wildcard, from 10.0.2.15;
 *   T. a TCP connect to 10.0.2.15 reaches a listener on the wildcard, data flows both ways, and both ends name 10.0.2.15;
 *   R. a TCP connect to 10.0.2.15 on a port nobody listens on is ECONNREFUSED. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
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
static long listen_(long s) { return rc(listen((int)s, 4)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long name_(long s, unsigned char *a) { socklen_t l = 16; return rc(getsockname((int)s, (void *)a, &l)); }
static long peer_(long s, unsigned char *a) { socklen_t l = 16; return rc(getpeername((int)s, (void *)a, &l)); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 16)); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { socklen_t l = 16; return rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l)); }
static long write_(long s, const char *b, int n) { return rc(write((int)s, b, n)); }
static long read_(long s, char *b, int n) { return rc(read((int)s, b, n)); }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM4(a) do { unsigned short fam = AF_INET; memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long usock(void) { return syscall3(117, 2, 2, 0); }
static long tsock(void) { return syscall3(117, 2, 1, 0); }
static long bind_(long s, const unsigned char *a) { return syscall3(118, s, (long)a, 16); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long listen_(long s) { return syscall2(119, s, 4); }
static long accept_(long s) { return syscall4(131, s, 0, 0, 0); }
static long name_(long s, unsigned char *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long peer_(long s, unsigned char *a) { int l = 16; return syscall3(127, s, (long)a, (long)&l); }
static long sendto_(long s, const char *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
static long recvfrom_(long s, char *b, int n, unsigned char *from) { int l = 16; return syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); }
static long write_(long s, const char *b, int n) { return write((int)s, b, n); }
static long read_(long s, char *b, int n) { return read((int)s, b, n); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM4(a) do { (a)[0] = 2; (a)[1] = 0; } while (0)
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello370:   ok   " : "hello370:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, const unsigned char *ip, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM4(s);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (ip) for (int i = 0; i < 4; i++) s[4 + i] = ip[i];
}
static int is_own(const unsigned char *a, const unsigned char *own) { return a[4] == own[0] && a[5] == own[1] && a[6] == own[2] && a[7] == own[3]; }
int main(void) {
    print("hello370: datagrams and segments to our own IPv4 address go over lo\n");
    /* Our own address: the source a datagram to the gateway leaves from. */
    unsigned char gwa[4] = { 10, 0, 2, 2 }, own[4], a[16], from[16], n1[16], n2[16];
    long g = usock();
    mk4(a, gwa, 19961);
    long gc = connect_(g, a);
    long gn = name_(g, n1);
    close_(g);
    for (int i = 0; i < 4; i++) own[i] = n1[4 + i];

    long r = usock();
    mk4(a, 0, 19962);
    long rb = bind_(r, a);
    long s = usock();
    mk4(a, own, 19962);
    long sn = sendto_(s, "hi", 2, a);
    char b[16];
    long got = -1;
    for (int t = 0; t < 50 && got < 0; t++) { pump(); got = recvfrom_(r, b, sizeof b, from); }
    snprintf(msg, sizeof msg, "U: own address %ld/%ld %d.%d.%d.%d; bind %ld, sendto %ld, received %ld from our own address %d (0 0 2 2 1)", gc, gn, own[0], own[1], own[2], own[3], rb, sn, got, got == 2 && is_own(from, own));
    check(gc == 0 && gn == 0 && own[0] != 127 && rb == 0 && sn == 2 && got == 2 && is_own(from, own), msg);
    close_(r); close_(s);

    long l = tsock();
    mk4(a, 0, 19963);
    long lb = bind_(l, a), ll = listen_(l);
    long c = tsock();
    mk4(a, own, 19963);
    long cc = connect_(c, a);
    /* Only a connection that was made is accepted and used: the blocking calls would wait forever otherwise. */
    long acc = cc == 0 ? accept_(l) : -1;
    long w1 = acc >= 0 ? write_(c, "ping", 4) : -1;
    char rbuf[8];
    long r1 = w1 == 4 ? read_(acc, rbuf, sizeof rbuf) : -1;
    long w2 = r1 == 4 ? write_(acc, "pong", 4) : -1;
    long r2 = w2 == 4 ? read_(c, rbuf, sizeof rbuf) : -1;
    long cn = name_(c, n1), ap = acc >= 0 ? peer_(acc, n2) : -1;
    snprintf(msg, sizeof msg, "T: listen %ld %ld, connect %ld, accept %ld, write/read %ld %ld %ld %ld, names %ld/%ld own %d %d (0 0 0 fd 4 4 4 4 0 0 1 1)", lb, ll, cc, acc, w1, r1, w2, r2, cn, ap, is_own(n1, own), is_own(n2, own));
    check(lb == 0 && ll == 0 && cc == 0 && acc >= 0 && w1 == 4 && r1 == 4 && w2 == 4 && r2 == 4 && cn == 0 && ap == 0 && is_own(n1, own) && is_own(n2, own), msg);
    if (acc >= 0) close_(acc);
    close_(c); close_(l);

    long x = tsock();
    mk4(a, own, 19964);
    long xc = connect_(x, a);
    snprintf(msg, sizeof msg, "R: connect to our own address on a closed port %ld (-111)", xc);
    check(xc == -111, msg);
    close_(x);

    print(failures ? "hello370: FAIL\n" : "hello370: PASS\n");
    return failures ? 1 : 0;
}
