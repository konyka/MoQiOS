/* hello375: a datagram to an IPv4 next hop whose MAC is not known yet is queued on the neighbour while ARP asks for it, and the send
 * succeeds (Linux __neigh_event_send → arp_queue); once the reply comes the queued frames go out; when nobody answers they are
 * dropped silently. Also the ARP ioctls SIOCGARP and SIOCDARP (net/ipv4/arp.c arp_ioctl). Measured on the host (build with -DHOST,
 * run as root in `unshare --map-auto --map-root-user -n`, with a veth pair whose far end lives in a second namespace holding
 * 10.0.2.2 and 10.0.2.3, see tools/tests or the doc section for the commands; the device is v0 there, eth0 on MoQiOS):
 *   G. after a ping to the gateway 10.0.2.2, SIOCGARP on it answers flags ATF_COM, hardware family ARPHRD_ETHER and a nonzero MAC;
 *   D. SIOCDARP removes it (SIOCGARP is then ENXIO, a second SIOCDARP ENXIO); an AF_INET6 address is EPFNOSUPPORT; SIOCGARP on an
 *      unknown device is ENODEV; a non-socket descriptor is ENOTTY;
 *   R. with the gateway's entry gone, an echo request to it is accepted (16) and its reply arrives; the entry is back afterwards;
 *   U. with 10.0.2.3's entry gone, a UDP datagram to 10.0.2.3:9 is accepted (16) and the entry comes back;
 *   Q. to 10.0.2.99, which nobody answers: two UDP sendto, a connected send and a ping all return 16; nothing comes back in 4 s
 *      and SO_ERROR stays 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define DEV "v0"
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock_(int d, int t, int p) { return rc(socket(d, t, p)); }
static long connect_(long s, const unsigned char *a) { return rc(connect((int)s, (const void *)a, 16)); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return rc(sendto((int)s, b, n, 0, (const void *)to, 16)); }
static long send_(long s, const void *b, int n) { return rc(send((int)s, b, n, 0)); }
static long recv_(long s, void *b, int n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long ioctl_(long s, unsigned long c, void *a) { return rc(ioctl((int)s, c, a)); }
static long getint(long s, int opt) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, SOL_SOCKET, opt, &v, &l)); return r < 0 ? r : v; }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long open_ro(const char *p) { return rc(open(p, O_RDONLY)); }
static void close_(long s) { close((int)s); }
#define FAM(a, f) do { unsigned short fam_v_ = (f); memcpy(a, &fam_v_, 2); } while (0)
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define DEV "eth0"
#define AF_INET 2
#define AF_INET6 10
#define SOCK_DGRAM 2
#define SO_ERROR 4
static long sock_(int d, int t, int p) { return syscall3(117, d, t, p); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
static long send_(long s, const void *b, int n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recv_(long s, void *b, int n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long ioctl_(long s, unsigned long c, void *a) { return syscall3(165, s, (long)c, (long)a); }
static long getint(long s, int opt) { int v = -1; int l = 4; long r = syscall5(133, s, 1, opt, (long)&v, (long)&l); return r < 0 ? r : v; }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long open_ro(const char *p) { return syscall3(9, (long)p, 0, 0); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
#define SIOCDARP 0x8953
#define SIOCGARP 0x8954
#define ATF_COM 0x02
static char range_saved[48];
static long range_io(const char *t, int wr) {
#ifdef HOST
    long fd = rc(open("/proc/sys/net/ipv4/ping_group_range", wr ? O_WRONLY : O_RDONLY));
#else
    long fd = syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", wr ? 1 : 0, 0);
#endif
    if (fd < 0) return fd;
    int n = 0;
    if (wr) while (t[n] && t[n] != '\n') n++;
#ifdef HOST
    long r = wr ? rc(write((int)fd, t, n)) : rc(read((int)fd, range_saved, sizeof range_saved - 1));
#else
    long r = wr ? syscall3(1, fd, (long)t, n) : syscall3(10, fd, (long)range_saved, sizeof range_saved - 1);
#endif
    close_(fd);
    if (!wr && r > 0) range_saved[r] = 0;
    return r;
}
static int failures;
static char msg[480];
static void check(int ok, const char *w) {
    print(ok ? "hello375:   ok   " : "hello375:   FAIL ");
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
/* struct arpreq: arp_pa @0, arp_ha @16, arp_flags @32, arp_netmask @36, arp_dev[16] @52; 68 bytes. */
static void mkreq(unsigned char *r, const unsigned char *ip, const char *dev, int fam) {
    for (int i = 0; i < 68; i++) r[i] = 0;
    mk4(r, ip, 0);
    FAM(r, fam);
    for (int i = 0; dev[i] && i < 15; i++) r[52 + i] = (unsigned char)dev[i];
}
static long arp_get(long s, const unsigned char *ip, unsigned char *r) { mkreq(r, ip, DEV, AF_INET); return ioctl_(s, SIOCGARP, r); }
static long arp_del(long s, const unsigned char *ip) { unsigned char r[68]; mkreq(r, ip, DEV, AF_INET); return ioctl_(s, SIOCDARP, r); }
static int flags_of(const unsigned char *r) { return r[32] | (r[33] << 8); }
static long ping_wait(long p, const unsigned char *dst) {
    unsigned char a[16], req[16] = { 8, 0, 0, 0, 0, 0, 0, 3, 'h', 'e', 'l', 'l', 'o', '3', '7', '5' }, rep[64];
    mk4(a, dst, 0);
    long s = sendto_(p, req, 16, a);
    if (s != 16) return s < 0 ? s : -1000;
    long r = -11;
    for (int t = 0; t < 100 && r == -11; t++) { r = recv_(p, rep, sizeof rep); if (r == -11) pump(); }
    return r == 16 && rep[0] == 0 ? 16 : (r < 0 ? r : -1001);
}
int main(void) {
    print("hello375: unresolved IPv4 next hop: frames wait for ARP; SIOCGARP/SIOCDARP\n");
    long saved = range_io(0, 0);
    range_io("0 0", 1);
    unsigned char gw[4] = { 10, 0, 2, 2 }, dns[4] = { 10, 0, 2, 3 }, far[4] = { 10, 0, 2, 99 };
    unsigned char r[68], a[16], b[16] = "hello375-queued";
    long s = sock_(AF_INET, SOCK_DGRAM, 0), p = sock_(AF_INET, SOCK_DGRAM, 1);

    long g0 = ping_wait(p, gw);
    long g1 = arp_get(s, gw, r);
    int mac = 0;
    for (int i = 0; i < 6; i++) mac |= r[18 + i];
    int fam = r[16] | (r[17] << 8);
    int devok = memcmp(r + 52, DEV, sizeof DEV) == 0;
    snprintf(msg, sizeof msg, "G: ping gateway %ld; SIOCGARP %ld flags 0x%x ATF_COM %d, hw family %d, MAC set %d, device kept %d (16 0 1 1 1 1)", g0, g1, flags_of(r), (flags_of(r) & ATF_COM) != 0, fam, mac != 0, devok);
    check(g0 == 16 && g1 == 0 && (flags_of(r) & ATF_COM) && fam == 1 && mac && devok, msg);

    long d1 = arp_del(s, gw);
    long d2 = arp_get(s, gw, r);
    long d3 = arp_del(s, gw);
    mkreq(r, gw, DEV, AF_INET6);
    long d4 = ioctl_(s, SIOCDARP, r);
    mkreq(r, gw, "nope0", AF_INET);
    long d5 = ioctl_(s, SIOCGARP, r);
    long dir = open_ro("/");
    mkreq(r, gw, DEV, AF_INET);
    long d6 = ioctl_(dir, SIOCGARP, r);
    if (dir >= 0) close_(dir);
    snprintf(msg, sizeof msg, "D: SIOCDARP %ld, then SIOCGARP %ld, SIOCDARP again %ld; AF_INET6 %ld; unknown device %ld; a directory %ld (0 -6 -6 -96 -19 -25)", d1, d2, d3, d4, d5, d6);
    check(d1 == 0 && d2 == -6 && d3 == -6 && d4 == -96 && d5 == -19 && d6 == -25, msg);

    long r1 = ping_wait(p, gw);
    long r2 = arp_get(s, gw, r);
    snprintf(msg, sizeof msg, "R: gateway entry gone: ping %ld, entry back %ld (16 0)", r1, r2);
    check(r1 == 16 && r2 == 0, msg);

    long u0 = arp_del(s, dns);
    mk4(a, dns, 9);
    long u1 = sendto_(s, b, 16, a);
    long u2 = -1;
    for (int t = 0; t < 100 && u2 != 0; t++) { u2 = arp_get(s, dns, r); if (u2 != 0) pump(); }
    snprintf(msg, sizeof msg, "U: SIOCDARP 10.0.2.3 %ld; UDP to it %ld; entry back %ld (0/-6 16 0)", u0, u1, u2);
    check((u0 == 0 || u0 == -6) && u1 == 16 && u2 == 0, msg);

    mk4(a, far, 9);
    long q1 = sendto_(s, b, 16, a), q2 = sendto_(s, b, 16, a);
    long c = sock_(AF_INET, SOCK_DGRAM, 0);
    long qc = connect_(c, a);
    long q3 = send_(c, b, 16);
    long pc = sock_(AF_INET, SOCK_DGRAM, 1);
    unsigned char req[16] = { 8, 0, 0, 0, 0, 0, 0, 4 };
    mk4(a, far, 0);
    long q4 = sendto_(pc, req, 16, a);
    long back = 0;
    for (int t = 0; t < 200; t++) {
        unsigned char x[64];
        if (recv_(c, x, sizeof x) != -11 || recv_(pc, x, sizeof x) != -11) back++;
        pump();
    }
    long e = getint(c, SO_ERROR);
    snprintf(msg, sizeof msg, "Q: to 10.0.2.99 (no answer): sendto %ld %ld, connect %ld send %ld, ping %ld; anything back in 4 s %ld, SO_ERROR %ld (16 16 0 16 16 0 0)", q1, q2, qc, q3, q4, back, e);
    check(q1 == 16 && q2 == 16 && qc == 0 && q3 == 16 && q4 == 16 && back == 0 && e == 0, msg);
    close_(c); close_(pc); close_(s); close_(p);

    if (saved > 0) range_io(range_saved, 1);
    else { print("hello375:   FAIL could not read net.ipv4.ping_group_range\n"); failures++; }
    print(failures ? "hello375: FAIL\n" : "hello375: PASS\n");
    return failures ? 1 : 0;
}
