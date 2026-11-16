/* hello382: proxy ARP entries (net/ipv4/arp.c arp_req_set_public / arp_req_delete_public, pneigh_create / pneigh_delete,
 * arp_format_pneigh_entry). SIOCSARP with ATF_PUBL keeps the address in the proxy table instead of the neighbour cache; /proc/net/arp
 * lists it after the cache entries with flags ATF_PUBL|ATF_PERM and a zero MAC. Measured on the host (build with -DHOST, run as root
 * in `unshare --map-auto --map-root-user -n`, with the veth setup of hello375; the device is v0 there, eth0 on MoQiOS):
 *   P. SIOCSARP 10.0.2.90 ATF_PUBL on the device succeeds, again too; its /proc/net/arp line reads hardware type 0x1, flags 0xc,
 *      MAC 00:00:00:00:00:00 and the device; SIOCGARP on it is ENXIO (it is no neighbour);
 *   N. without a device name and ATF_COM the entry is for every device: type 0x0, device "*"; with ATF_COM and a MAC no device has
 *      it is ENODEV;
 *   M. ATF_NETMASK with 255.255.255.0 is EINVAL; with 0.0.0.0 it switches proxy ARP for the device on and SIOCDARP the same way off
 *      (no line either way);
 *   C. an ordinary entry for 10.0.2.90 sits next to the proxy one; SIOCDARP without ATF_PUBL removes only the ordinary one;
 *   D. SIOCDARP ATF_PUBL on the device removes the proxy entry, again is ENOENT; the "*" one goes with SIOCDARP ATF_PUBL without a
 *      device name.
 * Linux answers ARP requests for a proxy address only when it forwards and the address routes out another device (arp_process);
 * MoQiOS has one NIC and does not forward, so the entries are kept and listed and never answered. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#define DEV "v0"
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock_(int d, int t, int p) { return rc(socket(d, t, p)); }
static long ioctl_(long s, unsigned long c, void *a) { return rc(ioctl((int)s, c, a)); }
static long open_(const char *p, int fl) { return rc(open(p, fl)); }
static long read_(long fd, char *b, int n) { return rc(read((int)fd, b, n)); }
static long write_(long fd, const char *b, int n) { return rc(write((int)fd, b, n)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#define DEV "eth0"
#define AF_INET 2
#define SOCK_DGRAM 2
static long sock_(int d, int t, int p) { return syscall3(117, d, t, p); }
static long ioctl_(long s, unsigned long c, void *a) { return syscall3(165, s, (long)c, (long)a); }
static long open_(const char *p, int fl) { return syscall3(9, (long)p, fl, 0); }
static long read_(long fd, char *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const char *b, int n) { return syscall3(1, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
#define SIOCDARP 0x8953
#define SIOCGARP 0x8954
#define SIOCSARP 0x8955
#define ATF_COM 0x02
#define ATF_PERM 0x04
#define ATF_PUBL 0x08
#define ATF_NETMASK 0x20
static int failures;
static char msg[640];
static char text[4096];
static void check(int ok, const char *w) {
    print(ok ? "hello382:   ok   " : "hello382:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* struct arpreq: arp_pa @0, arp_ha @16 (family, MAC @18), arp_flags @32, arp_netmask @36 (address @40), arp_dev[16] @52. */
