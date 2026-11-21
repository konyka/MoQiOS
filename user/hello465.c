/* hello465: IPv4 options a UDP sender gives (Linux do_ip_setsockopt IP_OPTIONS → ip_options_get, ip_options_build; an IP_RETOPTS
 * control message on sendmsg). The receiver on 127.0.0.1:4650 has IP_RECVOPTS on. Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with lo up):
 *   A. IP_OPTIONS with a 7-byte record route (07 07 04 00 00 00 00): 0; getsockopt reads 8 bytes 07 07 04 00 00 00 00 00 (padded
 *      with END); the datagram arrives with 07 07 08 7f 00 00 01 00 (the sender recorded 127.0.0.1);
 *   B. a timestamp 44 08 05 00 ...: 0; it arrives with the pointer at 9 and the time written (the receiver found no free slot);
 *   C. malformed (07 02), a 4-byte timestamp of length 12, and 41 bytes are EINVAL; IP_OPTIONS of 0 bytes clears them (getsockopt
 *      0 bytes) and the next datagram has none;
 *   D. sendmsg with an IP_RETOPTS control message holding a record route: the datagram arrives with 07 07 08 7f 00 00 01 00; a
 *      malformed IP_RETOPTS (07 02 00 00) is EINVAL. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
static long sendmsg_(long s, void *m, int f) { return rc(sendmsg((int)s, m, f)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static void nap(void) { usleep(20000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long sendmsg_(long s, void *m, int f) { return syscall3(129, s, (long)m, f); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello465:   ok   " : "hello465:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rcv;
static unsigned char ro[40];
static long ro_len;
/* The next datagram on the receiver and its IP_RECVOPTS payload (ro_len: cmsg_len, -1 when absent). */
static long next(void) {
    nap();
    static unsigned char ctl[256];
    char d[8];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    memset(ctl, 0, sizeof ctl);
    long iov[2] = { (long)d, 8 };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    ro_len = -1;
    long r = recvmsg_(rcv, mh, 0x40);
    if (r < 0) return r;
    long used;
    memcpy(&used, mh + 40, 8);
    if (used >= 16) {
        long len; int lv, ty;
        memcpy(&len, ctl, 8); memcpy(&lv, ctl + 8, 4); memcpy(&ty, ctl + 12, 4);
        if (lv == 0 && ty == 6) { ro_len = len; memcpy(ro, ctl + 16, (unsigned long)(len - 16 > 40 ? 40 : len - 16)); }
    }
    return r;
}
static unsigned char a[16];
/* sendmsg of "x" to `a` with one IP_RETOPTS control message of `n` bytes. */
static long send_retopts(long s, const unsigned char *opt, int n) {
    unsigned char ctl[64];
    memset(ctl, 0, sizeof ctl);
    long len = 16 + n;
    int lv = 0, ty = 7;
    memcpy(ctl, &len, 8); memcpy(ctl + 8, &lv, 4); memcpy(ctl + 12, &ty, 4);
    memcpy(ctl + 16, opt, (unsigned long)n);
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    char d = 'x';
    long iov[2] = { (long)&d, 1 };
    long np = (long)a, nl = 16, ip = (long)iov, one = 1, cp = (long)ctl, cl = (16 + n + 7) & ~7;
    memcpy(mh, &np, 8); memcpy(mh + 8, &nl, 4); memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    return sendmsg_(s, mh, 0);
}
static int eq(const unsigned char *x, const unsigned char *y, int n) { return memcmp(x, y, (unsigned long)n) == 0; }
int main(void) {
    print("hello465: IPv4 options a UDP sender gives\n");
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4650 >> 8; a[3] = 4650 & 0xff; a[4] = 127; a[7] = 1;
    rcv = sock(2, 2, 0);
    bind_(rcv, a, 16);
    int one = 1;
    setopt_(rcv, 0, 6, &one, 4);
    long u = sock(2, 2, 0);

    static const unsigned char rr7[7] = { 7, 7, 4, 0, 0, 0, 0 };
    static const unsigned char rr_pad[8] = { 7, 7, 4, 0, 0, 0, 0, 0 };
    static const unsigned char rr_got[8] = { 7, 7, 8, 127, 0, 0, 1, 0 };
    long s1 = setopt_(u, 0, 4, rr7, 7);
    unsigned char ob[40];
    int ol = 40;
    long g1 = getopt_(u, 0, 4, ob, &ol);
    sendto_(u, "x", 1, a, 16);
    long r1 = next();
    snprintf(msg, sizeof msg, "A: record route set %ld; get %ld len %d same %d; received %ld IP_RECVOPTS %ld %02x %02x %02x %02x (0 0 8 1 1 24 07 07 08 7f)", s1, g1, ol, eq(ob, rr_pad, 8), r1,
             ro_len, ro[0], ro[1], ro[2], ro[3]);
    check(s1 == 0 && g1 == 0 && ol == 8 && eq(ob, rr_pad, 8) && r1 == 1 && ro_len == 24 && eq(ro, rr_got, 8), msg);

    static const unsigned char ts[8] = { 0x44, 8, 5, 0, 0, 0, 0, 0 };
    long s2 = setopt_(u, 0, 4, ts, 8);
    sendto_(u, "x", 1, a, 16);
    long r2 = next();
    int stamped = ro[4] | ro[5] | ro[6] | ro[7];
    snprintf(msg, sizeof msg, "B: timestamp set %ld; received %ld IP_RECVOPTS %ld type %02x pointer %u time written %d (0 1 24 44 9 1)", s2, r2, ro_len, ro[0], ro[2], stamped != 0);
    check(s2 == 0 && r2 == 1 && ro_len == 24 && ro[0] == 0x44 && ro[2] == 9 && stamped != 0, msg);

    static const unsigned char bad[2] = { 7, 2 };
    static const unsigned char ts12[4] = { 0x44, 12, 5, 0 };
    static unsigned char big[41];
    memset(big, 1, sizeof big);
    long c1 = setopt_(u, 0, 4, bad, 2), c2 = setopt_(u, 0, 4, ts12, 4), c3 = setopt_(u, 0, 4, big, 41);
    long c4 = setopt_(u, 0, 4, 0, 0);
    ol = 40;
    long c5 = getopt_(u, 0, 4, ob, &ol);
    sendto_(u, "x", 1, a, 16);
    long c6 = next();
    snprintf(msg, sizeof msg, "C: malformed %ld, short timestamp %ld, 41 bytes %ld; clear %ld, get %ld len %d; next datagram %ld options %ld (-22 -22 -22 0 0 0 1 -1)", c1, c2, c3, c4, c5, ol, c6,
             ro_len);
    check(c1 == -22 && c2 == -22 && c3 == -22 && c4 == 0 && c5 == 0 && ol == 0 && c6 == 1 && ro_len == -1, msg);

    long d1 = send_retopts(u, rr_pad, 8);
    long d2 = next();
    int d_ok = ro_len == 24 && eq(ro, rr_got, 8);
    static const unsigned char rbad[4] = { 7, 2, 0, 0 };
    long d3 = send_retopts(u, rbad, 4);
    snprintf(msg, sizeof msg, "D: IP_RETOPTS record route: send %ld received %ld options %ld right %d; malformed %ld (1 1 24 1 -22)", d1, d2, ro_len, d_ok, d3);
    check(d1 == 1 && d2 == 1 && d_ok && d3 == -22, msg);

    print(failures ? "hello465: FAIL\n" : "hello465: PASS\n");
    return failures ? 1 : 0;
}
