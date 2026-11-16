/* hello378: /proc/net/arp lists the IPv4 neighbour table (net/ipv4/arp.c arp_seq_show): a fixed header, then one line per entry in
 * the format "%-16s 0x%-10x0x%-10x%-17s     *        %s\n" (address, hardware type, flags as SIOCGARP reports them, MAC, device).
 * Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n`, with the veth setup of hello375;
 * the device is v0 there, eth0 on MoQiOS):
 *   H. the file opens read-only and starts with the header line;
 *   P. after SIOCSARP 10.0.2.77 with ATF_PERM its line reads flags 0x6 and the MAC, hardware type 0x1;
 *   O. after SIOCSARP 10.0.2.78 without ATF_PERM its line reads flags 0x2;
 *   D. after SIOCDARP on both, neither line is there;
 *   W. a write to the file fails (EIO on Linux: the file has no write method; MoQiOS refuses it at open, EACCES, or at write). */
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
#define SIOCSARP 0x8955
#define ATF_COM 0x02
#define ATF_PERM 0x04
static const char header[] = "IP address       HW type     Flags       HW address            Mask     Device\n";
static int failures;
static char msg[640];
static char text[4096];
static void check(int ok, const char *w) {
    print(ok ? "hello378:   ok   " : "hello378:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void mkreq(unsigned char *r, int last, int flags, int mac_last) {
    for (int i = 0; i < 68; i++) r[i] = 0;
    r[0] = AF_INET;
    r[4] = 10; r[5] = 0; r[6] = 2; r[7] = (unsigned char)last;
    r[16] = 1;
    r[18] = 2; r[23] = (unsigned char)mac_last;
    r[32] = (unsigned char)flags;
    for (int i = 0; DEV[i]; i++) r[52 + i] = (unsigned char)DEV[i];
}
/* The whole file, read in small pieces so that a read starting mid-file is exercised too. */
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
static int has_addr(const char *ip) {
    int l = (int)strlen(ip);
    for (const char *p = text; *p; ) {
        if (memcmp(p, ip, l) == 0 && p[l] == ' ') return 1;
        while (*p && *p != '\n') p++;
        if (*p) p++;
    }
    return 0;
}
int main(void) {
    print("hello378: /proc/net/arp lists the IPv4 neighbour table\n");
    long s = sock_(AF_INET, SOCK_DGRAM, 0);
    unsigned char r[68];
    char l77[160], l78[160];
    snprintf(l77, sizeof l77, "%-16s 0x%-10x0x%-10x%-17s     *        %s\n", "10.0.2.77", 1, 6, "02:00:00:00:00:77", DEV);
    snprintf(l78, sizeof l78, "%-16s 0x%-10x0x%-10x%-17s     *        %s\n", "10.0.2.78", 1, 2, "02:00:00:00:00:78", DEV);

    long h = slurp();
    int hdr = h >= (long)sizeof header - 1 && memcmp(text, header, sizeof header - 1) == 0;
    snprintf(msg, sizeof msg, "H: read %ld bytes, header line %d (1)", h, hdr);
    check(hdr, msg);

    mkreq(r, 77, ATF_COM | ATF_PERM, 0x77);
    long p1 = ioctl_(s, SIOCSARP, r);
    mkreq(r, 78, ATF_COM, 0x78);
    long o1 = ioctl_(s, SIOCSARP, r);
    long n2 = slurp();
    int p2 = has_line(l77), o2 = has_line(l78);
    snprintf(msg, sizeof msg, "P: SIOCSARP perm %ld; line for 10.0.2.77 with flags 0x6 %d (0 1)", p1, p2);
    check(p1 == 0 && p2, msg);
    snprintf(msg, sizeof msg, "O: SIOCSARP %ld; line for 10.0.2.78 with flags 0x2 %d (0 1; read %ld)", o1, o2, n2);
    check(o1 == 0 && o2, msg);
    if (!p2 || !o2) print(text);

    mkreq(r, 77, 0, 0);
    long d1 = ioctl_(s, SIOCDARP, r);
    mkreq(r, 78, 0, 0);
    long d2 = ioctl_(s, SIOCDARP, r);
    slurp();
    int g77 = has_addr("10.0.2.77"), g78 = has_addr("10.0.2.78");
    snprintf(msg, sizeof msg, "D: SIOCDARP %ld %ld; lines left %d %d (0 0 0 0)", d1, d2, g77, g78);
    check(d1 == 0 && d2 == 0 && !g77 && !g78, msg);

    long w = open_("/proc/net/arp", 1);
    long wr = w >= 0 ? write_(w, "x", 1) : w;
    if (w >= 0) close_(w);
    snprintf(msg, sizeof msg, "W: open for writing %ld, write %ld (the write is refused)", w, wr);
    check(wr < 0, msg);
    close_(s);
    print(failures ? "hello378: FAIL\n" : "hello378: PASS\n");
    return failures ? 1 : 0;
}
