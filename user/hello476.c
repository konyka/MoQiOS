/* hello476: SO_RCVMARK, SO_RCVPRIORITY and SO_TIMESTAMP on raw sockets, and the mark and priority of raw and ping sends (Linux:
 * raw_recvmsg / rawv6_recvmsg call sock_recv_cmsgs; raw_sendmsg and ping_v4_sendmsg take skb->mark / skb->priority from the socket or
 * the control messages, kept over lo). Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user
 * -n` with lo up):
 *   A. a protocol-253 raw receiver with SO_RCVMARK and SO_RCVPRIORITY: a datagram from a sender with SO_MARK 9 and SO_PRIORITY 4
 *      brings SO_MARK 9, then SO_PRIORITY 4;
 *   B. an ICMP raw receiver with both: the echo request a ping socket (SO_MARK 7, SO_PRIORITY 3) sends brings 7 and 3; the echo
 *      reply the kernel sends back brings 0 and 0;
 *   C. a ping socket's own recvmsg with both options on: the reply brings no control message (ping_recvmsg does not call
 *      sock_recv_cmsgs);
 *   D. an IPv6 protocol-253 raw receiver with SO_RCVMARK: a packet from a sender with SO_MARK 5 brings 5;
 *   E. SO_TIMESTAMP on a raw receiver: SCM_TIMESTAMP (29) with a non-zero time. */
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
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static void nap(void) { usleep(10000); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static void close_(long s) { close((int)s); }
static long range_fd(int wr) { return rc(open("/proc/sys/net/ipv4/ping_group_range", wr ? O_WRONLY : O_RDONLY)); }
static long range_io(long fd, char *b, int n, int wr) { return rc(wr ? write((int)fd, b, n) : read((int)fd, b, n)); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static void nap(void) { long t[2] = { 0, 10000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static void close_(long s) { syscall1(11, s); }
static long range_fd(int wr) { return syscall3(9, (long)"/proc/sys/net/ipv4/ping_group_range", wr ? 1 : 0, 0); }
static long range_io(long fd, char *b, int n, int wr) { return syscall3(wr ? 1 : 10, fd, (long)b, n); }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello476:   ok   " : "hello476:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
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
/* What the next datagram on `r` brought: up to 4 control messages' types and first 8 bytes. */
static int n_cm, cm_ty[4];
static long cm_val[4];
static long clen;
static long rcv(long r, int icmp_type) {
    for (;;) {
        static unsigned char ctl[192], d[256];
        unsigned char mh[56];
        memset(mh, 0, sizeof mh);
        memset(ctl, 0, sizeof ctl);
        long iov[2] = { (long)d, sizeof d };
        long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
        memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
        long rr = recvmsg_(r, mh, 0x40);
        if (rr < 0) return rr;
        memcpy(&clen, mh + 40, 8);
        n_cm = 0;
        for (long off = 0; off + 16 <= clen && n_cm < 4;) {
            long len; int ty;
            memcpy(&len, ctl + off, 8); memcpy(&ty, ctl + off + 12, 4);
            if (len < 16) break;
            cm_ty[n_cm] = ty;
            cm_val[n_cm] = 0;
            memcpy(&cm_val[n_cm], ctl + off + 16, (unsigned long)(len - 16 > 8 ? 8 : len - 16));
            n_cm++;
            off += (len + 7) & ~7L;
        }
        /* An ICMP raw socket: skip what is not of the wanted type (the IP header is 20 bytes). */
        if (icmp_type < 0 || (rr > 20 && d[20] == icmp_type)) return rr;
    }
}
static long seti(long fd, int o, int v) { return setopt_(fd, 1, o, &v, 4); }
static int mp(int m, int p) { return n_cm == 2 && cm_ty[0] == 36 && (int)cm_val[0] == m && cm_ty[1] == 12 && (int)cm_val[1] == p; }
int main(void) {
    print("hello476: SO_RCVMARK / SO_RCVPRIORITY / SO_TIMESTAMP on raw sockets\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[4] = 127; a[7] = 1;
    long orc = open_ping_range();
    long r = sock(2, 3, 253), s = sock(2, 3, 253);
    seti(r, 75, 1); seti(r, 82, 1);
    seti(s, 36, 9); seti(s, 12, 4);
    sendto_(s, "x", 1, a, 16);
    nap();
    long a1 = rcv(r, -1);
    snprintf(msg, sizeof msg, "A: ping_group_range %ld; raw 253: received %ld, %d messages, mark+priority right %d (3 21 2 1)", orc, a1, n_cm, mp(9, 4));
    check(a1 == 21 && mp(9, 4), msg);

    long ri = sock(2, 3, 1);
    seti(ri, 75, 1); seti(ri, 82, 1);
    long p = sock(2, 2, 1);
    seti(p, 75, 1); seti(p, 82, 1);
    seti(p, 36, 7); seti(p, 12, 3);
    unsigned char echo[8] = { 8, 0, 0, 0, 0, 0, 0, 1 };
    sendto_(p, echo, 8, a, 16);
    nap();
    long b1 = rcv(ri, 8);
    int req_ok = mp(7, 3);
    long b2 = rcv(ri, 0);
    int rep_ok = mp(0, 0);
    snprintf(msg, sizeof msg, "B: ICMP raw: request %ld mark 7 priority 3 %d, reply %ld 0 0 %d (28 1 28 1)", b1, req_ok, b2, rep_ok);
    check(b1 == 28 && req_ok && b2 == 28 && rep_ok, msg);

    long c1 = rcv(p, -1);
    snprintf(msg, sizeof msg, "C: the ping socket's reply %ld, controllen %ld (8 0)", c1, clen);
    check(c1 == 8 && clen == 0, msg);

    unsigned char a6[28];
    memset(a6, 0, 28);
    a6[0] = 10; a6[23] = 1;
    long r6 = sock(10, 3, 253), s6 = sock(10, 3, 253);
    seti(r6, 75, 1);
    seti(s6, 36, 5);
    sendto_(s6, "y", 1, a6, 28);
    nap();
    long d1 = rcv(r6, -1);
    snprintf(msg, sizeof msg, "D: IPv6 raw: received %ld, %d messages, type %d mark %ld (1 1 36 5)", d1, n_cm, n_cm ? cm_ty[0] : -1, n_cm ? cm_val[0] : -1);
    check(d1 == 1 && n_cm == 1 && cm_ty[0] == 36 && cm_val[0] == 5, msg);

    long rt = sock(2, 3, 253);
    seti(rt, 29, 1);
    sendto_(s, "z", 1, a, 16);
    nap();
    long e1 = rcv(rt, -1);
    snprintf(msg, sizeof msg, "E: SO_TIMESTAMP raw: received %ld, type %d, time set %d (21 29 1)", e1, n_cm ? cm_ty[0] : -1, n_cm && cm_val[0] != 0);
    check(e1 == 21 && n_cm == 1 && cm_ty[0] == 29 && cm_val[0] != 0, msg);

    restore_ping_range();
    print(failures ? "hello476: FAIL\n" : "hello476: PASS\n");
    return failures ? 1 : 0;
}
