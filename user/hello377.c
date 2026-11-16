/* hello377: SIOCSARP adds or replaces an ARP entry (net/ipv4/arp.c arp_req_set): ATF_PERM makes it permanent (NUD_PERMANENT,
 * reported back as ATF_PERM|ATF_COM), without it the entry is an ordinary one (ATF_COM); setting it again replaces the MAC and the
 * state. Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n`, with the veth setup of
 * hello375; the device is v0 there, eth0 on MoQiOS):
 *   P. SIOCSARP 10.0.2.77 with ATF_COM|ATF_PERM: SIOCGARP reports flags 0x6, the MAC and family ARPHRD_ETHER; a UDP datagram to it
 *      is sent (16) and the entry stays;
 *   T. SIOCSARP 10.0.2.78 with ATF_COM only: flags 0x2; set again with another MAC: the new MAC; the permanent 10.0.2.77 set again
 *      without ATF_PERM becomes an ordinary entry (0x2);
 *   C. without ATF_COM (no MAC given) a new entry is EINVAL and nothing completed is left (Linux keeps an incomplete neighbour,
 *      SIOCGARP flags 0; MoQiOS has none, ENXIO); a permanent one keeps its MAC and becomes ordinary (0x2);
 *   N. without a device name an on-link address is set on the NIC; an off-link one is ENETUNREACH (arp_req_set wants a link route);
 *   E. hardware family 0 is EINVAL, an unknown device ENODEV, an AF_INET6 address EPFNOSUPPORT, lo EINVAL (its type is not ether);
 *   U. a child that drops to uid 1000 (losing CAP_NET_ADMIN) gets EPERM from SIOCSARP, and SIOCGARP still reads the entry;
 *   D. SIOCDARP removes them. */
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
#include <sys/wait.h>
static long fork_(void) { return rc(fork()); }
static void setuid_(int u) { if (setuid(u)) {} }
static void exit_(int c) { fflush(stdout); _exit(c); }
static int wait_status(long pid) { int st = -1; waitpid((int)pid, &st, 0); return st; }
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
static long fork_(void) { return syscall1(57, 0); }
static void setuid_(int u) { syscall1(174, u); }
static void exit_(int c) { syscall1(2, c); for (;;) {} }
static int wait_status(long pid) { int st = -1; syscall3(6, pid, (long)&st, 0); return st; }
#endif
#define SIOCDARP 0x8953
#define SIOCGARP 0x8954
#define SIOCSARP 0x8955
#define ATF_COM 0x02
#define ATF_PERM 0x04
#define ATF_PUBL 0x08
static int failures;
static char msg[480];
static void check(int ok, const char *w) {
    print(ok ? "hello377:   ok   " : "hello377:   FAIL ");
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
/* struct arpreq: arp_pa @0, arp_ha @16 (family, MAC @18), arp_flags @32, arp_netmask @36, arp_dev[16] @52; 68 bytes. */
static void mkreq(unsigned char *r, const unsigned char *ip, const char *dev, int flags, int hwfam, const unsigned char *mac) {
    for (int i = 0; i < 68; i++) r[i] = 0;
    mk4(r, ip, 0);
    r[16] = (unsigned char)hwfam;
    if (mac) for (int i = 0; i < 6; i++) r[18 + i] = mac[i];
    r[32] = (unsigned char)flags;
    for (int i = 0; dev[i] && i < 15; i++) r[52 + i] = (unsigned char)dev[i];
}
static long arp_set(long s, const unsigned char *ip, const char *dev, int flags, int hwfam, const unsigned char *mac) {
    unsigned char r[68]; mkreq(r, ip, dev, flags, hwfam, mac); return ioctl_(s, SIOCSARP, r);
}
static long arp_get(long s, const unsigned char *ip, unsigned char *r) { mkreq(r, ip, DEV, 0, 0, 0); return ioctl_(s, SIOCGARP, r); }
static long arp_del(long s, const unsigned char *ip) { unsigned char r[68]; mkreq(r, ip, DEV, 0, 0, 0); return ioctl_(s, SIOCDARP, r); }
static int flags_of(const unsigned char *r) { return r[32] | (r[33] << 8); }
static int mac_is(const unsigned char *r, const unsigned char *m) { for (int i = 0; i < 6; i++) if (r[18 + i] != m[i]) return 0; return 1; }
int main(void) {
    print("hello377: SIOCSARP sets ARP entries (permanent or not)\n");
    unsigned char ip77[4] = { 10, 0, 2, 77 }, ip78[4] = { 10, 0, 2, 78 }, ip79[4] = { 10, 0, 2, 79 }, off[4] = { 192, 0, 2, 1 };
    unsigned char m1[6] = { 2, 0, 0, 0, 0, 0x77 }, m2[6] = { 2, 0, 0, 0, 0, 0x78 };
    unsigned char r[68], a[16], b[16] = "hello377-static";
    long s = sock_(AF_INET, SOCK_DGRAM, 0);

    long p1 = arp_set(s, ip77, DEV, ATF_COM | ATF_PERM, 1, m1);
    long p2 = arp_get(s, ip77, r);
    int pf = flags_of(r), pm = mac_is(r, m1), pfam = r[16];
    mk4(a, ip77, 9);
    long p3 = sendto_(s, b, 16, a);
    long p4 = arp_get(s, ip77, r);
    int pm2 = mac_is(r, m1);
    snprintf(msg, sizeof msg, "P: SIOCSARP perm %ld; SIOCGARP %ld flags 0x%x MAC %d family %d; UDP to it %ld; still %ld MAC %d (0 0 0x6 1 1 16 0 1)", p1, p2, pf, pm, pfam, p3, p4, pm2);
    check(p1 == 0 && p2 == 0 && pf == 6 && pm && pfam == 1 && p3 == 16 && p4 == 0 && pm2, msg);

    long t1 = arp_set(s, ip78, DEV, ATF_COM, 1, m2);
    long t2 = arp_get(s, ip78, r);
    int tf = flags_of(r), tm = mac_is(r, m2);
    long t3 = arp_set(s, ip78, DEV, ATF_COM, 1, m1);
    long t4 = arp_get(s, ip78, r);
    int tm2 = mac_is(r, m1);
    long t5 = arp_set(s, ip77, DEV, ATF_COM, 1, m2);
    long t6 = arp_get(s, ip77, r);
    int tf3 = flags_of(r), tm3 = mac_is(r, m2);
    snprintf(msg, sizeof msg, "T: SIOCSARP %ld; flags 0x%x MAC %d (%ld); replaced %ld MAC %d (%ld); perm entry reset %ld flags 0x%x MAC %d (%ld) (0 0x2 1 0, 0 1 0, 0 0x2 1 0)", t1, tf, tm, t2, t3, tm2, t4, t5, tf3, tm3, t6);
    check(t1 == 0 && t2 == 0 && tf == 2 && tm && t3 == 0 && t4 == 0 && tm2 && t5 == 0 && t6 == 0 && tf3 == 2 && tm3, msg);

    /* Without ATF_COM no MAC is given: a new entry cannot be made, an existing one keeps its MAC. */
    unsigned char ip80[4] = { 10, 0, 2, 80 };
    long c1 = arp_set(s, ip80, DEV, 0, 1, m1);
    long c2 = arp_get(s, ip80, r);
    int c2f = flags_of(r);
    arp_set(s, ip78, DEV, ATF_COM | ATF_PERM, 1, m2);
    long c3 = arp_set(s, ip78, DEV, 0, 1, m1);
    long c4 = arp_get(s, ip78, r);
    int cf = flags_of(r), cm = mac_is(r, m2);
    snprintf(msg, sizeof msg, "C: no ATF_COM, new entry %ld (then %ld flags 0x%x); existing permanent one %ld, flags 0x%x, MAC kept %d (%ld) (-22 -6/0 0 0 0x2 1 0)", c1, c2, c2f, c3, cf, cm, c4);
    check(c1 == -22 && (c2 == -6 || (c2 == 0 && c2f == 0)) && c3 == 0 && cf == 2 && cm && c4 == 0, msg);
    arp_del(s, ip80);

    long n1 = arp_set(s, ip79, "", ATF_COM, 1, m1);
    long n2 = arp_get(s, ip79, r);
    long n3 = arp_set(s, off, "", ATF_COM, 1, m1);
    snprintf(msg, sizeof msg, "N: no device, on-link %ld (entry %ld); off-link %ld (0 0 -101)", n1, n2, n3);
    check(n1 == 0 && n2 == 0 && n3 == -101, msg);

    long e1 = arp_set(s, ip79, DEV, ATF_COM, 0, m1);
    long e1g = arp_get(s, ip79, r);
    int e1f = r[16] | (r[17] << 8), e1m = mac_is(r, m1);
    unsigned char rl[68]; mkreq(rl, ip79, DEV, ATF_COM, 0, m1); rl[16] = 0x04; rl[17] = 0x03; /* 772, ARPHRD_LOOPBACK */
    long e1b = ioctl_(s, SIOCSARP, rl);
    long e2 = arp_set(s, ip79, "nope0", ATF_COM, 1, m1);
    unsigned char r6[68]; mkreq(r6, ip79, DEV, ATF_COM, 1, m1); FAM(r6, AF_INET6);
    long e3 = ioctl_(s, SIOCSARP, r6);
    long e4 = arp_set(s, ip79, "lo", ATF_COM, 1, m1);
    snprintf(msg, sizeof msg, "E: hw family 0 %ld (entry %ld family %d MAC %d); family 772 %ld; unknown device %ld; AF_INET6 %ld; lo %ld (0 0 1 1 -22 -19 -96 -22)", e1, e1g, e1f, e1m, e1b, e2, e3, e4);
    check(e1 == 0 && e1g == 0 && e1f == 1 && e1m && e1b == -22 && e2 == -19 && e3 == -96 && e4 == -22, msg);

    /* U: without CAP_NET_ADMIN SIOCSARP is EPERM, SIOCGARP still reads the entry. */
    long kid = fork_();
    if (kid == 0) {
        setuid_(1000);
        unsigned char rr[68];
        long k1 = arp_set(s, ip79, DEV, ATF_COM, 1, m2);
        long k2 = arp_get(s, ip79, rr);
        exit_(k1 == -1 && k2 == 0 && mac_is(rr, m1) ? 0 : 1);
    }
    int ks = wait_status(kid);
    snprintf(msg, sizeof msg, "U: a uid-1000 child: SIOCSARP EPERM and SIOCGARP reads the entry (child status 0x%x, 0)", ks);
    check(kid > 0 && ks == 0, msg);

    long d1 = arp_del(s, ip77), d2 = arp_get(s, ip77, r), d3 = arp_del(s, ip78), d4 = arp_del(s, ip79);
    snprintf(msg, sizeof msg, "D: SIOCDARP %ld, SIOCGARP after %ld, others %ld %ld (0 -6 0 0)", d1, d2, d3, d4);
    check(d1 == 0 && d2 == -6 && d3 == 0 && d4 == 0, msg);
    close_(s);
    print(failures ? "hello377: FAIL\n" : "hello377: PASS\n");
    return failures ? 1 : 0;
}
