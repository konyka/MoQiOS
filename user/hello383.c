/* hello383: net.ipv4.conf.<dev>.proxy_arp (/proc/sys/net/ipv4/conf/{all,default,lo,<nic>}/proxy_arp, net/ipv4/devinet.c
 * devinet_conf_proc -> proc_dointvec; arp_req_set_proxy for SIOCSARP / SIOCDARP with ATF_PUBL and netmask 0). Measured on the host
 * (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n`, with the veth setup of hello375; the NIC is v0 there,
 * eth0 on MoQiOS):
 *   L. /proc/sys/net/ipv4 lists "conf" (a directory) next to ping_group_range; conf lists all, default, lo and the NIC (directories);
 *      a device's directory lists proxy_arp (a file); an unknown device or file is ENOENT;
 *   R. every proxy_arp reads "0\n"; a second read on the descriptor and a pread at offset 1 return 0 bytes;
 *   I. SIOCSARP ATF_PUBL|ATF_NETMASK with netmask 0 on the NIC sets its proxy_arp to 1 (all stays 0), SIOCDARP back to 0; without a
 *      device it is all; on lo it is lo;
 *   W. writes parse one int like proc_dointvec: "1\n" 2 (reads 1), "-3" 2, "x" EINVAL (unchanged), "  7  \n" 6, "7 8" 2 (7), "" 0,
 *      "99999999999" EINVAL, "0x10" 4 (16), "010" 3 (8), "12abc" EINVAL, "4\r" EINVAL, "\n\n" EINVAL, "-2147483648" 11,
 *      "2147483648" EINVAL, 21 digits EINVAL and 20 digits 20; a second write on the descriptor (offset 1) returns 1 and changes
 *      nothing; pwrite at offset 1 the same, pwrite at offset 0 writes;
 *   D. default and all are separate values: default 1 leaves lo and the NIC at 0, all 3 leaves default and the NIC alone;
 *   P. the test process (root on the host; uid 1000 with CAP_NET_ADMIN on MoQiOS) opens proxy_arp and ping_group_range for writing; a
 *      child with uid 1000 and no CAP_NET_ADMIN gets EACCES for both and still reads them (net_ctl_permissions gives a
 *      CAP_NET_ADMIN holder the owner's bits).
 * MoQiOS does not forward and has one NIC, so the switch is kept and reported and never makes it answer ARP for others. */
