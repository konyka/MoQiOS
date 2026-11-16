/* hello384: incomplete IPv4 neighbours (net/core/neighbour.c __neigh_event_send, arp_state_to_flags, arp_req_set, arp_invalidate).
 * Sending to an on-link address whose MAC is unknown leaves a neighbour entry without a MAC: /proc/net/arp lists it with flags 0x0
 * and MAC 00:00:00:00:00:00 and SIOCGARP answers it with flags 0. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n`, with the veth setup of hello375, where nobody answers 10.0.2.97 or 10.0.2.98; the device
 * is v0 there, eth0 on MoQiOS):
 *   I. a UDP datagram to 10.0.2.98 is accepted (16); its /proc/net/arp line reads type 0x1, flags 0x0, a zero MAC and the device;
 *      SIOCGARP on it returns 0 with flags 0, hardware family 1 and a zero MAC;
 *   T. a non-blocking TCP connect to 10.0.2.97 is EINPROGRESS and leaves the same kind of entry;
 *   F. 4 s later, with nobody having answered, both are still there with flags 0 (NUD_FAILED is kept until garbage collection);
 *   S. SIOCSARP without ATF_COM on 10.0.2.98 is EINVAL and leaves it at flags 0; with ATF_COM and a MAC it becomes flags 0x2 with
 *      that MAC, in /proc/net/arp too;
 *   P. SIOCSARP with ATF_PERM and no MAC on 10.0.2.97 succeeds: flags 0x6 and a zero MAC;
 *   D. SIOCDARP removes both (0), again is ENXIO, and their lines are gone. */
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
static long ioctl_(long s, unsigned long c, void *a) { return rc(ioctl((int)s, c, a)); }
static void pump(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long open_ro(const char *p) { return rc(open(p, O_RDONLY)); }
static long read_(long fd, char *b, int n) { return rc(read((int)fd, b, n)); }
#define O_NONBLOCK_SOCK SOCK_NONBLOCK
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
#define SOCK_STREAM 1
#define O_NONBLOCK_SOCK 0x800
static long sock_(int d, int t, int p) { return syscall3(117, d, t, p); }
static long connect_(long s, const unsigned char *a) { return syscall3(124, s, (long)a, 16); }
static long sendto_(long s, const void *b, int n, const unsigned char *to) { return syscall6(121, s, (long)b, n, 0, (long)to, 16); }
static long ioctl_(long s, unsigned long c, void *a) { return syscall3(165, s, (long)c, (long)a); }
static void pump(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long open_ro(const char *p) { return syscall3(9, (long)p, 0, 0); }
static long read_(long fd, char *b, int n) { return syscall3(10, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#define FAM(a, f) do { (a)[0] = (unsigned char)(f); (a)[1] = 0; } while (0)
#endif
#define SIOCDARP 0x8953
#define SIOCGARP 0x8954
#define SIOCSARP 0x8955
#define ATF_COM 0x02
#define ATF_PERM 0x04
static int failures;
static char msg[560];
static char text[4096];
static void check(int ok, const char *w) {
    print(ok ? "hello384:   ok   " : "hello384:   FAIL ");
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
static long arp(long s, unsigned long cmd, int last, int flags, int with_mac, unsigned char *r) {
    unsigned char ip[4] = { 10, 0, 2, (unsigned char)last };
    for (int i = 0; i < 68; i++) r[i] = 0;
    mk4(r, ip, 0);
    r[16] = 1;
    if (with_mac) { r[18] = 2; r[23] = (unsigned char)last; }
    r[32] = (unsigned char)flags;
    for (int i = 0; DEV[i] && i < 15; i++) r[52 + i] = (unsigned char)DEV[i];
    return ioctl_(s, cmd, r);
}
static int flags_of(const unsigned char *r) { return r[32] | (r[33] << 8); }
static int mac_zero(const unsigned char *r) { int m = 0; for (int i = 0; i < 6; i++) m |= r[18 + i]; return m == 0; }
static long slurp(void) {
    long fd = open_ro("/proc/net/arp");
    if (fd < 0) { text[0] = 0; return fd; }
    long n = read_(fd, text, sizeof text - 1);
    close_(fd);
    text[n > 0 ? n : 0] = 0;
    return n;
}
/* Whether /proc/net/arp has the line for 10.0.2.<last> with the given flags and MAC. */
static int has_line(int last, const char *flags, const char *mac) {
    char want[160];
    char addr[16];
    snprintf(addr, sizeof addr, "10.0.2.%d", last);
    snprintf(want, sizeof want, "%-16s 0x%-10x0x%-10s%-17s     *        %s\n", addr, 1, flags, mac, DEV);
    slurp();
    return strstr(text, want) != 0;
}
static int listed(int last) {
    char addr[20];
    snprintf(addr, sizeof addr, "\n10.0.2.%d ", last);
    slurp();
    return strstr(text, addr) != 0;
}
int main(void) {
    print("hello384: incomplete IPv4 neighbours\n");
    unsigned char r[68], a[16], b[16] = "hello384-unans.";
    unsigned char n98[4] = { 10, 0, 2, 98 }, n97[4] = { 10, 0, 2, 97 };
    long s = sock_(AF_INET, SOCK_DGRAM, 0);
    arp(s, SIOCDARP, 98, 0, 0, r);
    arp(s, SIOCDARP, 97, 0, 0, r);

    mk4(a, n98, 9);
    long i1 = sendto_(s, b, 16, a);
    pump();
    int i2 = has_line(98, "0", "00:00:00:00:00:00");
    long i3 = arp(s, SIOCGARP, 98, 0, 0, r);
    int i4 = flags_of(r), i5 = r[16] | (r[17] << 8), i6 = mac_zero(r);
    snprintf(msg, sizeof msg, "I: UDP to 10.0.2.98 %ld; line with flags 0x0 and a zero MAC %d; SIOCGARP %ld flags 0x%x family %d MAC zero %d (16 1 0 0x0 1 1)", i1, i2, i3, i4, i5, i6);
    check(i1 == 16 && i2 && i3 == 0 && i4 == 0 && i5 == 1 && i6, msg);

    long t = sock_(AF_INET, SOCK_STREAM | O_NONBLOCK_SOCK, 0);
    mk4(a, n97, 80);
    long t1 = connect_(t, a);
    pump();
    long t2 = arp(s, SIOCGARP, 97, 0, 0, r);
    int t3 = flags_of(r), t4 = has_line(97, "0", "00:00:00:00:00:00");
    close_(t);
    snprintf(msg, sizeof msg, "T: non-blocking connect to 10.0.2.97 %ld; SIOCGARP %ld flags 0x%x; line %d (-115 0 0x0 1)", t1, t2, t3, t4);
    check(t1 == -115 && t2 == 0 && t3 == 0 && t4, msg);

    for (int k = 0; k < 200; k++) pump();
    long f1 = arp(s, SIOCGARP, 98, 0, 0, r);
    int f2 = flags_of(r);
    long f3 = arp(s, SIOCGARP, 97, 0, 0, r);
    int f4 = flags_of(r), f5 = has_line(98, "0", "00:00:00:00:00:00"), f6 = has_line(97, "0", "00:00:00:00:00:00");
    snprintf(msg, sizeof msg, "F: 4 s later: 10.0.2.98 %ld flags 0x%x, 10.0.2.97 %ld flags 0x%x, lines %d %d (0 0x0 0 0x0 1 1)", f1, f2, f3, f4, f5, f6);
    check(f1 == 0 && f2 == 0 && f3 == 0 && f4 == 0 && f5 && f6, msg);

    long s1 = arp(s, SIOCSARP, 98, 0, 0, r);
    long s2 = arp(s, SIOCGARP, 98, 0, 0, r);
    int s3 = flags_of(r);
    long s4 = arp(s, SIOCSARP, 98, ATF_COM, 1, r);
    long s5 = arp(s, SIOCGARP, 98, 0, 0, r);
    int s6 = flags_of(r), s7 = r[18] == 2 && r[23] == 98, s8 = has_line(98, "2", "02:00:00:00:00:62");
    snprintf(msg, sizeof msg, "S: SIOCSARP without ATF_COM %ld (then %ld flags 0x%x); with ATF_COM %ld, then %ld flags 0x%x MAC %d line %d (-22 0 0x0 0 0 0x2 1 1)", s1, s2, s3, s4, s5, s6, s7, s8);
    check(s1 == -22 && s2 == 0 && s3 == 0 && s4 == 0 && s5 == 0 && s6 == 2 && s7 && s8, msg);

    long p1 = arp(s, SIOCSARP, 97, ATF_PERM, 0, r);
    long p2 = arp(s, SIOCGARP, 97, 0, 0, r);
    int p3 = flags_of(r), p4 = mac_zero(r), p5 = has_line(97, "6", "00:00:00:00:00:00");
    snprintf(msg, sizeof msg, "P: SIOCSARP ATF_PERM without a MAC %ld; SIOCGARP %ld flags 0x%x MAC zero %d line %d (0 0 0x6 1 1)", p1, p2, p3, p4, p5);
    check(p1 == 0 && p2 == 0 && p3 == 6 && p4 && p5, msg);

    long d1 = arp(s, SIOCDARP, 98, 0, 0, r), d2 = arp(s, SIOCDARP, 97, 0, 0, r), d3 = arp(s, SIOCDARP, 98, 0, 0, r);
    int d4 = listed(98), d5 = listed(97);
    snprintf(msg, sizeof msg, "D: SIOCDARP %ld %ld, again %ld; lines left %d %d (0 0 -6 0 0)", d1, d2, d3, d4, d5);
    check(d1 == 0 && d2 == 0 && d3 == -6 && !d4 && !d5, msg);

    close_(s);
    print(failures ? "hello384: FAIL\n" : "hello384: PASS\n");
    return failures ? 1 : 0;
}
