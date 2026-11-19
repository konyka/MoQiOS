/* hello422: the IPv6 receive control messages of a UDP socket (Linux do_ipv6_setsockopt IPV6_RECVPKTINFO / IPV6_RECVHOPLIMIT /
 * IPV6_RECVTCLASS, ip6_datagram_recv_common_ctl, ip6_datagram_recv_specific_ctl, put_cmsg). Each option is an on/off flag read back as
 * 0 or 1 and needs a full int; while it is on, recvmsg appends a control message at level SOL_IPV6 (41): IPV6_PKTINFO (50) a struct
 * in6_pktinfo (the header destination, then the arrival interface index), IPV6_HOPLIMIT (52) an int, IPV6_TCLASS (67) an int, in that
 * order. Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   V. the three options read 0 by default, 1 after setting 1 (and 5), 0 after setting 0; a 2-byte value is EINVAL;
 *   N. with none set, recvmsg returns msg_controllen 0 and msg_flags 0;
 *   P. IPV6_RECVPKTINFO on, a datagram to ::1 from a socket with IPV6_UNICAST_HOPS 33 and IPV6_TCLASS 0x28: one message of length 36
 *      (level 41, type 50), addr ::1, ifindex 1; msg_controllen 40;
 *   A. all three on: PKTINFO, then HOPLIMIT (length 20, value 33), then TCLASS (length 20, value 0x28); msg_controllen 88;
 *   T. all three on, a 48-byte control buffer: only PKTINFO fits whole, MSG_CTRUNC is set, msg_controllen 40. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static void close_(long s) { close((int)s); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recvmsg_(long s, long *m, int fl) { return rc(recvmsg((int)s, (struct msghdr *)m, fl)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void close_(long s) { syscall1(11, s); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recvmsg_(long s, long *m, int fl) { return syscall3(130, s, (long)m, fl); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
#define RECVPKTINFO 49
#define RECVHOPLIMIT 51
#define RECVTCLASS 66
static int failures;
static char msg[1200];
static void check(int ok, const char *w) {
    print(ok ? "hello422:   ok   " : "hello422:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int geti(long s, int lv, int o) { int v = -7; int l = 4; long r = getopt_(s, lv, o, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static void mk6(unsigned char *a, int port) {
    memset(a, 0, 28);
    a[0] = 10;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[23] = 1;
}
static unsigned long rd64(const unsigned char *p) { unsigned long v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static int rd32(const unsigned char *p) { return (int)(p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24); }
static unsigned char ctl[256];
static long m[7];
static long ctl_len, ctl_flags;
/* Send "ping" from `tx` to `dst` and recvmsg it on `rx` with a control buffer of `cap` bytes: the recvmsg result. */
static long roundtrip(long tx, long rx, const unsigned char *dst, long cap) {
    static char data[16];
    sendto_(tx, "ping", 4, dst, 28);
    for (int i = 0; i < 3; i++) nap();
    unsigned char name[28];
    long iov[2] = { (long)data, sizeof data };
    memset(ctl, 0xee, sizeof ctl);
    memset(m, 0, sizeof m);
    m[0] = (long)name; m[1] = 28; m[2] = (long)iov; m[3] = 1; m[4] = cap ? (long)ctl : 0; m[5] = cap;
    long r = recvmsg_(rx, m, 0x40);
    ctl_len = m[5];
    ctl_flags = (int)m[6];
    return r;
}
/* The control message at offset `off` of ctl: its length, level and type (and the next offset in *next). */
static void cm_at(long off, long *len, int *lv, int *ty, long *next) {
    *len = (long)rd64(ctl + off);
    *lv = rd32(ctl + off + 8);
    *ty = rd32(ctl + off + 12);
    *next = off + ((*len + 7) & ~7L);
    if (*len < 16 || *next > 200) *next = 200;
}
int main(void) {
    print("hello422: IPv6 UDP receive control messages\n");
    unsigned char ra[28], d1[28];
    mk6(ra, 40422);
    ra[23] = 0;
    mk6(d1, 40422);
    long rx = sock(10, 2, 0);
    long b = bind_(rx, ra, 28);
    long tx = sock(10, 2, 0);
    seti(tx, 41, 16, 33);
    seti(tx, 41, 67, 0x28);

    int o[3] = { RECVPKTINFO, RECVHOPLIMIT, RECVTCLASS };
    int d[3], one[3], five[3], zero[3];
    long sh[3];
    for (int i = 0; i < 3; i++) {
        d[i] = geti(rx, 41, o[i]);
        seti(rx, 41, o[i], 1); one[i] = geti(rx, 41, o[i]);
        seti(rx, 41, o[i], 5); five[i] = geti(rx, 41, o[i]);
        seti(rx, 41, o[i], 0); zero[i] = geti(rx, 41, o[i]);
        short v = 1;
        sh[i] = setopt(rx, 41, o[i], &v, 2);
    }
    snprintf(msg, sizeof msg, "V: bind %ld; RECVPKTINFO RECVHOPLIMIT RECVTCLASS default %d %d %d, 1 reads %d %d %d, 5 reads %d %d %d, 0 reads %d %d %d; 2 bytes %ld %ld %ld (0; 0 0 0; 1 1 1; 1 1 1; 0 0 0; -22 -22 -22)",
             b, d[0], d[1], d[2], one[0], one[1], one[2], five[0], five[1], five[2], zero[0], zero[1], zero[2], sh[0], sh[1], sh[2]);
    check(b == 0 && d[0] == 0 && d[1] == 0 && d[2] == 0 && one[0] == 1 && one[1] == 1 && one[2] == 1 && five[0] == 1 && five[1] == 1 && five[2] == 1 &&
          zero[0] == 0 && zero[1] == 0 && zero[2] == 0 && sh[0] == -22 && sh[1] == -22 && sh[2] == -22, msg);

    long nr = roundtrip(tx, rx, d1, 128);
    snprintf(msg, sizeof msg, "N: recvmsg %ld, controllen %ld, flags 0x%lx (4, 0, 0)", nr, ctl_len, ctl_flags);
    check(nr == 4 && ctl_len == 0 && ctl_flags == 0, msg);

    static const unsigned char lo6[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    seti(rx, 41, RECVPKTINFO, 1);
    long pr = roundtrip(tx, rx, d1, 128);
    long l0, n0; int lv0, ty0;
    cm_at(0, &l0, &lv0, &ty0, &n0);
    int pif = rd32(ctl + 32);
    snprintf(msg, sizeof msg, "P: recvmsg %ld, controllen %ld, flags 0x%lx; len %ld level %d type %d, addr ::1 %d, ifindex %d (4, 40, 0; 36 41 50, 1, 1)",
             pr, ctl_len, ctl_flags, l0, lv0, ty0, !memcmp(ctl + 16, lo6, 16), pif);
    check(pr == 4 && ctl_len == 40 && ctl_flags == 0 && l0 == 36 && lv0 == 41 && ty0 == 50 && !memcmp(ctl + 16, lo6, 16) && pif == 1, msg);

    seti(rx, 41, RECVHOPLIMIT, 1);
    seti(rx, 41, RECVTCLASS, 1);
    long ar = roundtrip(tx, rx, d1, 128);
    long l1, n1, l2, n2, l3, n3; int lv1, ty1, lv2, ty2, lv3, ty3;
    cm_at(0, &l1, &lv1, &ty1, &n1);
    cm_at(n1, &l2, &lv2, &ty2, &n2);
    int hl = rd32(ctl + n1 + 16);
    cm_at(n2, &l3, &lv3, &ty3, &n3);
    int tc = rd32(ctl + n2 + 16);
    snprintf(msg, sizeof msg, "A: recvmsg %ld, controllen %ld, flags 0x%lx; %ld/%d/%d, %ld/%d/%d hoplimit %d, %ld/%d/%d tclass 0x%x (4, 88, 0; 36/41/50, 20/41/52 33, 20/41/67 0x28)",
             ar, ctl_len, ctl_flags, l1, lv1, ty1, l2, lv2, ty2, hl, l3, lv3, ty3, tc);
    check(ar == 4 && ctl_len == 88 && ctl_flags == 0 && l1 == 36 && ty1 == 50 && l2 == 20 && lv2 == 41 && ty2 == 52 && hl == 33 &&
          l3 == 20 && lv3 == 41 && ty3 == 67 && tc == 0x28, msg);

    long tr = roundtrip(tx, rx, d1, 48);
    snprintf(msg, sizeof msg, "T: 48-byte buffer: recvmsg %ld, controllen %ld, flags 0x%lx, first len %ld (4, 40, 0x8, 36)", tr, ctl_len, ctl_flags, (long)rd64(ctl));
    check(tr == 4 && ctl_len == 40 && ctl_flags == 8 && rd64(ctl) == 36, msg);

    close_(tx);
    close_(rx);
    print(failures == 0 ? "hello422: PASS\n" : "hello422: FAIL\n");
    return failures == 0 ? 0 : 1;
}
