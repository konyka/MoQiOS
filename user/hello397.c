/* hello397: sendmsg and recvmsg on raw ICMP sockets (Linux raw_sendmsg / raw_recvmsg, rawv6_sendmsg / rawv6_recvmsg): the iovecs are
 * gathered into one message and a received datagram is scattered over them, msg_name carries the address both ways, and msg_flags
 * reports MSG_TRUNC. Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   S. an echo request split over two iovecs (4 + 4 bytes) sent with msg_name 127.0.0.1 returns 8;
 *   R. recvmsg over two iovecs (10 + 100 bytes) gets the 28-byte copy, IP header in the first, the rest in the second; msg_name is
 *      AF_INET 127.0.0.1 with msg_namelen 16, msg_controllen 0, msg_flags 0;
 *   T. into one 10-byte iovec: 10 and MSG_TRUNC (0x20) in msg_flags; with the MSG_TRUNC flag the call returns 28;
 *   E. MSG_DONTWAIT on an empty queue is EAGAIN; no msg_name on an unconnected socket is EDESTADDRREQ;
 *   C. after connect(127.0.0.1) a sendmsg without msg_name goes to the peer (8, and the copy comes back);
 *   6. on an IPv6 raw ICMPv6 socket sendmsg to ::1 returns 8 and recvmsg gets the 8-byte request with msg_name AF_INET6 ::1, length 28. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long rsock4(void) { return rc(socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)); }
static long rsock6(void) { return rc(socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)); }
static long connect_(long s, const void *a, int n) { return rc(connect((int)s, a, (socklen_t)n)); }
static long sendmsg_(long s, long *m, int fl) { return rc(sendmsg((int)s, (struct msghdr *)m, fl)); }
static long recvmsg_(long s, long *m, int fl) { return rc(recvmsg((int)s, (struct msghdr *)m, fl)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rsock4(void) { return syscall3(117, 2, 3, 1); }
static long rsock6(void) { return syscall3(117, 10, 3, 58); }
static long connect_(long s, const void *a, int n) { return syscall3(124, s, (long)a, n); }
static long sendmsg_(long s, long *m, int fl) { return syscall3(129, s, (long)m, fl); }
static long recvmsg_(long s, long *m, int fl) { return syscall3(130, s, (long)m, fl); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[700];
static void check(int ok, const char *w) {
    print(ok ? "hello397:   ok   " : "hello397:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char echo[8];
static void mk_echo(int type, int id) {
    for (int i = 0; i < 8; i++) echo[i] = 0;
    echo[0] = (unsigned char)type; echo[4] = (unsigned char)(id >> 8); echo[5] = (unsigned char)id; echo[7] = 1;
    unsigned int s = 0;
    for (int i = 0; i < 8; i += 2) s += (unsigned int)(echo[i] << 8 | echo[i + 1]);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    s = ~s & 0xffff;
    echo[2] = (unsigned char)(s >> 8); echo[3] = (unsigned char)s;
}
/* sendmsg of `echo` split 4 + 4 over two iovecs, to `to` (`tl` bytes) or with no msg_name. */
static long send2(long s, const void *to, int tl) {
    long io[4] = { (long)echo, 4, (long)(echo + 4), 4 };
    long m[7] = { (long)to, tl, (long)io, 2, 0, 0, 0 };
    return sendmsg_(s, m, 0);
}
static unsigned char a[10], b[100], name[32];
static long m[7];
/* recvmsg into a (`la` bytes) and b (`lb`, none when 0), with a 32-byte msg_name and a 16-byte control buffer. */
static long recv2(long s, int la, int lb, int fl) {
    static unsigned char ctl[16];
    static long io[4];
    memset(a, 0, sizeof a); memset(b, 0, sizeof b); memset(name, 0, sizeof name);
    io[0] = (long)a; io[1] = la; io[2] = (long)b; io[3] = lb;
    m[0] = (long)name; m[1] = 32; m[2] = (long)io; m[3] = lb ? 2 : 1; m[4] = (long)ctl; m[5] = 16; m[6] = 0;
    return recvmsg_(s, m, fl);
}
/* recv2 until the copy of the echo with id `id` (type `type`) arrives; the ICMP header sits `off` bytes in. */
static long recv_echo(long s, int la, int lb, int fl, int off, int type, int id) {
    for (int i = 0; i < 12; i++) {
        long n = recv2(s, la, lb, fl | 0x40);
        if (n < 0) return n;
        unsigned char all[110];
        memcpy(all, a, 10); memcpy(all + 10, b, 100);
        int at = off < la ? off : -1;
        unsigned char *p = at >= 0 ? a + off : (off >= 10 ? b + off - 10 : a);
        (void)all;
        if (p[0] == type && p[4] == (unsigned char)(id >> 8) && p[5] == (unsigned char)id) return n;
    }
    return -1;
}
static void drain(long s) { while (recv2(s, 10, 100, 0x40) >= 0) {} }
int main(void) {
    print("hello397: sendmsg and recvmsg on raw ICMP sockets\n");
    unsigned char lo[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
    long s = rsock4();
    drain(s);
    mk_echo(8, 0x3971);
    long sent = send2(s, lo, 16);
    nap();
    snprintf(msg, sizeof msg, "S: socket %ld; sendmsg over 4 + 4 bytes to 127.0.0.1: %ld (8)", s, sent);
    check(s >= 0 && sent == 8, msg);

    long n = recv_echo(s, 10, 100, 0, 20, 8, 0x3971);
    int nl = (int)m[1], fl = (int)m[6];
    snprintf(msg, sizeof msg, "R: recvmsg %ld (28): first byte 0x%02x (0x45), type %d at 20 (8); name family %d addr %d.%d.%d.%d, namelen %d (16), controllen %ld (0), flags 0x%x (0)",
             n, a[0], b[10], name[0] | name[1] << 8, name[4], name[5], name[6], name[7], nl, m[5], fl);
    check(n == 28 && a[0] == 0x45 && b[10] == 8 && name[0] == 2 && name[1] == 0 && name[4] == 127 && name[7] == 1 && nl == 16 && m[5] == 0 && fl == 0, msg);

    mk_echo(8, 0x3972);
    send2(s, lo, 16);
    nap();
    long t1 = recv2(s, 10, 0, 0x40);
    int tf = (int)m[6];
    while (recv2(s, 10, 100, 0x40) >= 0) {}
    mk_echo(8, 0x3973);
    send2(s, lo, 16);
    nap();
    long t2 = recv2(s, 10, 0, 0x40 | 0x20);
    int tf2 = (int)m[6];
    drain(s);
    snprintf(msg, sizeof msg, "T: into 10 bytes %ld (10), msg_flags 0x%x (0x20); with MSG_TRUNC %ld (28), msg_flags 0x%x (0x20)", t1, tf, t2, tf2);
    check(t1 == 10 && tf == 0x20 && t2 == 28 && tf2 == 0x20, msg);

    long e1 = recv2(s, 10, 100, 0x40);
    long e2 = send2(s, 0, 0);
    snprintf(msg, sizeof msg, "E: empty queue with MSG_DONTWAIT %ld (-11); sendmsg without msg_name unconnected %ld (-89)", e1, e2);
    check(e1 == -11 && e2 == -89, msg);

    long cc = connect_(s, lo, 16);
    mk_echo(8, 0x3974);
    long cs = send2(s, 0, 0);
    nap();
    long cr = recv_echo(s, 10, 100, 0, 20, 8, 0x3974);
    snprintf(msg, sizeof msg, "C: connect %ld; sendmsg without msg_name %ld (8); its copy came back %ld (28)", cc, cs, cr);
    check(cc == 0 && cs == 8 && cr == 28, msg);
    close_(s);

    unsigned char lo6[28] = { 10, 0 };
    lo6[23] = 1;
    long s6 = rsock6();
    drain(s6);
    mk_echo(128, 0x3975);
    long s6s = send2(s6, lo6, 28);
    nap();
    long r6 = recv_echo(s6, 10, 100, 0, 0, 128, 0x3975);
    int nl6 = (int)m[1];
    snprintf(msg, sizeof msg, "6: socket %ld; sendmsg to ::1 %ld (8); recvmsg %ld (8), name family %d, last byte %d (1), namelen %d (28)", s6, s6s, r6,
             name[0] | name[1] << 8, name[23], nl6);
    check(s6 >= 0 && s6s == 8 && r6 == 8 && name[0] == 10 && name[1] == 0 && name[23] == 1 && nl6 == 28, msg);
    close_(s6);

    print(failures == 0 ? "hello397: PASS\n" : "hello397: FAIL\n");
    return failures == 0 ? 0 : 1;
}
