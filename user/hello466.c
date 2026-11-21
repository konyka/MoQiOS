/* hello466: IPv4 options on raw and ping sockets (Linux raw_sendmsg / ping_v4_sendmsg take ipc.opt from an IP_RETOPTS control
 * message or the socket's IP_OPTIONS; raw_rcv and ping_recvmsg give IP_RECVOPTS / IP_RETOPTS; icmp_reply echoes a request's options).
 * An observer raw ICMP socket with IP_RECVOPTS and IP_RETOPTS on sees each echo request and reply sent to 127.0.0.1. Measured on the
 * host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up, MTU 1500):
 *   A. a raw ICMP socket with an 11-byte record route (07 0b 04 ...): set 0, getsockopt 12 bytes; the request reaches the observer
 *      with a 32-byte header (0x48) whose options are 07 0b 0c 7f 00 00 01 7f 00 00 01 00 (sender and receiver recorded), and both
 *      control messages hold those 12 bytes; the echo reply carries the same options;
 *   B. a 12-byte timestamp (44 0c 05 00): the request arrives with the pointer at 13 and two times written, the reply with the
 *      overflow count at 1 (flags byte 0x10);
 *   C. sendmsg with an IP_RETOPTS record route (socket options cleared): the request has 07 07 08 7f 00 00 01 00; an IPPROTO_RAW
 *      (IP_HDRINCL) socket takes IP_OPTIONS (0) but its send is EINVAL;
 *   D. a ping socket: a malformed IP_OPTIONS is EINVAL; an 8-byte record route is set and read back (8 bytes); with IP_RECVOPTS its
 *      echo reply comes with 07 07 08 7f 00 00 01 00;
 *   E. record route + router alert (15 bytes) and a 3000-byte request: it leaves in fragments; the observer gets the request
 *      reassembled (3036 bytes, header 0x49, options 07 07 08 7f 00 00 01 94 04 00 00 01 01 01 00 00) and the 3028-byte reply
 *      (header 0x47, the record route only: icmp_reply does not echo a router alert).
 * The test opens net.ipv4.ping_group_range to group 0 itself and puts the old range back. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
static long sendmsg_(long s, void *m, int f) { return rc(sendmsg((int)s, m, f)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static void close_(long s) { close((int)s); }
static void nap(void) { usleep(20000); }
static long range_fd(int wr) { return rc(open("/proc/sys/net/ipv4/ping_group_range", wr ? O_WRONLY : O_RDONLY)); }
static long range_io(long fd, char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long sendmsg_(long s, void *m, int f) { return syscall3(129, s, (long)m, f); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static void close_(long s) { syscall1(11, s); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long range_fd(int wr) { return syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", wr ? 1 : 0, 0); }
static long range_io(long fd, char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
#endif
static char range_saved[48];
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
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello466:   ok   " : "hello466:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char a[16];
static unsigned char d[4096];
static unsigned char c6[40], c7[40];
static long l6, l7;
/* The next datagram on `s` without waiting (its length, or -errno), its IP_RECVOPTS / IP_RETOPTS data in c6 / c7 (l6 / l7: data
 * length, -1 when absent). */
