/* hello472: SO_MARK and SO_PRIORITY of a datagram reach the receiver (Linux: the skb keeps skb->mark and skb->priority over lo;
 * SO_RCVMARK (75) and SO_RCVPRIORITY (82) make recvmsg report them, sock_recv_mark / sock_recv_priority, after any timestamp; a
 * sendmsg SO_MARK / SO_PRIORITY control message replaces the socket's value for that datagram). Measured on the host (build with
 * -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up):
 *   A. without the options a UDP datagram brings no control message;
 *   B. SO_RCVMARK on: a plain datagram brings SOL_SOCKET / SO_MARK 0 (cmsg_len 20); with the sender's SO_MARK 9, 9; with a SO_MARK
 *      control message of 7, 7;
 *   C. SO_RCVPRIORITY on (SO_RCVMARK off): SOL_SOCKET / SO_PRIORITY 0; with the sender's SO_PRIORITY 4, 4; with a control message
 *      of 6, 6;
 *   D. getsockopt reads SO_RCVMARK 0 after it was turned off and SO_RCVPRIORITY 1; a TCP socket takes SO_RCVMARK too. */
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
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
static long sendmsg_(long s, void *m, int f) { return rc(sendmsg((int)s, m, f)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static void nap(void) { usleep(10000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static long sendmsg_(long s, void *m, int f) { return syscall3(129, s, (long)m, f); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static void nap(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello472:   ok   " : "hello472:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char a[16];
static long r, s;
/* sendmsg of one byte to `a`, with one SOL_SOCKET control message of type `ty` holding `val` (none when ty is 0). */
static long snd(int ty, int val) {
    unsigned char ctl[24];
    memset(ctl, 0, sizeof ctl);
    long len = 20;
    int lv = 1;
    memcpy(ctl, &len, 8); memcpy(ctl + 8, &lv, 4); memcpy(ctl + 12, &ty, 4); memcpy(ctl + 16, &val, 4);
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    char d = 'x';
    long iov[2] = { (long)&d, 1 };
    long np = (long)a, nl = 16, ip = (long)iov, one = 1, cp = (long)ctl, cl = ty ? 24 : 0;
    memcpy(mh, &np, 8); memcpy(mh + 8, &nl, 4); memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8);
    if (ty) { memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8); }
    long rr = sendmsg_(s, mh, 0);
    nap();
    return rr;
}
static long clen, cty, clen0, cval;
/* The next datagram: its control length, and the first message's type, cmsg_len and value. */
static long rcv(void) {
    static unsigned char ctl[128];
    memset(ctl, 0, sizeof ctl);
    char d[4];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    long iov[2] = { (long)d, 4 };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    long rr = recvmsg_(r, mh, 0x40);
    memcpy(&clen, mh + 40, 8);
    clen0 = 0; cty = -1; cval = -1;
    if (rr > 0 && clen >= 20) {
        int t, v;
        memcpy(&clen0, ctl, 8); memcpy(&t, ctl + 12, 4); memcpy(&v, ctl + 16, 4);
        cty = t; cval = v;
    }
    return rr;
}
static long seti(long fd, int o, int v) { return setopt_(fd, 1, o, &v, 4); }
int main(void) {
    print("hello472: SO_RCVMARK and SO_RCVPRIORITY\n");
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4720 >> 8; a[3] = 4720 & 0xff; a[4] = 127; a[7] = 1;
    r = sock(2, 2, 0);
    s = sock(2, 2, 0);
    long b = bind_(r, a, 16);
    snd(0, 0);
    long a1 = rcv();
    snprintf(msg, sizeof msg, "A: bind %ld; plain datagram %ld, controllen %ld (0 1 0)", b, a1, clen);
    check(b == 0 && a1 == 1 && clen == 0, msg);

    long b0 = seti(r, 75, 1);
    snd(0, 0);
    rcv();
    long m0 = cval, t0 = cty, l0 = clen0;
    seti(s, 36, 9);
    snd(0, 0);
    rcv();
    long m9 = cval;
    snd(36, 7);
    rcv();
    long m7 = cval;
    seti(s, 36, 0);
    snprintf(msg, sizeof msg, "B: SO_RCVMARK %ld; plain: type %ld len %ld mark %ld; socket mark 9: %ld; control message 7: %ld (0 36 20 0 9 7)", b0, t0, l0, m0, m9, m7);
    check(b0 == 0 && t0 == 36 && l0 == 20 && m0 == 0 && m9 == 9 && m7 == 7, msg);

    seti(r, 75, 0);
    long c0 = seti(r, 82, 1);
    snd(0, 0);
    rcv();
    long p0 = cval, pt = cty;
    seti(s, 12, 4);
    snd(0, 0);
    rcv();
    long p4 = cval;
    snd(12, 6);
    rcv();
    long p6 = cval;
    seti(s, 12, 0);
    snprintf(msg, sizeof msg, "C: SO_RCVPRIORITY %ld; plain: type %ld priority %ld; socket priority 4: %ld; control message 6: %ld (0 12 0 4 6)", c0, pt, p0, p4, p6);
    check(c0 == 0 && pt == 12 && p0 == 0 && p4 == 4 && p6 == 6, msg);

    int v = -1, l = 4;
    getopt_(r, 1, 75, &v, &l);
    int v2 = -1, l2 = 4;
    getopt_(r, 1, 82, &v2, &l2);
    long t = sock(2, 1, 0);
    long d3 = seti(t, 75, 1);
    snprintf(msg, sizeof msg, "D: SO_RCVMARK reads %d, SO_RCVPRIORITY %d; TCP SO_RCVMARK %ld (0 1 0)", v, v2, d3);
    check(v == 0 && v2 == 1 && d3 == 0, msg);

    print(failures ? "hello472: FAIL\n" : "hello472: PASS\n");
    return failures ? 1 : 0;
}
