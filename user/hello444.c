/* hello444: receive timestamps and the original destination (Linux net/core/sock.c __sock_set_timestamps / sock_getsockopt,
 * net/socket.c __sock_recv_timestamp, net/ipv4/ip_sockglue.c ip_cmsg_recv_dstaddr, net/ipv6/datagram.c rxorigdstaddr).
 * SO_TIMESTAMP (29) makes recvmsg bring an SCM_TIMESTAMP struct timeval at SOL_SOCKET, SO_TIMESTAMPNS (35) an SCM_TIMESTAMPNS
 * struct timespec; setting one replaces the other (getsockopt of SO_TIMESTAMP reads 0 once SO_TIMESTAMPNS is on); the stamp comes
 * before the IP messages. IP_RECVORIGDSTADDR (SOL_IP 20) brings IP_ORIGDSTADDR, a struct sockaddr_in with the destination address
 * and port; IPV6_RECVORIGDSTADDR (SOL_IPV6 74) a struct sockaddr_in6. A control buffer too small for the message cuts it
 * (MSG_CTRUNC). The kernel used to refuse all four options with ENOPROTOOPT.
 * Measured on the host (build with -DHOST, run in `unshare -n` with lo up):
 *   A. getsockopt SO_TIMESTAMP 0; set SO_TIMESTAMP and IP_RECVORIGDSTADDR -> 0, 0; they read back 1, 1; SO_TIMESTAMPNS reads 0;
 *   B. a datagram to 127.0.0.1:47441: controllen 64, first SOL_SOCKET/29 len 32 with a timeval within 2 s of gettimeofday,
 *      then SOL_IP/20 len 32: family 2, port 47441, 127.0.0.1;
 *   C. SO_TIMESTAMPNS on: SO_TIMESTAMP reads 0, SO_TIMESTAMPNS 1; the stamp is SOL_SOCKET/35 with tv_nsec < 1e9 and within 2 s;
 *   D. a 20-byte control buffer: controllen 20, MSG_CTRUNC (0x8) in msg_flags, the cut stamp message first (len 20);
 *   E. IPv6 ::1:47442 with IPV6_RECVORIGDSTADDR: reads back 1, SOL_IPV6/74 len 44, family 10, port 47442, ::1. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, n, 0, a, (socklen_t)al)); }
static long recvmsg_(long s, void *m) { return rc(recvmsg((int)s, m, 0)); }
static long now_s(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return t.tv_sec; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(44, s, (long)b, n, 0, (long)a, al); }
static long recvmsg_(long s, void *m) { return syscall3(130, s, (long)m, 0); }
static long now_s(void) { long t[2] = { 0, 0 }; syscall2(228, 0, (long)t); return t[0]; }
#endif
struct iov { void *base; unsigned long len; };
struct mhdr { void *name; unsigned int namelen; int pad0; struct iov *iov; unsigned long iovlen; void *control; unsigned long controllen; int flags; int pad1; };
static int failures;
static char msg[700];
static void check(int ok, const char *w) {
    print(ok ? "hello444:   ok   " : "hello444:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rd64(const unsigned char *p) { long v; memcpy(&v, p, 8); return v; }
static int rd32(const unsigned char *p) { int v; memcpy(&v, p, 4); return v; }
static long one_msg(long s, unsigned char *ctl, unsigned long cap, unsigned long *cl, int *fl) {
    char buf[8];
    struct iov io = { buf, sizeof buf };
    struct mhdr m;
    memset(&m, 0, sizeof m);
    m.iov = &io;
    m.iovlen = 1;
    m.control = ctl;
    m.controllen = cap;
    long r = recvmsg_(s, &m);
    *cl = m.controllen;
    *fl = m.flags;
    return r;
}
int main(void) {
    print("hello444: SO_TIMESTAMP / SO_TIMESTAMPNS and IP(V6)_RECVORIGDSTADDR control messages\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = 47441 >> 8;
    a[3] = 47441 & 0xff;
    a[4] = 127;
    a[7] = 1;
    long s = sock(2, 2, 0);
    long b = bind_(s, a, 16);
    int one = 1, v = -1, l = 4;
    long g0 = getopt_(s, 1, 29, &v, &l);
    int v0 = v;
    long s1 = setopt(s, 1, 29, &one, 4);
    long s2 = setopt(s, 0, 20, &one, 4);
    int vt = -1, vo = -1, vn = -1;
    l = 4;
    getopt_(s, 1, 29, &vt, &l);
    l = 4;
    getopt_(s, 0, 20, &vo, &l);
    l = 4;
    getopt_(s, 1, 35, &vn, &l);
    snprintf(msg, sizeof msg, "A: bind %ld, get ts %ld/%d, set ts %ld, set origdst %ld, read back %d %d, tsns %d (0, 0/0, 0, 0, 1 1, 0)", b, g0, v0, s1,
             s2, vt, vo, vn);
    check(b == 0 && g0 == 0 && v0 == 0 && s1 == 0 && s2 == 0 && vt == 1 && vo == 1 && vn == 0, msg);

    long c = sock(2, 2, 0);
    unsigned char ctl[256];
    unsigned long cl = 0;
    int fl = -1;
    long t0 = now_s();
    sendto_(c, "hi", 2, a, 16);
    long r = one_msg(s, ctl, sizeof ctl, &cl, &fl);
    long sec = rd64(ctl + 16), usec = rd64(ctl + 24);
    int port = (ctl[32 + 18] << 8) | ctl[32 + 19];
    snprintf(msg, sizeof msg, "B: recv %ld, controllen %lu, [%ld %d/%d] sec-t0 %ld usec %ld, [%ld %d/%d] family %d port %d addr %d.%d.%d.%d "
             "(2, 64, [32 1/29] 0..1 <1e6, [32 0/20] 2 47441 127.0.0.1)", r, cl, rd64(ctl), rd32(ctl + 8), rd32(ctl + 12), sec - t0, usec,
             rd64(ctl + 32), rd32(ctl + 40), rd32(ctl + 44), ctl[48], port, ctl[52], ctl[53], ctl[54], ctl[55]);
    check(r == 2 && cl == 64 && rd64(ctl) == 32 && rd32(ctl + 8) == 1 && rd32(ctl + 12) == 29 && sec - t0 >= -1 && sec - t0 <= 2 && usec >= 0 &&
              usec < 1000000 && rd64(ctl + 32) == 32 && rd32(ctl + 40) == 0 && rd32(ctl + 44) == 20 && ctl[48] == 2 && port == 47441 && ctl[52] == 127 &&
              ctl[53] == 0 && ctl[54] == 0 && ctl[55] == 1,
          msg);

    long s3 = setopt(s, 1, 35, &one, 4);
    vt = vn = -1;
    l = 4;
    getopt_(s, 1, 29, &vt, &l);
    l = 4;
    getopt_(s, 1, 35, &vn, &l);
    t0 = now_s();
    sendto_(c, "hi", 2, a, 16);
    r = one_msg(s, ctl, sizeof ctl, &cl, &fl);
    sec = rd64(ctl + 16);
    long nsec = rd64(ctl + 24);
    snprintf(msg, sizeof msg, "C: set tsns %ld, ts %d tsns %d, recv %ld, [%d/%d] sec-t0 %ld nsec %ld (0, 0 1, 2, [1/35] 0..1 <1e9)", s3, vt, vn, r,
             rd32(ctl + 8), rd32(ctl + 12), sec - t0, nsec);
    check(s3 == 0 && vt == 0 && vn == 1 && r == 2 && rd32(ctl + 8) == 1 && rd32(ctl + 12) == 35 && sec - t0 >= -1 && sec - t0 <= 2 && nsec >= 0 &&
              nsec < 1000000000,
          msg);

    sendto_(c, "hi", 2, a, 16);
    r = one_msg(s, ctl, 20, &cl, &fl);
    snprintf(msg, sizeof msg, "D: recv %ld, controllen %lu, flags 0x%x, first len %ld type %d (2, 20, 0x8, 20, 35)", r, cl, fl, rd64(ctl), rd32(ctl + 12));
    check(r == 2 && cl == 20 && fl == 8 && rd64(ctl) == 20 && rd32(ctl + 12) == 35, msg);

    unsigned char a6[28];
    memset(a6, 0, 28);
    a6[0] = 10;
    a6[2] = 47442 >> 8;
    a6[3] = 47442 & 0xff;
    a6[23] = 1;
    long s6 = sock(10, 2, 0);
    long b6 = bind_(s6, a6, 28);
    long o6 = setopt(s6, 41, 74, &one, 4);
    int v6 = -1;
    l = 4;
    getopt_(s6, 41, 74, &v6, &l);
    long c6 = sock(10, 2, 0);
    sendto_(c6, "hi", 2, a6, 28);
    r = one_msg(s6, ctl, sizeof ctl, &cl, &fl);
    int port6 = (ctl[18] << 8) | ctl[19];
    snprintf(msg, sizeof msg, "E: bind %ld, set %ld, get %d, recv %ld, [%ld %d/%d] family %d port %d last %d (0, 0, 1, 2, [44 41/74] 10 47442 1)", b6, o6,
             v6, r, rd64(ctl), rd32(ctl + 8), rd32(ctl + 12), ctl[16], port6, ctl[16 + 23]);
    check(b6 == 0 && o6 == 0 && v6 == 1 && r == 2 && rd64(ctl) == 44 && rd32(ctl + 8) == 41 && rd32(ctl + 12) == 74 && ctl[16] == 10 &&
              port6 == 47442 && ctl[16 + 23] == 1,
          msg);

    print(failures ? "hello444: FAIL\n" : "hello444: PASS\n");
    return failures ? 1 : 0;
}