static void mkreq(unsigned char *r, int last, int flags, const char *dev, const unsigned char *mask) {
    for (int i = 0; i < 68; i++) r[i] = 0;
    r[0] = AF_INET;
    r[4] = 10; r[5] = 0; r[6] = 2; r[7] = (unsigned char)last;
    r[16] = 1;
    r[18] = 2; r[19] = 0x5e; r[23] = (unsigned char)last;
    r[32] = (unsigned char)flags;
    if (mask) { r[36] = AF_INET; for (int i = 0; i < 4; i++) r[40 + i] = mask[i]; }
    for (int i = 0; dev[i] && i < 15; i++) r[52 + i] = (unsigned char)dev[i];
}
static long arp(long s, unsigned long cmd, int last, int flags, const char *dev, const unsigned char *mask) {
    unsigned char r[68]; mkreq(r, last, flags, dev, mask); return ioctl_(s, cmd, r);
}
static long slurp(void) {
    long fd = open_("/proc/net/arp", 0);
    if (fd < 0) return fd;
    long n = 0;
    for (;;) {
        long r = read_(fd, text + n, 37);
        if (r <= 0) break;
        n += r;
        if (n > (long)sizeof text - 64) break;
    }
    close_(fd);
    text[n] = 0;
    return n;
}
static int has_line(const char *line) {
    int ll = (int)strlen(line);
    for (const char *p = text; *p; ) {
        const char *e = p;
        while (*e && *e != '\n') e++;
        if (e - p + 1 == ll && memcmp(p, line, ll) == 0) return 1;
        p = *e ? e + 1 : e;
    }
    return 0;
}
static int count_addr(const char *ip) {
    int l = (int)strlen(ip), n = 0;
    for (const char *p = text; *p; ) {
        if (memcmp(p, ip, l) == 0 && p[l] == ' ') n++;
        while (*p && *p != '\n') p++;
        if (*p) p++;
    }
    return n;
}
int main(void) {
    print("hello382: proxy ARP entries (ATF_PUBL)\n");
    long s = sock_(AF_INET, SOCK_DGRAM, 0);
    unsigned char r[68];
    char line[160];
    snprintf(line, sizeof line, "10.0.2.90        0x1         0xc         00:00:00:00:00:00     *        %s\n", DEV);

    long p1 = arp(s, SIOCSARP, 90, ATF_PUBL, DEV, 0), p2 = arp(s, SIOCSARP, 90, ATF_PUBL, DEV, 0);
    slurp();
    int pl = has_line(line);
    mkreq(r, 90, 0, DEV, 0);
    long pg = ioctl_(s, SIOCGARP, r);
    snprintf(msg, sizeof msg, "P: SIOCSARP ATF_PUBL %ld, again %ld; the proxy line %d; SIOCGARP %ld (0 0 1 -6)", p1, p2, pl, pg);
    check(p1 == 0 && p2 == 0 && pl && pg == -6, msg);

    long n1 = arp(s, SIOCSARP, 91, ATF_PUBL, "", 0);
    slurp();
    int nl = has_line("10.0.2.91        0x0         0xc         00:00:00:00:00:00     *        *\n");
    long n2 = arp(s, SIOCSARP, 92, ATF_PUBL | ATF_COM, "", 0);
    snprintf(msg, sizeof msg, "N: no device %ld, line for every device %d; ATF_COM with an unknown MAC %ld (0 1 -19)", n1, nl, n2);
    check(n1 == 0 && nl && n2 == -19, msg);

    unsigned char m24[4] = { 255, 255, 255, 0 }, m0[4] = { 0, 0, 0, 0 };
    long m1 = arp(s, SIOCSARP, 93, ATF_PUBL | ATF_NETMASK, DEV, m24);
    long m2 = arp(s, SIOCSARP, 93, ATF_PUBL | ATF_NETMASK, DEV, m0);
    slurp();
    int ml = count_addr("10.0.2.93");
    long m3 = arp(s, SIOCDARP, 93, ATF_PUBL | ATF_NETMASK, DEV, m0);
    snprintf(msg, sizeof msg, "M: netmask /24 %ld; netmask 0 on %ld (lines %d), off %ld (-22 0 0 0)", m1, m2, ml, m3);
    check(m1 == -22 && m2 == 0 && ml == 0 && m3 == 0, msg);

    long c1 = arp(s, SIOCSARP, 90, ATF_COM, DEV, 0);
    slurp();
    int cn = count_addr("10.0.2.90");
    long c2 = arp(s, SIOCDARP, 90, 0, DEV, 0);
    slurp();
    int cn2 = count_addr("10.0.2.90"), cl = has_line(line);
    snprintf(msg, sizeof msg, "C: ordinary entry %ld, lines %d; SIOCDARP %ld leaves %d line, the proxy one %d (0 2 0 1 1)", c1, cn, c2, cn2, cl);
    check(c1 == 0 && cn == 2 && c2 == 0 && cn2 == 1 && cl, msg);

    long d1 = arp(s, SIOCDARP, 90, ATF_PUBL, DEV, 0), d2 = arp(s, SIOCDARP, 90, ATF_PUBL, DEV, 0);
    long d3 = arp(s, SIOCDARP, 91, ATF_PUBL, "", 0);
    slurp();
    int left = count_addr("10.0.2.90") + count_addr("10.0.2.91");
    snprintf(msg, sizeof msg, "D: SIOCDARP ATF_PUBL %ld, again %ld; the \"*\" one %ld; lines left %d (0 -2 0 0)", d1, d2, d3, left);
    check(d1 == 0 && d2 == -2 && d3 == 0 && left == 0, msg);
    close_(s);
    print(failures ? "hello382: FAIL\n" : "hello382: PASS\n");
    return failures ? 1 : 0;
}
