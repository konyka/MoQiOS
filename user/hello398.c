/* hello398: MSG_PEEK on raw ICMP sockets (Linux raw_recvmsg / rawv6_recvmsg pass MSG_PEEK to skb_recv_datagram, which leaves the
 * datagram queued). Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   P. recvfrom(MSG_PEEK) gets the 28-byte copy of an echo request and its source; the next recvfrom gets the same 28 bytes again;
 *      after that the queue is empty (EAGAIN);
 *   T. a 10-byte MSG_PEEK|MSG_TRUNC recvfrom returns 28 and leaves the datagram: a plain recvfrom still gets all 28 bytes;
 *   M. recvmsg(MSG_PEEK) fills msg_name (127.0.0.1, 16) and keeps the datagram; a second recvmsg(MSG_PEEK) sees it again;
 *   O. two queued requests: a peek shows the older one, a read takes it, the next peek shows the newer one;
 *   F. the queue is first in, first out: request A and the host's reply A queue; the request is read; request B arrives; the next
 *      read gets reply A, not request B;
 *   6. on an IPv6 raw ICMPv6 socket a peek and then a read both get the 8-byte request from ::1. */
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
static long rsock4(void) { return rc(socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)); }
static long rsock6(void) { return rc(socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recvfrom_(long s, void *b, long n, int fl, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, fl, a, (socklen_t *)al)); }
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recvfrom_(long s, void *b, long n, int fl, void *a, int *al) { return syscall6(122, s, (long)b, n, fl, (long)a, (long)al); }
static long recvmsg_(long s, long *m, int fl) { return syscall3(130, s, (long)m, fl); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[700];
static void check(int ok, const char *w) {
    print(ok ? "hello398:   ok   " : "hello398:   FAIL ");
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
static unsigned char buf[200], name[32];
static int namelen;
static long rf(long s, long n, int fl) {
    memset(buf, 0, sizeof buf); memset(name, 0, sizeof name); namelen = 32;
    return recvfrom_(s, buf, n, fl | 0x40, name, &namelen);
}
static int id_at(int off) { return buf[off + 4] << 8 | buf[off + 5]; }
static void drain(long s) { while (rf(s, sizeof buf, 0) >= 0) {} }
/* Read away whatever heads the queue until an ICMP message of `type` (at `off`) does: the replies the host sends back are dropped. */
static void skip_others(long s, int off, int type) {
    for (int i = 0; i < 12; i++) {
        long n = rf(s, sizeof buf, 0x02);
        if (n < 0 || buf[off] == type) return;
        rf(s, sizeof buf, 0);
    }
}
int main(void) {
    print("hello398: MSG_PEEK on raw ICMP sockets\n");
    unsigned char lo[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
    long s = rsock4();
    drain(s);
    mk_echo(8, 0x3981);
    long sent = sendto_(s, echo, 8, lo, 16);
    nap();
    skip_others(s, 20, 8);
    long p1 = rf(s, sizeof buf, 0x02);
    int p1id = id_at(20), p1n = namelen, p1a = name[4];
    long p2 = rf(s, sizeof buf, 0);
    int p2id = id_at(20);
    skip_others(s, 20, 8);
    long p3 = rf(s, sizeof buf, 0x02);
    snprintf(msg, sizeof msg, "P: socket %ld, sent %ld (8); peek %ld (28) id 0x%x (0x3981) from %d namelen %d (16); read %ld (28) id 0x%x (0x3981); then %ld (-11)",
             s, sent, p1, p1id, p1a, p1n, p2, p2id, p3);
    check(s >= 0 && sent == 8 && p1 == 28 && p1id == 0x3981 && p1a == 127 && p1n == 16 && p2 == 28 && p2id == 0x3981 && p3 == -11, msg);
    drain(s);

    mk_echo(8, 0x3982);
    sendto_(s, echo, 8, lo, 16);
    nap();
    skip_others(s, 20, 8);
    long t1 = rf(s, 10, 0x02 | 0x20);
    long t2 = rf(s, sizeof buf, 0);
    int t2id = id_at(20);
    snprintf(msg, sizeof msg, "T: 10-byte peek with MSG_TRUNC %ld (28); then a read %ld (28) id 0x%x (0x3982)", t1, t2, t2id);
    check(t1 == 28 && t2 == 28 && t2id == 0x3982, msg);
    drain(s);

    mk_echo(8, 0x3983);
    sendto_(s, echo, 8, lo, 16);
    nap();
    skip_others(s, 20, 8);
    static unsigned char mb[100], mn[32];
    long io[2] = { (long)mb, sizeof mb };
    long m[7] = { (long)mn, 32, (long)io, 1, 0, 0, 0 };
    long m1 = recvmsg_(s, m, 0x02 | 0x40);
    int m1id = mb[24] << 8 | mb[25], m1n = (int)m[1], m1a = mn[4];
    memset(mb, 0, sizeof mb);
    m[1] = 32;
    long m2 = recvmsg_(s, m, 0x02 | 0x40);
    int m2id = mb[24] << 8 | mb[25];
    long m3 = rf(s, sizeof buf, 0);
    int m3id = id_at(20);
    snprintf(msg, sizeof msg, "M: recvmsg peek %ld (28) id 0x%x (0x3983) from %d namelen %d (16); again %ld (28) id 0x%x; read %ld (28) id 0x%x",
             m1, m1id, m1a, m1n, m2, m2id, m3, m3id);
    check(m1 == 28 && m1id == 0x3983 && m1a == 127 && m1n == 16 && m2 == 28 && m2id == 0x3983 && m3 == 28 && m3id == 0x3983, msg);
    drain(s);

    mk_echo(8, 0x3984);
    sendto_(s, echo, 8, lo, 16);
    mk_echo(8, 0x3985);
    sendto_(s, echo, 8, lo, 16);
    nap();
    skip_others(s, 20, 8);
    rf(s, sizeof buf, 0x02);
    int o1 = id_at(20);
    rf(s, sizeof buf, 0);
    int o2 = id_at(20);
    skip_others(s, 20, 8);
    rf(s, sizeof buf, 0x02);
    int o3 = id_at(20);
    snprintf(msg, sizeof msg, "O: peek id 0x%x (0x3984), read id 0x%x (0x3984), next peek id 0x%x (0x3985)", o1, o2, o3);
    check(o1 == 0x3984 && o2 == 0x3984 && o3 == 0x3985, msg);
    drain(s);

    mk_echo(8, 0x3987);
    sendto_(s, echo, 8, lo, 16);
    nap();
    long f1 = rf(s, sizeof buf, 0);
    int f1t = buf[20], f1id = id_at(20);
    mk_echo(8, 0x3988);
    sendto_(s, echo, 8, lo, 16);
    nap();
    long f2 = rf(s, sizeof buf, 0);
    int f2t = buf[20], f2id = id_at(20);
    snprintf(msg, sizeof msg, "F: first read %ld type %d (8) id 0x%x (0x3987); after request B the next read %ld type %d (0) id 0x%x (0x3987)",
             f1, f1t, f1id, f2, f2t, f2id);
    check(f1 == 28 && f1t == 8 && f1id == 0x3987 && f2 == 28 && f2t == 0 && f2id == 0x3987, msg);
    close_(s);

    unsigned char lo6[28] = { 10, 0 };
    lo6[23] = 1;
    long s6 = rsock6();
    drain(s6);
    mk_echo(128, 0x3986);
    long s6s = sendto_(s6, echo, 8, lo6, 28);
    nap();
    skip_others(s6, 0, 128);
    long q1 = rf(s6, sizeof buf, 0x02);
    int q1id = id_at(0), q1n = namelen, q1l = name[23];
    long q2 = rf(s6, sizeof buf, 0);
    int q2id = id_at(0);
    snprintf(msg, sizeof msg, "6: socket %ld, sent %ld (8); peek %ld (8) id 0x%x (0x3986) namelen %d (28) last byte %d (1); read %ld (8) id 0x%x (0x3986)",
             s6, s6s, q1, q1id, q1n, q1l, q2, q2id);
    check(s6 >= 0 && s6s == 8 && q1 == 8 && q1id == 0x3986 && q1n == 28 && q1l == 1 && q2 == 8 && q2id == 0x3986, msg);
    close_(s6);

    print(failures == 0 ? "hello398: PASS\n" : "hello398: FAIL\n");
    return failures == 0 ? 0 : 1;
}
