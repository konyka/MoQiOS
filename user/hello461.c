/* hello461: IPV6_DONTFRAG (Linux do_ipv6_setsockopt, ip6_datagram_send_ctl, __ip6_append_data: with dontfrag set a datagram over
 * the path MTU is EMSGSIZE instead of being fragmented). Measured on the host (build with -DHOST, run in `unshare -n` with lo up and
 * its MTU set to 1500):
 *   A. setsockopt(SOL_IPV6, IPV6_DONTFRAG, 1) on a UDP socket: 0, getsockopt reads 1; then a 3000-byte send to [::1] is EMSGSIZE;
 *      with IPV6_RECVERR on as well the refusal is queued: MSG_ERRQUEUE returns 0 with ee_errno 90, ee_origin 1 (local) and ee_info
 *      the path MTU (1500 here; an earlier test in the boot run may have lowered the path MTU to ::1, so only "at most 1500" is
 *      checked); a 1232-byte datagram (it fits the IPv6 minimum MTU of 1280) is sent;
 *   B. back to 0: 3000 bytes are sent (fragmented); a value of 2 reads back 1; a 2-byte optval sets 0;
 *   C. sendmsg with an IPV6_DONTFRAG 1 control message on a socket without the option: 3000 bytes EMSGSIZE; with 0: sent;
 *   D. a raw ICMPv6 socket with IPV6_DONTFRAG: a 3000-byte echo request is EMSGSIZE; with IPV6_RECVERR the refusal is queued too
 *      (ee_errno 90, ee_info the path MTU, at most 1500);
 *   E. an IPv4 UDP socket: SOL_IPV6 IPV6_DONTFRAG is ENOPROTOOPT; a TCP IPv6 socket takes it (0). */
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
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getint(long s, int lv, int o) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, lv, o, &v, &l)); return r < 0 ? r : v; }
static long sendmsg_(long s, void *m, int f) { return rc(sendmsg((int)s, m, f)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getint(long s, int lv, int o) { int v = -1; int l = 4; long r = syscall5(133, s, lv, o, (long)&v, (long)&l); return r < 0 ? r : v; }
static long sendmsg_(long s, void *m, int f) { return syscall3(129, s, (long)m, f); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
#endif
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello461:   ok   " : "hello461:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char out[3000];
static unsigned char in[3100];
/* struct msghdr (56 bytes) with one iovec of `n` bytes from `out`, the name `a` (28 bytes) and `ctl` as control. */
static unsigned char mh[56];
static long iov[2];
static void msghdr_(unsigned char *a, unsigned char *ctl, long ctl_len, long n) {
    memset(mh, 0, sizeof mh);
    iov[0] = (long)out; iov[1] = n;
    long p = (long)a, nl = 28, ip = (long)iov, one = 1, cp = (long)ctl;
    memcpy(mh, &p, 8); memcpy(mh + 8, &nl, 4); memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &ctl_len, 8);
}
/* One cmsghdr: len 20 (16 + an int), SOL_IPV6, IPV6_DONTFRAG, value `v`; padded to 24. */
static unsigned char ctl[24];
static void dontfrag_cmsg(int v) {
    memset(ctl, 0, sizeof ctl);
    long len = 20;
    int lv = 41, ty = 62;
    memcpy(ctl, &len, 8); memcpy(ctl + 8, &lv, 4); memcpy(ctl + 12, &ty, 4); memcpy(ctl + 16, &v, 4);
}
int main(void) {
    print("hello461: IPV6_DONTFRAG\n");
    unsigned char a[28];
    memset(a, 0, 28);
    a[0] = 10; a[2] = 4610 >> 8; a[3] = 4610 & 0xff; a[23] = 1;
    long r = sock(10, 2, 0);
    bind_(r, a, 28);
    long u = sock(10, 2, 0);
    int one = 1, zero = 0, two = 2;

    long so = setopt_(u, 41, 62, &one, 4);
    long g = getint(u, 41, 62);
    long a1 = sendto_(u, out, 3000, a, 28);
    setopt_(u, 41, 25, &one, 4);
    long a3 = sendto_(u, out, 3000, a, 28);
    unsigned char eh[56];
    memset(eh, 0, sizeof eh);
    long eiov[2] = { (long)in, 16 };
    long eip = (long)eiov, eone = 1;
    memcpy(eh + 16, &eip, 8); memcpy(eh + 24, &eone, 8);
    static unsigned char ec[128];
    long ecp = (long)ec, ecl = sizeof ec;
    memcpy(eh + 32, &ecp, 8); memcpy(eh + 40, &ecl, 8);
    long aq = recvmsg_(u, eh, 0x2000 | 0x40);
    unsigned int ee_errno, ee_info;
    memcpy(&ee_errno, ec + 16, 4);
    memcpy(&ee_info, ec + 16 + 8, 4);
    unsigned char ee_origin = ec[16 + 4];
    setopt_(u, 41, 25, &zero, 4);
    long a2 = sendto_(u, out, 1232, a, 28);
    while (recv_(r, in, sizeof in) >= 0) {}
    snprintf(msg, sizeof msg, "A: set %ld get %ld; 3000 %ld; with IPV6_RECVERR 3000 %ld, error queue %ld errno %u origin %u info %u; 1232 %ld (0 1; -90; -90 0 90 1 <=1500; 1232)", so, g,
             a1, a3, aq, ee_errno, ee_origin, ee_info, a2);
    check(so == 0 && g == 1 && a1 == -90 && a3 == -90 && aq == 0 && ee_errno == 90 && ee_origin == 1 && ee_info >= 1280 && ee_info <= 1500 && a2 == 1232, msg);

    setopt_(u, 41, 62, &zero, 4);
    long b1 = sendto_(u, out, 3000, a, 28);
    long b2 = recv_(r, in, sizeof in);
    setopt_(u, 41, 62, &two, 4);
    long b3 = getint(u, 41, 62);
    long b4 = setopt_(u, 41, 62, &one, 2);
    long b5 = getint(u, 41, 62);
    snprintf(msg, sizeof msg, "B: off: 3000 %ld, received %ld; set 2 reads %ld; a 2-byte value %ld reads %ld (3000 3000 1 0 0)", b1, b2, b3, b4, b5);
    check(b1 == 3000 && b2 == 3000 && b3 == 1 && b4 == 0 && b5 == 0, msg);

    long u2 = sock(10, 2, 0);
    dontfrag_cmsg(1);
    msghdr_(a, ctl, 24, 3000);
    long c1 = sendmsg_(u2, mh, 0);
    dontfrag_cmsg(0);
    msghdr_(a, ctl, 24, 3000);
    long c2 = sendmsg_(u2, mh, 0);
    long c3 = recv_(r, in, sizeof in);
    snprintf(msg, sizeof msg, "C: control message 1: %ld; 0: %ld, received %ld (-90 3000 3000)", c1, c2, c3);
    check(c1 == -90 && c2 == 3000 && c3 == 3000, msg);

    long raw = sock(10, 3, 58);
    setopt_(raw, 41, 62, &one, 4);
    memset(out, 0, 8);
    out[0] = 128;
    unsigned char b[28];
    memcpy(b, a, 28);
    b[2] = 0; b[3] = 0;
    long d1 = sendto_(raw, out, 3000, b, 28);
    setopt_(raw, 41, 25, &one, 4);
    long d2 = sendto_(raw, out, 3000, b, 28);
    memset(ec, 0, sizeof ec);
    memcpy(eh + 32, &ecp, 8); memcpy(eh + 40, &ecl, 8);
    long dq = recvmsg_(raw, eh, 0x2000 | 0x40);
    unsigned int de, di;
    memcpy(&de, ec + 16, 4);
    memcpy(&di, ec + 16 + 8, 4);
    snprintf(msg, sizeof msg, "D: raw ICMPv6 with IPV6_DONTFRAG, 3000 bytes: %ld; with IPV6_RECVERR %ld, error queue %ld errno %u info %u (-90 -90 0 90 <=1500)", d1, d2, dq, de, di);
    check(raw >= 0 && d1 == -90 && d2 == -90 && dq == 0 && de == 90 && di >= 1280 && di <= 1500, msg);

    long v4 = sock(2, 2, 0), t6 = sock(10, 1, 0);
    long e1 = setopt_(v4, 41, 62, &one, 4), e2 = setopt_(t6, 41, 62, &one, 4);
    snprintf(msg, sizeof msg, "E: IPv4 UDP %ld; IPv6 TCP %ld (-92 0)", e1, e2);
    check(e1 == -92 && e2 == 0, msg);

    print(failures ? "hello461: FAIL\n" : "hello461: PASS\n");
    return failures ? 1 : 0;
}
