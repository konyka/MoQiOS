/* hello449: a UDP datagram larger than the path MTU with DF (Linux ip_append_data / __ip_append_data: `if (inet->pmtudisc >=
 * IP_PMTUDISC_DO && length > mtu) { ip_local_error(sk, EMSGSIZE, ..., mtu); return -EMSGSIZE; }`). The send fails with EMSGSIZE;
 * with IP_RECVERR the error queue gets an SO_EE_ORIGIN_LOCAL (1) entry: errno 90, ee_info = the MTU, msg_name the destination, no
 * payload, and the pending error is not set (SO_ERROR 0, no POLLERR... except the queue itself, so POLLERR is set). The kernel used
 * to copy only the first 1472 bytes of a bigger datagram and send that (sendto returned 1472).
 * Measured on the host (build with -DHOST, run in `unshare -n` with lo up and its MTU set to 1500):
 *   A. IP_MTU_DISCOVER DO, IP_RECVERR, connected to 127.0.0.1:47491: send of 1600 -> EMSGSIZE; POLLERR set; SO_ERROR 0;
 *   B. recvmsg(MSG_ERRQUEUE) -> 0 bytes, msg_namelen 16 (2, 47491, 127.0.0.1), flags MSG_ERRQUEUE, controllen 48, SOL_IP/11 with
 *      errno 90, origin 1 (LOCAL), type 0, code 0, ee_info 1500; a second read EAGAIN;
 *   C. the same send without IP_RECVERR: EMSGSIZE, nothing queued, no POLLERR;
 *   D. a datagram that fits (1472) still goes out whole (1472). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a) { return rc(bind((int)s, a, 16)); }
static long connect_(long s, const void *a) { return rc(connect((int)s, a, 16)); }
static long setopt(long s, int lv, int o, int v) { return rc(setsockopt((int)s, lv, o, &v, 4)); }
static long soerr(long s) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, 1, 4, &v, &l)); return r < 0 ? r : v; }
static long send_(long s, const void *b, long n) { return rc(send((int)s, b, n, 0)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, n, MSG_DONTWAIT)); }
static long recvmsg_(long s, void *m, int fl) { return rc(recvmsg((int)s, m, fl)); }
static long poll1(long s) { struct pollfd p = { (int)s, POLLIN, 0 }; long r = poll(&p, 1, 0); return r < 0 ? -errno : p.revents; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a) { return syscall3(118, s, (long)a, 16); }
static long connect_(long s, const void *a) { return syscall3(124, s, (long)a, 16); }
static long setopt(long s, int lv, int o, int v) { return syscall5(132, s, lv, o, (long)&v, 4); }
static long soerr(long s) { int v = -1; int l = 4; long r = syscall5(133, s, 1, 4, (long)&v, (long)&l); return r < 0 ? r : v; }
static long send_(long s, const void *b, long n) { return syscall6(121, s, (long)b, n, 0, 0, 0); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long recvmsg_(long s, void *m, int fl) { return syscall3(130, s, (long)m, fl); }
static long poll1(long s) { struct { int fd; short ev, rev; } p = { (int)s, 1, 0 }; long r = syscall3(SYS_poll, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello449:   ok   " : "hello449:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int rd32(const unsigned char *p) { int v; memcpy(&v, p, 4); return v; }
static long rd64(const unsigned char *p) { long v; memcpy(&v, p, 8); return v; }
static unsigned char big[2000], rbuf[2000];
int main(void) {
    print("hello449: an oversized UDP datagram with DF is EMSGSIZE and a local IP_RECVERR entry\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = 47491 >> 8;
    a[3] = 47491 & 0xff;
    a[4] = 127;
    a[7] = 1;
    long rx = sock(2, 2, 0);
    bind_(rx, a);
    long s = sock(2, 2, 0);
    long o1 = setopt(s, 0, 10, 2), o2 = setopt(s, 0, 11, 1), c = connect_(s, a);
    long r = send_(s, big, 1600);
    long ev = poll1(s), se = soerr(s);
    snprintf(msg, sizeof msg, "A: DO %ld RECVERR %ld connect %ld; send 1600 %ld; POLLERR %d; SO_ERROR %ld (0 0 0; -90; 1; 0)", o1, o2, c, r, (int)((ev & 8) != 0), se);
    check(o1 == 0 && o2 == 0 && c == 0 && r == -90 && (ev & 8) && se == 0, msg);

    unsigned char name[32], ctl[96];
    struct { void *b; unsigned long n; } io = { rbuf, sizeof rbuf };
    struct { void *name; unsigned int nl; int pad; void *iov; unsigned long iovlen; void *ctl; unsigned long ctllen; int flags; int pad2; } m;
    memset(&m, 0, sizeof m);
    memset(name, 0, sizeof name);
    memset(ctl, 0, sizeof ctl);
    m.name = name;
    m.nl = sizeof name;
    m.iov = &io;
    m.iovlen = 1;
    m.ctl = ctl;
    m.ctllen = sizeof ctl;
    long q = recvmsg_(s, &m, 0x2000 | 0x40);
    int port = (name[2] << 8) | name[3];
    long q2 = recvmsg_(s, &m, 0x2000 | 0x40);
    snprintf(msg, sizeof msg, "B: errqueue %ld, namelen %u family %d port %d addr %d.%d.%d.%d, flags 0x%x, controllen %lu, [%ld %d/%d] errno %d origin %d "
             "type %d code %d info %d; again %ld (0, 16 2 47491 127.0.0.1, 0x2000, 48, [48 0/11] 90 1 0 0 1500; -11)", q, m.nl, name[0], port, name[4],
             name[5], name[6], name[7], m.flags, m.ctllen, rd64(ctl), rd32(ctl + 8), rd32(ctl + 12), rd32(ctl + 16), ctl[20], ctl[21], ctl[22],
             rd32(ctl + 24), q2);
    check(q == 0 && name[0] == 2 && port == 47491 && name[4] == 127 && name[7] == 1 && rd64(ctl) == 48 && rd32(ctl + 8) == 0 &&
              rd32(ctl + 12) == 11 && rd32(ctl + 16) == 90 && ctl[20] == 1 && ctl[21] == 0 && ctl[22] == 0 && rd32(ctl + 24) == 1500 && q2 == -11,
          msg);

    long u = sock(2, 2, 0);
    setopt(u, 0, 10, 2);
    connect_(u, a);
    long ru = send_(u, big, 1600);
    long evu = poll1(u);
    memset(&m, 0, sizeof m);
    m.iov = &io;
    m.iovlen = 1;
    long qu = recvmsg_(u, &m, 0x2000 | 0x40);
    snprintf(msg, sizeof msg, "C: without IP_RECVERR send %ld, revents 0x%lx, errqueue %ld (-90, 0x0, -11)", ru, evu, qu);
    check(ru == -90 && evu == 0 && qu == -11, msg);

    while (recv_(rx, rbuf, sizeof rbuf) >= 0) {}
    long rf = send_(u, big, 1472);
    long got = recv_(rx, rbuf, sizeof rbuf);
    snprintf(msg, sizeof msg, "D: a 1472-byte datagram %ld, received %ld (1472 1472)", rf, got);
    check(rf == 1472 && got == 1472, msg);

    print(failures ? "hello449: FAIL\n" : "hello449: PASS\n");
    return failures ? 1 : 0;
}
