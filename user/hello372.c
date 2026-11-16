/* hello372: ping sockets that share an ident. The echo reply for an ident goes to the ping socket hashed last among those that hold
 * it and whose bound address takes it (Linux ping_lookup walks the hash chain from its head, and ping_get_port puts a newly hashed
 * socket at the head), whichever socket sent the request; ping_lookup does not look at the peer of a connected socket. A socket is
 * hashed by bind, by its first send, or by connect (ip4_datagram_connect autobinds), and getsockname then names the ident and, once
 * connected, the source address for the peer. The test opens net.ipv4.ping_group_range to group 0 itself (hello373) and puts the
 * old range back. Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up and a
 * veth pair whose far end has no address:
 *   ip link set lo up; ip link add v0 type veth peer name v1; ip link set v1 up; ip link set v0 up; ip addr add 10.0.2.15/24 dev v0):
 *   L. A and B bind ident 4700 (both have SO_REUSEADDR): A's request is answered to B, and so is B's; after C binds 4700 too, A's
 *      request goes to C;
 *   S. a socket bound to 127.0.0.1 first and a wildcard one later: the reply to 127.0.0.1 goes to the later; a wildcard one first and
 *      one bound to our own address later: the reply to 127.0.0.1 goes to the earlier (the later does not take it);
 *   A. D gets an ident from its first send; E binds that ident: D's next request is answered to E;
 *   C. a fresh socket names 0.0.0.0:0; connected to 127.0.0.1 it names 127.0.0.1 and an ident; a socket on ident 4701 connected to
 *      127.0.0.1 and hashed last still takes a reply that came from 127.0.0.2 for that ident. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long psock(void) { return rc(socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)); }
static long usock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long bind_(long s, const unsigned char *a, int l) { return rc(bind((int)s, (const void *)a, l)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long name_(long s, unsigned char *a) { socklen_t l = 16; return rc(getsockname((int)s, (void *)a, &l)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return rc(sendto((int)s, b, n, 0, (const void *)to, l)); }
static long recvfrom_(long s, void *b, int n, unsigned char *from, long *flen) { socklen_t l = (socklen_t)*flen; long r = rc(recvfrom((int)s, b, n, MSG_DONTWAIT, (void *)from, &l)); *flen = l; return r; }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#define FAM(a, f) do { unsigned short fam = (f); memcpy(a, &fam, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define AF_INET 2
#define AF_INET6 10
static long psock(void) { return syscall3(117, AF_INET, 2, 1); }
static long usock(void) { return syscall3(117, AF_INET, 2, 0); }
static long bind_(long s, const unsigned char *a, int l) { return syscall3(118, s, (long)a, l); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long name_(long s, unsigned char *a) { int l = 16; return syscall3(126, s, (long)a, (long)&l); }
static long sendto_(long s, const void *b, int n, const unsigned char *to, int l) { return syscall6(121, s, (long)b, n, 0, (long)to, l); }
static long recvfrom_(long s, void *b, int n, unsigned char *from, long *flen) { int l = (int)*flen; long r = syscall6(122, s, (long)b, n, 0x40, (long)from, (long)&l); *flen = l; return r; }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
/* Ping sockets need the caller's group in net.ipv4.ping_group_range (empty by default): open it to group 0 for the test and put
 * back what was there (on the host the namespace starts with the default range, as MoQiOS does). */
static char range_saved[48];
static long range_fd(int wr) {
#ifdef HOST
    return rc(open("/proc/sys/net/ipv4/ping_group_range", wr ? O_WRONLY : O_RDONLY));
#else
    return syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", wr ? 1 : 0, 0);
#endif
}
static long range_io(long fd, char *b, int n, int wr) {
#ifdef HOST
    return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n));
#else
    return syscall3(wr ? 1 : 10, fd, (long)b, n);
