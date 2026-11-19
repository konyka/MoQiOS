/* hello445: IP_RECVERR and the error queue (Linux net/ipv4/udp.c __udp4_lib_err, ip_sockglue.c ip_icmp_error / ip_recv_error,
 * net/core/skbuff.c sock_dequeue_err_skb). With IP_RECVERR (SOL_IP 11) an ICMP error about a datagram the socket sent is queued even
 * when the socket is not connected, and becomes its pending error; recvmsg(MSG_ERRQUEUE) never blocks, returns the quoted payload,
 * msg_name the original destination, one SOL_IP/IP_RECVERR control message (struct sock_extended_err: ee_errno, ee_origin 2 ICMP,
 * ee_type, ee_code; then the ICMP sender as a sockaddr_in), and MSG_ERRQUEUE in msg_flags. Without IP_RECVERR an unconnected socket
 * hears nothing. The kernel used to refuse IP_RECVERR (ENOPROTOOPT) and had no error queue.
 * Measured on the host (build with -DHOST, run in `unshare -n` with lo up):
 *   A. IP_RECVERR reads 0, set -> 0, reads 1; recvmsg(MSG_ERRQUEUE) on the empty queue -> EAGAIN;
 *   B. sendto("hello") to 127.0.0.1:47451 (nobody there) -> 5; poll POLLERR (0x8); SO_ERROR 111;
 *   C. recvmsg(MSG_ERRQUEUE) -> 5 "hello", msg_namelen 16 (2, port 47451, 127.0.0.1), flags MSG_ERRQUEUE (0x2000), controllen 48,
 *      SOL_IP/11 len 48: errno 111, origin 2, type 3, code 3, offender family 2 127.0.0.1; then poll 0 and the queue is empty;
 *   D. a socket without IP_RECVERR, not connected: no POLLERR, the queue is empty;
 *   E. a 2-byte buffer and a 20-byte control buffer: 2, flags MSG_ERRQUEUE|MSG_TRUNC|MSG_CTRUNC (0x2028), controllen 20;
 *   F. IPv6 (IPV6_RECVERR, SOL_IPV6 25) to [::1]:47452: reads back 1; send -> 5, POLLERR, SO_ERROR 111; the error queue gives 5
 *      "hello", msg_namelen 28 (10, port 47452, ::1), flags 0x2000, controllen 64, SOL_IPV6/25 len 60: errno 111, origin 3 (ICMP6),
 *      type 1, code 4, offender family 10 ::1. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, n, 0, a, (socklen_t)al)); }
static long recvmsg_(long s, void *m, int fl) { return rc(recvmsg((int)s, m, fl)); }
static long poll1(long fd) { struct pollfd p = { (int)fd, POLLIN, 0 }; long r = poll(&p, 1, 0); return r < 0 ? -errno : p.revents; }
static void pause_ms(long ms) { struct timespec t = { 0, ms * 1000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(44, s, (long)b, n, 0, (long)a, al); }
static long recvmsg_(long s, void *m, int fl) { return syscall3(130, s, (long)m, fl); }
static long poll1(long fd) { struct { int fd; short ev, rev; } p = { (int)fd, 1, 0 }; long r = syscall3(SYS_poll, (long)&p, 1, 0); return r < 0 ? r : (unsigned short)p.rev; }
static void pause_ms(long ms) { long t[2] = { 0, ms * 1000000 }; syscall2(SYS_nanosleep, (long)t, 0); }
#endif
struct iov { void *base; unsigned long len; };
struct mhdr { void *name; unsigned int namelen; int pad0; struct iov *iov; unsigned long iovlen; void *control; unsigned long controllen; int flags; int pad1; };
static int failures;
static char msg[700];
static void check(int ok, const char *w) {
    print(ok ? "hello445:   ok   " : "hello445:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int rd32(const unsigned char *p) { int v; memcpy(&v, p, 4); return v; }
static long rd64(const unsigned char *p) { long v; memcpy(&v, p, 8); return v; }
static struct mhdr m;
static struct iov io;
static unsigned char name[32], ctl[256];
static char buf[64];
static long errq(long s, unsigned long bufcap, unsigned long ctlcap) {
    memset(&m, 0, sizeof m);
    memset(buf, 0, sizeof buf);
    memset(name, 0, sizeof name);
    memset(ctl, 0, sizeof ctl);
    io.base = buf;
    io.len = bufcap;
    m.name = name;
    m.namelen = sizeof name;
    m.iov = &io;
    m.iovlen = 1;
    m.control = ctl;
    m.controllen = ctlcap;
    return recvmsg_(s, &m, 0x2000 | 0x40);
}
int main(void) {
    print("hello445: IP_RECVERR queues ICMP errors for recvmsg(MSG_ERRQUEUE)\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = 47451 >> 8;
    a[3] = 47451 & 0xff;
    a[4] = 127;
    a[7] = 1;
    long s = sock(2, 2, 0);
    int one = 1, v = -1, l = 4;
    getopt_(s, 0, 11, &v, &l);
    int v0 = v;
    long so = setopt(s, 0, 11, &one, 4);
    l = 4;
    getopt_(s, 0, 11, &v, &l);
    long e0 = errq(s, sizeof buf, sizeof ctl);
    snprintf(msg, sizeof msg, "A: recverr %d, set %ld, reads %d, empty queue %ld (0, 0, 1, -11)", v0, so, v, e0);
    check(v0 == 0 && so == 0 && v == 1 && e0 == -11, msg);

    long r = sendto_(s, "hello", 5, a, 16);
    pause_ms(50);
    long ev = poll1(s);
    int se = -1;
    l = 4;
    getopt_(s, 1, 4, &se, &l);
    snprintf(msg, sizeof msg, "B: send %ld, poll 0x%lx, SO_ERROR %d (5, 0x8, 111)", r, ev, se);
    check(r == 5 && ev == 8 && se == 111, msg);

    long e1 = errq(s, sizeof buf, sizeof ctl);
    int port = (name[2] << 8) | name[3];
    int hello = memcmp(buf, "hello", 5) == 0;
    snprintf(msg, sizeof msg, "C: errqueue %ld hello %d, namelen %u family %d port %d addr %d.%d.%d.%d, flags 0x%x, controllen %lu, "
             "[%ld %d/%d] errno %d origin %d type %d code %d offender %d %d.%d.%d.%d (5 1, 16 2 47451 127.0.0.1, 0x2000, 48, [48 0/11] 111 2 3 3 2 127.0.0.1)",
             e1, hello, m.namelen, name[0], port, name[4], name[5], name[6], name[7], m.flags, m.controllen, rd64(ctl), rd32(ctl + 8), rd32(ctl + 12),
             rd32(ctl + 16), ctl[20], ctl[21], ctl[22], ctl[32], ctl[36], ctl[37], ctl[38], ctl[39]);
    check(e1 == 5 && hello && m.namelen == 16 && name[0] == 2 && port == 47451 && name[4] == 127 && name[7] == 1 && m.flags == 0x2000 &&
              m.controllen == 48 && rd64(ctl) == 48 && rd32(ctl + 8) == 0 && rd32(ctl + 12) == 11 && rd32(ctl + 16) == 111 && ctl[20] == 2 &&
              ctl[21] == 3 && ctl[22] == 3 && ctl[32] == 2 && ctl[36] == 127 && ctl[39] == 1,
          msg);
    long ev2 = poll1(s);
    long e2 = errq(s, sizeof buf, sizeof ctl);
    snprintf(msg, sizeof msg, "C2: poll 0x%lx, queue %ld (0, -11)", ev2, e2);
    check(ev2 == 0 && e2 == -11, msg);

    long u = sock(2, 2, 0);
    sendto_(u, "x", 1, a, 16);
    pause_ms(50);
    long ev3 = poll1(u);
    long e3 = errq(u, sizeof buf, sizeof ctl);
    snprintf(msg, sizeof msg, "D: no IP_RECVERR: poll 0x%lx, queue %ld (0, -11)", ev3, e3);
    check(ev3 == 0 && e3 == -11, msg);

    sendto_(s, "hello", 5, a, 16);
    pause_ms(50);
    long e4 = errq(s, 2, 20);
    snprintf(msg, sizeof msg, "E: small: %ld, flags 0x%x, controllen %lu (2, 0x2028, 20)", e4, m.flags, m.controllen);
    check(e4 == 2 && m.flags == 0x2028 && m.controllen == 20, msg);

    unsigned char a6[28];
    memset(a6, 0, 28);
    a6[0] = 10;
    a6[2] = 47452 >> 8;
    a6[3] = 47452 & 0xff;
    a6[23] = 1;
    long s6 = sock(10, 2, 0);
    long o6 = setopt(s6, 41, 25, &one, 4);
    v = -1;
    l = 4;
    getopt_(s6, 41, 25, &v, &l);
    long r6 = sendto_(s6, "hello", 5, a6, 28);
    pause_ms(50);
    long ev6 = poll1(s6);
    se = -1;
    l = 4;
    getopt_(s6, 1, 4, &se, &l);
    long e6 = errq(s6, sizeof buf, sizeof ctl);
    int port6 = (name[2] << 8) | name[3];
    snprintf(msg, sizeof msg, "F: set %ld get %d, send %ld, poll 0x%lx, SO_ERROR %d, errqueue %ld hello %d, namelen %u family %d port %d last %d, flags 0x%x, "
             "controllen %lu, [%ld %d/%d] errno %d origin %d type %d code %d offender %d last %d "
             "(0 1, 5, 0x8, 111, 5 1, 28 10 47452 1, 0x2000, 64, [60 41/25] 111 3 1 4 10 1)",
             o6, v, r6, ev6, se, e6, memcmp(buf, "hello", 5) == 0, m.namelen, name[0], port6, name[23], m.flags, m.controllen, rd64(ctl), rd32(ctl + 8),
             rd32(ctl + 12), rd32(ctl + 16), ctl[20], ctl[21], ctl[22], ctl[32], ctl[32 + 23]);
    check(o6 == 0 && v == 1 && r6 == 5 && ev6 == 8 && se == 111 && e6 == 5 && memcmp(buf, "hello", 5) == 0 && m.namelen == 28 && name[0] == 10 &&
              port6 == 47452 && name[23] == 1 && m.flags == 0x2000 && m.controllen == 64 && rd64(ctl) == 60 && rd32(ctl + 8) == 41 &&
              rd32(ctl + 12) == 25 && rd32(ctl + 16) == 111 && ctl[20] == 3 && ctl[21] == 1 && ctl[22] == 4 && ctl[32] == 10 && ctl[32 + 23] == 1,
          msg);

    print(failures ? "hello445: FAIL\n" : "hello445: PASS\n");
    return failures ? 1 : 0;
}
