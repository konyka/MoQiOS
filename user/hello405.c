/* hello405: IPv4 neighbour unreachability detection (net/core/neighbour.c neigh_timer_handler, __neigh_event_send, neigh_update;
 * net/ipv4/arp.c arp_process, arp_solicit). An entry set with SIOCSARP is STALE; a send to it moves it to DELAY, 5 s later to
 * PROBE, which asks the cached MAC by unicast once a second; an answer makes it REACHABLE, three unanswered probes FAILED (flags 0,
 * the MAC still listed, nothing resolves it). An entry nothing is sent to stays as it is. Measured on the host (build with -DHOST,
 * run as root in `unshare --map-auto --map-root-user -n` with the veth setup of hello375: the far end holds 10.0.2.2, nobody
 * answers 10.0.2.95 or 10.0.2.96; the device is v0 there, eth0 on MoQiOS):
 *   F. 10.0.2.96 set with a MAC and sent to: still flags 0x2 after 3 s, flags 0x0 after 11 s with the MAC still listed;
 *   N. 10.0.2.95 set with a MAC and never sent to: flags 0x2 after 11 s;
 *   G. the gateway set with its own MAC and sent to: flags 0x2 and that MAC after 11 s (the unicast probe was answered);
 *   W. the gateway set with a wrong MAC and sent to: still wrong after 2 s, its real MAC back with flags 0x2 within 12 s. */
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
static int failures;
static char msg[560];
static char text[4096];
static void check(int ok, const char *w) {
    print(ok ? "hello405:   ok   " : "hello405:   FAIL ");
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
/* struct arpreq: arp_pa @0, arp_ha @16 (family, MAC @18), arp_flags @32, arp_dev[16] @52; 68 bytes. `mac` null: none given. */
static long arp(long s, unsigned long cmd, int last, int flags, const unsigned char *mac, unsigned char *r) {
    unsigned char ip[4] = { 10, 0, 2, (unsigned char)last };
    for (int i = 0; i < 68; i++) r[i] = 0;
    mk4(r, ip, 0);
    r[16] = 1;
    if (mac) for (int i = 0; i < 6; i++) r[18 + i] = mac[i];
    r[32] = (unsigned char)flags;
    for (int i = 0; DEV[i] && i < 15; i++) r[52 + i] = (unsigned char)DEV[i];
    return ioctl_(s, cmd, r);
}
static int flags_of(const unsigned char *r) { return r[32] | (r[33] << 8); }
static int mac_is(const unsigned char *r, const unsigned char *m) { for (int i = 0; i < 6; i++) if (r[18 + i] != m[i]) return 0; return 1; }
static void slurp(void) {
    long fd = open_ro("/proc/net/arp");
    if (fd < 0) { text[0] = 0; return; }
    long n = read_(fd, text, sizeof text - 1);
    close_(fd);
    text[n > 0 ? n : 0] = 0;
}
static int has_line(int last, const char *flags, const char *mac) {
    char want[160];
    char addr[16];
    snprintf(addr, sizeof addr, "10.0.2.%d", last);
    snprintf(want, sizeof want, "%-16s 0x%-10x0x%-10s%-17s     *        %s\n", addr, 1, flags, mac, DEV);
    slurp();
    return strstr(text, want) != 0;
}
static void wait_ms(int ms) { for (int i = 0; i < ms / 20; i++) pump(); }
static void kick(long s, int last) {
    unsigned char ip[4] = { 10, 0, 2, (unsigned char)last }, a[16];
    mk4(a, ip, 9);
    sendto_(s, "hello405", 8, a);
}
int main(void) {
    print("hello405: IPv4 neighbour unreachability detection\n");
    unsigned char r[68], gw[6];
    static const unsigned char m95[6] = { 2, 0, 0, 0, 0, 95 }, m96[6] = { 2, 0, 0, 0, 0, 96 }, bad[6] = { 2, 0, 0, 0, 0, 0x22 };
    long s = sock_(AF_INET, SOCK_DGRAM, 0);
    arp(s, SIOCDARP, 95, 0, 0, r);
    arp(s, SIOCDARP, 96, 0, 0, r);
    kick(s, 2);
    long g0 = -1;
    for (int i = 0; i < 50; i++) {
        g0 = arp(s, SIOCGARP, 2, 0, 0, r);
        if (g0 == 0 && flags_of(r) == ATF_COM) break;
        pump();
    }
    for (int i = 0; i < 6; i++) gw[i] = r[18 + i];
    long sn = arp(s, SIOCSARP, 95, ATF_COM, m95, r), sf = arp(s, SIOCSARP, 96, ATF_COM, m96, r), sg = arp(s, SIOCSARP, 2, ATF_COM, gw, r);
    kick(s, 96);
    kick(s, 2);
    wait_ms(3000);
    arp(s, SIOCGARP, 96, 0, 0, r);
    int f3 = flags_of(r);
    wait_ms(8000);
    long f11 = arp(s, SIOCGARP, 96, 0, 0, r);
    int ff = flags_of(r), fm = mac_is(r, m96), fl = has_line(96, "0", "02:00:00:00:00:60");
    snprintf(msg, sizeof msg, "F: gateway known %ld; set %ld; after 3 s flags 0x%x; after 11 s %ld flags 0x%x MAC kept %d line %d (0 0 0x2 0 0x0 1 1)", g0, sf, f3, f11, ff, fm, fl);
    check(g0 == 0 && sf == 0 && f3 == 2 && f11 == 0 && ff == 0 && fm && fl, msg);

    long n11 = arp(s, SIOCGARP, 95, 0, 0, r);
    int nf = flags_of(r), nm = mac_is(r, m95);
    snprintf(msg, sizeof msg, "N: set %ld, never sent to: after 11 s %ld flags 0x%x MAC %d (0 0 0x2 1)", sn, n11, nf, nm);
    check(sn == 0 && n11 == 0 && nf == 2 && nm, msg);

    long g11 = arp(s, SIOCGARP, 2, 0, 0, r);
    int gf = flags_of(r), gm = mac_is(r, gw);
    snprintf(msg, sizeof msg, "G: gateway set with its MAC %ld and sent to: after 11 s %ld flags 0x%x same MAC %d (0 0 0x2 1)", sg, g11, gf, gm);
    check(sg == 0 && g11 == 0 && gf == 2 && gm, msg);

    long sw = arp(s, SIOCSARP, 2, ATF_COM, bad, r);
    kick(s, 2);
    wait_ms(2000);
    arp(s, SIOCGARP, 2, 0, 0, r);
    int w2 = mac_is(r, bad);
    int fixed_at = -1;
    for (int t = 2; t <= 12 && fixed_at < 0; t++) {
        arp(s, SIOCGARP, 2, 0, 0, r);
        if (mac_is(r, gw) && flags_of(r) == ATF_COM) fixed_at = t;
        else {
            if (t == 10) kick(s, 2);
            wait_ms(1000);
        }
    }
    snprintf(msg, sizeof msg, "W: gateway set with a wrong MAC %ld and sent to: wrong after 2 s %d; real MAC back with flags 0x2 at %d s (0 1, 3..12)", sw, w2, fixed_at);
    check(sw == 0 && w2 && fixed_at >= 3, msg);

    arp(s, SIOCDARP, 95, 0, 0, r);
    arp(s, SIOCDARP, 96, 0, 0, r);
    close_(s);
    print(failures ? "hello405: FAIL\n" : "hello405: PASS\n");
    return failures ? 1 : 0;
}