#ifdef HOST
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#define DEV "v0"
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock_(int d, int t, int p) { return rc(socket(d, t, p)); }
static long ioctl_(long s, unsigned long c, void *a) { return rc(ioctl((int)s, c, a)); }
static long open_(const char *p, int fl) { return rc(open(p, fl)); }
static long read_(long fd, char *b, int n) { return rc(read((int)fd, b, n)); }
static long pread_(long fd, char *b, int n, long off) { return rc(pread((int)fd, b, n, off)); }
static long write_(long fd, const char *b, int n) { return rc(write((int)fd, b, n)); }
static long pwrite_(long fd, const char *b, int n, long off) { return rc(pwrite((int)fd, b, n, off)); }
static long getdents_(long fd, char *b, int n) { return rc(syscall(217, (int)fd, b, n)); }
static void close_(long s) { close((int)s); }
static long fork_(void) { return fork(); }
static long wait_(long pid) { int st = 0; waitpid((pid_t)pid, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 255; }
static void exit_(int c) { _exit(c); }
static long drop_admin(void) { return rc(setresuid(1000, 1000, 1000)); }
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
static long pread_(long fd, char *b, int n, long off) { return syscall4(17, fd, (long)b, n, off); }
static long write_(long fd, const char *b, int n) { return syscall3(1, fd, (long)b, n); }
static long pwrite_(long fd, const char *b, int n, long off) { return syscall4(18, fd, (long)b, n, off); }
static long getdents_(long fd, char *b, int n) { return syscall3(173, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
static long fork_(void) { return syscall0(57); }
static long wait_(long pid) { int st = 0; syscall3(6, pid, (long)&st, 0); return (st >> 8) & 0xff; }
static void exit_(int c) { syscall1(2, c); }
/* capset(V3, self) with empty sets: the child keeps uid 1000 and loses CAP_NET_ADMIN. */
static long drop_admin(void) { unsigned h[2] = { 0x20080522u, 0 }; unsigned d[6] = { 0 }; return syscall2(307, (long)h, (long)d); }
#endif
#define SIOCDARP 0x8953
#define SIOCSARP 0x8955
#define ATF_PUBL 0x08
#define ATF_NETMASK 0x20
#define CONF "/proc/sys/net/ipv4/conf/"
#define NICP CONF DEV "/proxy_arp"
#define LOP CONF "lo/proxy_arp"
#define ALLP CONF "all/proxy_arp"
#define DFLP CONF "default/proxy_arp"
#define RANGE "/proc/sys/net/ipv4/ping_group_range"
static int failures;
static char msg[640];
static void check(int ok, const char *w) {
    print(ok ? "hello383:   ok   " : "hello383:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* The value a proxy_arp file reads as an int (its text must be digits and a newline), or -9999 when it does not read that way. */
static long value(const char *path) {
    char b[32];
    long fd = open_(path, O_RDONLY);
    if (fd < 0) return -9999;
    long n = read_(fd, b, sizeof b - 1);
    close_(fd);
    if (n < 2 || b[n - 1] != '\n') return -9999;
    long v = 0, i = 0, neg = 0;
    if (b[0] == '-') { neg = 1; i = 1; }
    for (; i < n - 1; i++) { if (b[i] < '0' || b[i] > '9') return -9999; v = v * 10 + (b[i] - '0'); }
    return neg ? -v : v;
}
/* One write of `text` on a fresh descriptor: what write returned. */
static long put(const char *path, const char *text) {
    long fd = open_(path, O_WRONLY);
    if (fd < 0) return fd;
    long n = write_(fd, text, (int)strlen(text));
    close_(fd);
    return n;
}
/* The d_type of `name` in directory `dir`, 0 when it is not listed, or the open error. */
static long type_in(const char *dir, const char *name) {
    char b[2048];
    long fd = open_(dir, O_RDONLY);
    if (fd < 0) return fd;
    long t = 0, n;
    while ((n = getdents_(fd, b, sizeof b)) > 0) {
        for (long off = 0; off < n;) {
            unsigned short reclen = (unsigned short)(b[off + 16] & 0xff) | (unsigned short)((b[off + 17] & 0xff) << 8);
            if (strcmp(b + off + 19, name) == 0) t = b[off + 18];
            off += reclen;
        }
    }
    close_(fd);
    return n < 0 ? n : t;
}
/* SIOCSARP / SIOCDARP with ATF_PUBL|ATF_NETMASK, netmask 0, on `dev` ("" for none). */
static long toggle(long s, unsigned long cmd, const char *dev) {
    unsigned char r[68];
    for (int i = 0; i < 68; i++) r[i] = 0;
    r[0] = AF_INET; r[4] = 10; r[6] = 2; r[7] = 90;
    r[16] = 1;
    r[32] = ATF_PUBL | ATF_NETMASK;
    r[36] = AF_INET;
    for (int i = 0; dev[i] && i < 15; i++) r[52 + i] = (unsigned char)dev[i];
    return ioctl_(s, cmd, r);
}
int main(void) {
    print("hello383: net.ipv4.conf.<dev>.proxy_arp\n");
    char b[32];

    long l1 = type_in("/proc/sys/net/ipv4", "conf"), l2 = type_in("/proc/sys/net/ipv4", "ping_group_range");
    long l3 = type_in(CONF, "all"), l4 = type_in(CONF, "default"), l5 = type_in(CONF, "lo"), l6 = type_in(CONF, DEV);
    long l7 = type_in(CONF DEV, "proxy_arp"), l8 = type_in(CONF "all/", "proxy_arp");
    long l9 = open_(CONF "nope0/proxy_arp", O_RDONLY), l10 = open_(CONF DEV "/nope", O_RDONLY);
    snprintf(msg, sizeof msg, "L: ipv4 lists conf %ld ping_group_range %ld; conf lists all %ld default %ld lo %ld " DEV " %ld; "
             DEV "/ lists proxy_arp %ld, all/ %ld; unknown device %ld, unknown file %ld (4 8 4 4 4 4 8 8 -2 -2)",
             l1, l2, l3, l4, l5, l6, l7, l8, l9, l10);
    check(l1 == 4 && l2 == 8 && l3 == 4 && l4 == 4 && l5 == 4 && l6 == 4 && l7 == 8 && l8 == 8 && l9 == -2 && l10 == -2, msg);

    long fd = open_(NICP, O_RDONLY);
    long r1 = read_(fd, b, sizeof b), r2 = read_(fd, b, sizeof b), r3 = pread_(fd, b, 8, 1);
    close_(fd);
    long ra = value(ALLP), rd = value(DFLP), rl = value(LOP), rn = value(NICP);
    snprintf(msg, sizeof msg, "R: all %ld default %ld lo %ld " DEV " %ld; reads %ld then %ld, pread at 1 %ld (0 0 0 0; 2 0 0)",
             ra, rd, rl, rn, r1, r2, r3);
    check(ra == 0 && rd == 0 && rl == 0 && rn == 0 && r1 == 2 && r2 == 0 && r3 == 0, msg);

    long s = sock_(AF_INET, SOCK_DGRAM, 0);
    long i1 = toggle(s, SIOCSARP, DEV), i2 = value(NICP), i3 = value(ALLP);
    long i4 = toggle(s, SIOCDARP, DEV), i5 = value(NICP);
    long i6 = toggle(s, SIOCSARP, ""), i7 = value(ALLP), i8 = value(NICP), i9 = value(DFLP);
    long i10 = toggle(s, SIOCDARP, ""), i11 = value(ALLP);
    long i12 = toggle(s, SIOCSARP, "lo"), i13 = value(LOP), i14 = toggle(s, SIOCDARP, "lo"), i15 = value(LOP);
    close_(s);
    snprintf(msg, sizeof msg, "I: set on " DEV " %ld -> %ld (all %ld), clear %ld -> %ld; set without device %ld -> all %ld (" DEV
             " %ld default %ld), clear %ld -> %ld; lo set %ld -> %ld, clear %ld -> %ld (0 1 0 0 0 0 1 0 0 0 0 0 1 0 0)",
             i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15);
    check(i1 == 0 && i2 == 1 && i3 == 0 && i4 == 0 && i5 == 0 && i6 == 0 && i7 == 1 && i8 == 0 && i9 == 0 && i10 == 0 && i11 == 0 &&
          i12 == 0 && i13 == 1 && i14 == 0 && i15 == 0, msg);

    long w1 = put(NICP, "1\n"), v1 = value(NICP);
    long w2 = put(NICP, "-3"), v2 = value(NICP);
    long w3 = put(NICP, "x"), v3 = value(NICP);
    long w4 = put(NICP, "  7  \n"), v4 = value(NICP);
    long w5 = put(NICP, "7 8"), w6 = put(NICP, ""), v6 = value(NICP);
    long w7 = put(NICP, "99999999999"), w8 = put(NICP, "0x10"), v8 = value(NICP);
    long w9 = put(NICP, "010"), v9 = value(NICP);
    long w10 = put(NICP, "12abc"), w11 = put(NICP, "4\r"), w12 = put(NICP, "\n\n"), v12 = value(NICP);
    snprintf(msg, sizeof msg, "W1: \"1\\n\" %ld (%ld), \"-3\" %ld (%ld), \"x\" %ld (%ld), \"  7  \\n\" %ld (%ld), \"7 8\" %ld, \"\" %ld (%ld), "
             "11 digits %ld, \"0x10\" %ld (%ld), \"010\" %ld (%ld), \"12abc\" %ld, \"4\\r\" %ld, \"\\n\\n\" %ld (%ld) "
             "(2 1, 2 -3, -22 -3, 6 7, 2, 0 7, -22, 4 16, 3 8, -22 -22 -22 8)",
             w1, v1, w2, v2, w3, v3, w4, v4, w5, w6, v6, w7, w8, v8, w9, v9, w10, w11, w12, v12);
    check(w1 == 2 && v1 == 1 && w2 == 2 && v2 == -3 && w3 == -22 && v3 == -3 && w4 == 6 && v4 == 7 && w5 == 2 && w6 == 0 && v6 == 7 &&
          w7 == -22 && w8 == 4 && v8 == 16 && w9 == 3 && v9 == 8 && w10 == -22 && w11 == -22 && w12 == -22 && v12 == 8, msg);

    long x1 = put(NICP, "-2147483648"), y1 = value(NICP);
    long x2 = put(NICP, "2147483648"), x3 = put(NICP, "000000000000000000001"), x4 = put(NICP, "00000000000000000002"), y4 = value(NICP);
    fd = open_(NICP, O_WRONLY);
    long x5 = write_(fd, "5", 1), x6 = write_(fd, "6", 1);
    close_(fd);
    long y6 = value(NICP);
    fd = open_(NICP, O_WRONLY);
    long x7 = pwrite_(fd, "3", 1, 1), y7 = value(NICP), x8 = pwrite_(fd, "4", 1, 0), y8 = value(NICP);
    close_(fd);
    snprintf(msg, sizeof msg, "W2: INT_MIN %ld (%ld), INT_MAX+1 %ld, 21 digits %ld, 20 digits %ld (%ld); writes %ld then %ld (%ld); "
             "pwrite at 1 %ld (%ld), at 0 %ld (%ld) (11 -2147483648, -22 -22 20 2; 1 1 5; 1 5 1 4)",
             x1, y1, x2, x3, x4, y4, x5, x6, y6, x7, y7, x8, y8);
    check(x1 == 11 && y1 == -2147483648L && x2 == -22 && x3 == -22 && x4 == 20 && y4 == 2 && x5 == 1 && x6 == 1 && y6 == 5 &&
          x7 == 1 && y7 == 5 && x8 == 1 && y8 == 4, msg);

    long d1 = put(DFLP, "1"), d2 = value(LOP), d3 = value(NICP), d4 = value(DFLP);
    long d5 = put(ALLP, "3"), d6 = value(DFLP), d7 = value(NICP), d8 = value(ALLP);
    snprintf(msg, sizeof msg, "D: default=1 %ld leaves lo %ld " DEV " %ld (default %ld); all=3 %ld leaves default %ld " DEV
             " %ld (all %ld) (1 0 4 1; 1 1 4 3)", d1, d2, d3, d4, d5, d6, d7, d8);
    check(d1 == 1 && d2 == 0 && d3 == 4 && d4 == 1 && d5 == 1 && d6 == 1 && d7 == 4 && d8 == 3, msg);

    long p1 = open_(NICP, O_WRONLY), p2 = open_(RANGE, O_WRONLY);
    if (p1 >= 0) close_(p1);
    if (p2 >= 0) close_(p2);
    long pid = fork_();
    if (pid == 0) {
        if (drop_admin() < 0) exit_(99);
        long a = open_(NICP, O_WRONLY), c = open_(RANGE, O_WRONLY), e = value(NICP), f = open_(RANGE, O_RDONLY);
        exit_(a == -13 && c == -13 && e == 4 && f >= 0 ? 0 : 1);
    }
    long pc = pid < 0 ? pid : wait_(pid);
    snprintf(msg, sizeof msg, "P: this process opens proxy_arp %ld and ping_group_range %ld for writing; a child without CAP_NET_ADMIN "
             "gets EACCES and still reads: %ld (>=0 >=0 0)", p1, p2, pc);
    check(p1 >= 0 && p2 >= 0 && pc == 0, msg);

    put(NICP, "0");
    put(ALLP, "0");
    put(DFLP, "0");
    put(LOP, "0");
    print(failures ? "hello383: FAIL\n" : "hello383: PASS\n");
    return failures ? 1 : 0;
}
