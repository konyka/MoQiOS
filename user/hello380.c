/* hello380: a full ARP cache still learns a new neighbour (net/core/neighbour.c neigh_alloc runs neigh_forced_gc when the table is
 * over its thresholds, removing entries that were not updated recently; permanent ones stay). MoQiOS keeps 16 entries and gives the
 * slot of the ordinary entry updated longest ago to the new neighbour. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n`, with the veth setup of hello375; the device is v0 there, eth0 on MoQiOS):
 *   F. 16 ordinary entries are set with SIOCSARP, the first one is set again;
 *   G. a UDP datagram to the gateway (whose entry was removed) asks for it, and the reply is cached: SIOCGARP reports it (0x2);
 *   O. the entry set again last is still there, and at least 15 of the 16 are;
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
    print(ok ? "hello380:   ok   " : "hello380:   FAIL ");
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
static void mkreq(unsigned char *r, const unsigned char *ip, const char *dev, int flags, int hwfam, const unsigned char *mac) {
    for (int i = 0; i < 68; i++) r[i] = 0;
    mk4(r, ip, 0);
    r[16] = (unsigned char)hwfam;
    if (mac) for (int i = 0; i < 6; i++) r[18 + i] = mac[i];
    r[32] = (unsigned char)flags;
    for (int i = 0; dev[i] && i < 15; i++) r[52 + i] = (unsigned char)dev[i];
}
static long arp_set(long s, const unsigned char *ip, int flags, const unsigned char *mac) {
    unsigned char r[68]; mkreq(r, ip, DEV, flags, 1, mac); return ioctl_(s, SIOCSARP, r);
}
static long arp_get(long s, const unsigned char *ip, unsigned char *r) { mkreq(r, ip, DEV, 0, 0, 0); return ioctl_(s, SIOCGARP, r); }
static long arp_del(long s, const unsigned char *ip) { unsigned char r[68]; mkreq(r, ip, DEV, 0, 0, 0); return ioctl_(s, SIOCDARP, r); }
static int flags_of(const unsigned char *r) { return r[32] | (r[33] << 8); }
#define N 16
int main(void) {
    print("hello380: a full ARP cache still learns a new neighbour\n");
    unsigned char gw[4] = { 10, 0, 2, 2 }, ip[N][4], mac[6] = { 2, 0, 0, 0, 0, 0 }, r[68], a[16], b[8] = "ping380";
    long s = sock_(AF_INET, SOCK_DGRAM, 0);
    arp_del(s, gw);

    /* F: N ordinary entries, enough to fill MoQiOS's 16-slot cache. */
    int set_ok = 0;
    for (int i = 0; i < N; i++) {
        ip[i][0] = 10; ip[i][1] = 0; ip[i][2] = 2; ip[i][3] = (unsigned char)(100 + i);
        mac[5] = (unsigned char)(100 + i);
        if (arp_set(s, ip[i], ATF_COM, mac) == 0) set_ok++;
        pump();
    }
    mac[5] = 100;
    long f1 = arp_set(s, ip[0], ATF_COM, mac); /* refreshed: now the most recently updated */
    pump();
    snprintf(msg, sizeof msg, "F: %d of %d ordinary entries set, the first set again %ld (%d 0)", set_ok, N, f1, N);
    check(set_ok == N && f1 == 0, msg);

    /* G: traffic to the gateway asks for it; its reply must be cached although the table is full. */
    mk4(a, gw, 9);
    long g1 = sendto_(s, b, 8, a);
    long g2 = -1;
    int gf = 0;
    for (int i = 0; i < 100 && g2 != 0; i++) {
        pump();
        g2 = arp_get(s, gw, r);
        gf = flags_of(r);
    }
    snprintf(msg, sizeof msg, "G: UDP to the gateway %ld; its entry %ld flags 0x%x (8 0 0x2)", g1, g2, gf);
    check(g1 == 8 && g2 == 0 && gf == 2, msg);

    /* O: the entry that made room was not the one set again last (the least recently updated goes first). */
    long o1 = arp_get(s, ip[0], r);
    int left = 0;
    for (int i = 0; i < N; i++) if (arp_get(s, ip[i], r) == 0) left++;
    snprintf(msg, sizeof msg, "O: the refreshed entry %ld; %d of %d set entries left (0 >= %d)", o1, left, N, N - 1);
    check(o1 == 0 && left >= N - 1, msg);

    int del = 0;
    for (int i = 0; i < N; i++) if (arp_del(s, ip[i]) == 0) del++;
    snprintf(msg, sizeof msg, "D: SIOCDARP removed %d (>= %d)", del, N - 1);
    check(del >= N - 1, msg);
    close_(s);
    print(failures ? "hello380: FAIL\n" : "hello380: PASS\n");
    return failures ? 1 : 0;
}