#endif
}
static long open_ping_range(void) {
    long fd = range_fd(0);
    if (fd < 0) return fd;
    long n = range_io(fd, range_saved, sizeof range_saved - 1, 0);
    close_(fd);
    if (n <= 0) return -1;
    range_saved[n] = 0;
    fd = range_fd(1);
    if (fd < 0) return fd;
    char zero[] = "0 0";
    long w = range_io(fd, zero, 3, 1);
    close_(fd);
    return w;
}
static void restore_ping_range(void) {
    long fd = range_fd(1);
    if (fd < 0) return;
    int n = 0;
    while (range_saved[n] && range_saved[n] != '\n') n++;
    range_io(fd, range_saved, n, 1);
    close_(fd);
}
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello372:   ok   " : "hello372:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mk4(unsigned char *s, const unsigned char *ip, int port) {
    for (int i = 0; i < 16; i++) s[i] = 0;
    FAM(s, AF_INET);
    s[2] = (unsigned char)(port >> 8); s[3] = (unsigned char)port;
    if (ip) for (int i = 0; i < 4; i++) s[4 + i] = ip[i];
}
static int port_of(const unsigned char *a) { return (a[2] << 8) | a[3]; }
/* Replies waiting on `s` after a short wait. */
static int got(long s) {
    unsigned char b[64], f[16];
    int n = 0;
    for (int t = 0; t < 10; t++) {
        pump();
        long l = 16;
        while (recvfrom_(s, b, sizeof b, f, &l) > 0) { n++; l = 16; }
    }
    return n;
}
static long bound(const unsigned char *ip, int port) {
    unsigned char a[16];
    long s = psock();
    mk4(a, ip, port);
    long r = bind_(s, a, 16);
    if (r < 0) { close_(s); return r; }
    return s;
}
static long ping_from(long s, const unsigned char *to) {
    unsigned char a[16], req[8] = { 8, 0, 0, 0, 0, 0, 0, 1 };
    mk4(a, to, 0);
    return sendto_(s, req, 8, a, 16);
}
int main(void) {
    print("hello372: ping sockets that share an ident\n");
    long range_rc = open_ping_range();
    unsigned char lo4[4] = { 127, 0, 0, 1 }, lo2[4] = { 127, 0, 0, 2 }, gw[4] = { 10, 0, 2, 2 }, own[4], a[16], name[16];

    long A = bound(0, 4700), B = bound(0, 4700);
    long sa = ping_from(A, lo4);
    int a1 = got(A), b1 = got(B);
    long sb = ping_from(B, lo4);
    int a2 = got(A), b2 = got(B);
    long C = bound(0, 4700);
    long sa2 = ping_from(A, lo4);
    int a3 = got(A), b3 = got(B), c3 = got(C);
    snprintf(msg, sizeof msg, "L: A, B on 4700 (%ld %ld): A sends %ld, A %d B %d; B sends %ld, A %d B %d; C binds (%ld), A sends %ld, A %d B %d C %d (8 0 1 8 0 1 8 0 0 1)", A, B, sa, a1, b1, sb, a2, b2, C, sa2, a3, b3, c3);
    check(A >= 0 && B >= 0 && C >= 0 && sa == 8 && a1 == 0 && b1 == 1 && sb == 8 && a2 == 0 && b2 == 1 && sa2 == 8 && a3 == 0 && b3 == 0 && c3 == 1, msg);
    close_(A); close_(B); close_(C);

    /* Our own address: the source a datagram to the gateway leaves from. */
    long g = usock();
    mk4(a, gw, 19972);
    connect_(g, a);
    name_(g, name);
    close_(g);
    for (int i = 0; i < 4; i++) own[i] = name[4 + i];
    long s1 = bound(lo4, 4702), w1 = bound(0, 4702);
    ping_from(s1, lo4);
    int gs1 = got(s1), gw1 = got(w1);
    long w2 = bound(0, 4703), o2 = bound(own, 4703);
    ping_from(w2, lo4);
    int gw2 = got(w2), go2 = got(o2);
    snprintf(msg, sizeof msg, "S: 127.0.0.1 first, wildcard later: %d %d; wildcard first, %d.%d.%d.%d later: %d %d (0 1 1 0)", gs1, gw1, own[0], own[1], own[2], own[3], gw2, go2);
    check(s1 >= 0 && w1 >= 0 && w2 >= 0 && o2 >= 0 && gs1 == 0 && gw1 == 1 && gw2 == 1 && go2 == 0, msg);
    close_(s1); close_(w1); close_(w2); close_(o2);

    long D = psock();
    ping_from(D, lo4);
    got(D);
    name_(D, name);
    int did = port_of(name);
    long E = bound(0, did);
    ping_from(D, lo4);
    int gd = got(D), ge = got(E);
    snprintf(msg, sizeof msg, "A: D's ident %d, E binds it (%ld), D sends: D %d E %d (0 1)", did, E, gd, ge);
    check(did != 0 && E >= 0 && gd == 0 && ge == 1, msg);
    close_(D); close_(E);

    long F = psock();
    long fn = name_(F, name);
    int fresh = fn == 0 && name[4] == 0 && port_of(name) == 0;
    mk4(a, lo4, 0);
    long fc = connect_(F, a);
    name_(F, name);
    int named = name[4] == 127 && name[7] == 1 && port_of(name) != 0;
    close_(F);
    long Q = bound(0, 4701), P = bound(0, 4701);
    mk4(a, lo4, 0);
    long pc = connect_(P, a);
    ping_from(Q, lo2);
    int gp = got(P), gq = got(Q);
    snprintf(msg, sizeof msg, "C: fresh names 0.0.0.0:0 %d; connect %ld names 127.0.0.1 and an ident %d; P on 4701 connected to 127.0.0.1 (%ld) takes the reply from 127.0.0.2: P %d Q %d (1 0 1 0 1 0)", fresh, fc, named, pc, gp, gq);
    check(fresh && fc == 0 && named && pc == 0 && gp == 1 && gq == 0, msg);
    close_(P); close_(Q);

    restore_ping_range();
    if (range_rc != 3) { print("hello372:   FAIL could not open net.ipv4.ping_group_range\n"); failures++; }
    print(failures ? "hello372: FAIL\n" : "hello372: PASS\n");
    return failures ? 1 : 0;
}