static long next(long s) {
    static unsigned char ctl[256];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    memset(ctl, 0, sizeof ctl);
    long iov[2] = { (long)d, sizeof d };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    l6 = l7 = -1;
    long r = recvmsg_(s, mh, 0x40);
    if (r < 0) return r;
    long used;
    memcpy(&used, mh + 40, 8);
    for (long off = 0; off + 16 <= used;) {
        long len; int lv, ty;
        memcpy(&len, ctl + off, 8); memcpy(&lv, ctl + off + 8, 4); memcpy(&ty, ctl + off + 12, 4);
        if (len < 16) break;
        long n = len - 16 > 40 ? 40 : len - 16;
        if (lv == 0 && ty == 6) { l6 = n; memcpy(c6, ctl + off + 16, (unsigned long)n); }
        if (lv == 0 && ty == 7) { l7 = n; memcpy(c7, ctl + off + 16, (unsigned long)n); }
        off += (len + 7) & ~7L;
    }
    return r;
}
static int eq(const unsigned char *x, const unsigned char *y, int n) { return memcmp(x, y, (unsigned long)n) == 0; }
static void csum(unsigned char *m, int n) {
    m[2] = m[3] = 0;
    unsigned long s = 0;
    for (int i = 0; i + 1 < n; i += 2) s += (unsigned)(m[i] << 8 | m[i + 1]);
    if (n & 1) s += (unsigned)(m[n - 1] << 8);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    s = ~s & 0xffff;
    m[2] = (unsigned char)(s >> 8);
    m[3] = (unsigned char)s;
}
static unsigned char echo[8] = { 8, 0, 0, 0, 0x12, 0x34, 0, 1 };
static long seti(long s, int lv, int o, int v) { return setopt_(s, lv, o, &v, 4); }
/* A raw ICMP sender that does not queue what comes back (ICMP_FILTER blocks every type). */
static long sender(void) {
    long s = sock(2, 3, 1);
    unsigned int all = 0xffffffffu;
    setopt_(s, 255, 1, &all, 4);
    return s;
}
int main(void) {
    print("hello466: IPv4 options on raw and ping sockets\n");
    memset(a, 0, 16);
    a[0] = 2; a[4] = 127; a[7] = 1;
    long orc = open_ping_range();
    long obs = sock(2, 3, 1);
    seti(obs, 0, 6, 1);
    seti(obs, 0, 7, 1);
    csum(echo, 8);

    long s = sender();
    static const unsigned char rr11[12] = { 7, 11, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    static const unsigned char rr11_got[12] = { 7, 11, 12, 127, 0, 0, 1, 127, 0, 0, 1, 0 };
    long a1 = setopt_(s, 0, 4, rr11, 11);
    unsigned char ob[40];
    int ol = 40;
    long a2 = getopt_(s, 0, 4, ob, &ol);
    long a3 = sendto_(s, echo, 8, a, 16);
    nap();
    long a4 = next(obs);
    int a_req = a4 == 40 && d[0] == 0x48 && d[32] == 8 && eq(d + 20, rr11_got, 12) && l6 == 12 && eq(c6, rr11_got, 12) && l7 == 12 && eq(c7, rr11_got, 12);
    long a5 = next(obs);
    int a_rep = a5 == 40 && d[0] == 0x48 && d[32] == 0 && eq(d + 20, rr11_got, 12) && l6 == 12;
    snprintf(msg, sizeof msg, "setup: ping_group_range %ld, observer %ld, sender %ld (3 >=0 >=0)", orc, obs, s);
    check(orc == 3 && obs >= 0 && s >= 0, msg);
    snprintf(msg, sizeof msg, "A: raw record route set %ld get %ld len %d same %d send %ld; request %ld right %d, reply %ld right %d (0 0 12 1 8 40 1 40 1)", a1, a2, ol,
             eq(ob, rr11, 12), a3, a4, a_req, a5, a_rep);
    check(a1 == 0 && a2 == 0 && ol == 12 && eq(ob, rr11, 12) && a3 == 8 && a_req && a_rep, msg);

    static const unsigned char ts12[12] = { 0x44, 12, 5, 0 };
    long b1 = setopt_(s, 0, 4, ts12, 12);
    long b2 = sendto_(s, echo, 8, a, 16);
    nap();
    long b3 = next(obs);
    int b_req = b3 == 40 && d[20] == 0x44 && d[22] == 13 && d[23] == 0 && (d[24] | d[25] | d[26] | d[27]) && (d[28] | d[29] | d[30] | d[31]) && l6 == 12 && eq(c6, d + 20, 12);
    long b4 = next(obs);
    int b_rep = b4 == 40 && d[32] == 0 && d[20] == 0x44 && d[22] == 13 && d[23] == 0x10;
    snprintf(msg, sizeof msg, "B: raw timestamp set %ld send %ld; request %ld right %d, reply %ld overflow %02x right %d (0 8 40 1 40 10 1)", b1, b2, b3, b_req, b4, d[23], b_rep);
    check(b1 == 0 && b2 == 8 && b_req && b_rep, msg);

    static const unsigned char rr8[8] = { 7, 7, 4, 0, 0, 0, 0, 0 };
    static const unsigned char rr8_got[8] = { 7, 7, 8, 127, 0, 0, 1, 0 };
    setopt_(s, 0, 4, 0, 0);
    unsigned char ctl[24];
    memset(ctl, 0, sizeof ctl);
    long clen = 24;
    int lv = 0, ty = 7;
    memcpy(ctl, &clen, 8); memcpy(ctl + 8, &lv, 4); memcpy(ctl + 12, &ty, 4); memcpy(ctl + 16, rr8, 8);
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    long iov[2] = { (long)echo, 8 };
    long np = (long)a, nl = 16, ip = (long)iov, one = 1, cp = (long)ctl, cl = 24;
    memcpy(mh, &np, 8); memcpy(mh + 8, &nl, 4); memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    long c1 = sendmsg_(s, mh, 0);
    nap();
    long c2 = next(obs);
    int c_req = c2 == 36 && d[0] == 0x47 && d[28] == 8 && eq(d + 20, rr8_got, 8) && l6 == 8 && eq(c6, rr8_got, 8);
    next(obs);
    long h = sock(2, 3, 255);
    long c3 = setopt_(h, 0, 4, rr8, 8);
    static unsigned char pkt[28] = { 0x45, 0, 0, 28, 0, 0, 0, 0, 64, 1, 0, 0, 127, 0, 0, 1, 127, 0, 0, 1, 8, 0, 0, 0, 0, 9, 0, 1 };
    csum(pkt + 20, 8);
    long c4 = sendto_(h, pkt, 28, a, 16);
    snprintf(msg, sizeof msg, "C: raw sendmsg IP_RETOPTS %ld, request %ld right %d; IPPROTO_RAW IP_OPTIONS %ld, send %ld (8 36 1 0 -22)", c1, c2, c_req, c3, c4);
    check(c1 == 8 && c_req && c3 == 0 && c4 == -22, msg);
    close_(h);

    long p = sock(2, 2, 1);
    static const unsigned char bad[2] = { 7, 2 };
    long d1 = setopt_(p, 0, 4, bad, 2);
    long d2 = setopt_(p, 0, 4, rr8, 8);
    ol = 40;
    long d3 = getopt_(p, 0, 4, ob, &ol);
    seti(p, 0, 6, 1);
    long d4 = sendto_(p, echo, 8, a, 16);
    nap();
    long d5 = next(p);
    int d_ok = d5 == 8 && d[0] == 0 && l6 == 8 && eq(c6, rr8_got, 8);
    snprintf(msg, sizeof msg, "D: ping malformed %ld, set %ld get %ld len %d same %d, send %ld, reply %ld IP_RECVOPTS %ld right %d (-22 0 0 8 1 8 8 8 1)", d1, d2, d3, ol,
             eq(ob, rr8, 8), d4, d5, l6, d_ok);
    check(d1 == -22 && d2 == 0 && d3 == 0 && ol == 8 && eq(ob, rr8, 8) && d4 == 8 && d_ok, msg);
    while (next(obs) >= 0) {}

    static const unsigned char rr_ra[16] = { 7, 7, 4, 0, 0, 0, 0, 0x94, 4, 0, 0, 1, 1, 1, 0, 0 };
    static const unsigned char rr_ra_got[16] = { 7, 7, 8, 127, 0, 0, 1, 0x94, 4, 0, 0, 1, 1, 1, 0, 0 };
    static unsigned char big[3000];
    memset(big, 'b', sizeof big);
    memcpy(big, echo, 8);
    big[7] = 2;
    csum(big, sizeof big);
    long e1 = setopt_(s, 0, 4, rr_ra, 15);
    long e2 = sendto_(s, big, sizeof big, a, 16);
    nap();
    long e3 = next(obs);
    int e_req = e3 == 3036 && d[0] == 0x49 && d[36] == 8 && eq(d + 20, rr_ra_got, 16) && l6 == 16 && eq(c6, rr_ra_got, 16);
    long e4 = next(obs);
    int e_rep = e4 == 3028 && d[0] == 0x47 && d[28] == 0 && eq(d + 20, rr8_got, 8) && l6 == 8;
    snprintf(msg, sizeof msg, "E: raw record route + router alert set %ld, 3000 bytes sent %ld; request %ld right %d, reply %ld right %d (0 3000 3036 1 3028 1)", e1, e2, e3, e_req,
             e4, e_rep);
    check(e1 == 0 && e2 == 3000 && e_req && e_rep, msg);

    restore_ping_range();
    print(failures ? "hello466: FAIL\n" : "hello466: PASS\n");
    return failures ? 1 : 0;
}
