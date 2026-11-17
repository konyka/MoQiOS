/* hello396: IP_HDRINCL on a raw IPv4 socket: the caller writes the IP header (Linux raw_send_hdrinc). The kernel fills in a zero
 * source address, the total length and the header checksum, keeps the rest, and still routes by the sendto address. Measured on the
 * host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   G. IP_HDRINCL reads 0 by default, 1 once set, 0 again once cleared;
 *   U. on a UDP socket setsockopt IP_HDRINCL is ENOPROTOOPT and getsockopt reads 0;
 *   I. an echo request with its own header (source 0, total length 0, checksum 0, id 0x1234, TTL 5) to 127.0.0.1 sends 28 bytes;
 *      the copy the socket gets has TTL 5 (IP_TTL 9 on the socket does not apply), id 0x1234, source 127.0.0.1, length 28 and a
 *      valid checksum;
 *   P. a UDP datagram written whole (protocol 17, UDP checksum 0) from 127.0.0.1:4000 reaches a UDP socket bound to 127.0.0.1:P;
 *   S. 19 bytes, and a header whose IHL (15, 60 bytes) runs past a 28-byte send, are EINVAL;
 *   O. with IP_HDRINCL cleared again the buffer is an ICMP message: the copy has the kernel's header with TTL 9. */
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
static long usock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long setopt(long s, int lvl, int name, const void *v, int n) { return rc(setsockopt((int)s, lvl, name, v, (socklen_t)n)); }
static long getopt_(long s, int lvl, int name, void *v, int *n) { socklen_t l = (socklen_t)*n; long r = rc(getsockopt((int)s, lvl, name, v, &l)); *n = (int)l; return r; }
static long bind_(long s, const void *a, int n) { return rc(bind((int)s, a, (socklen_t)n)); }
static long recvfrom_(long s, void *b, int n, void *from) { socklen_t l = 16; return rc(recvfrom((int)s, b, n, MSG_DONTWAIT, from, from ? &l : 0)); }
static long sendto_(long s, const void *b, int n, const void *to, int tl) { return rc(sendto((int)s, b, n, 0, to, (socklen_t)tl)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rsock4(void) { return syscall3(117, 2, 3, 1); }
static long usock(void) { return syscall3(117, 2, 2, 0); }
static long setopt(long s, int lvl, int name, const void *v, int n) { return syscall5(132, s, lvl, name, (long)v, n); }
static long getopt_(long s, int lvl, int name, void *v, int *n) { return syscall5(133, s, lvl, name, (long)v, (long)n); }
static long bind_(long s, const void *a, int n) { return syscall3(118, s, (long)a, n); }
static long recvfrom_(long s, void *b, int n, void *from) { int l = 16; return syscall6(122, s, (long)b, n, 0x40, (long)from, from ? (long)&l : 0); }
static long sendto_(long s, const void *b, int n, const void *to, int tl) { return syscall6(121, s, (long)b, n, 0, (long)to, tl); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[700];
static unsigned char buf[2048];
static void check(int ok, const char *w) {
    print(ok ? "hello396:   ok   " : "hello396:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long seti(long s, int lvl, int name, int v) { return setopt(s, lvl, name, &v, 4); }
static long geti(long s, int lvl, int name) { int v = -1, n = 4; long r = getopt_(s, lvl, name, &v, &n); return r < 0 ? r : v; }
static unsigned int sum16(const unsigned char *p, int n) {
    unsigned int s = 0;
    for (int i = 0; i + 1 < n; i += 2) s += (unsigned int)(p[i] << 8 | p[i + 1]);
    if (n & 1) s += (unsigned int)(p[n - 1] << 8);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return s;
}
static void fill_sum(unsigned char *p, int n, int at) {
    p[at] = 0; p[at + 1] = 0;
    unsigned int s = ~sum16(p, n) & 0xffff;
    p[at] = (unsigned char)(s >> 8); p[at + 1] = (unsigned char)s;
}
static void drain(long s) { while (recvfrom_(s, buf, sizeof buf, 0) >= 0) {} }
static const unsigned char to_lo[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
/* An IPv4 header at p: protocol, TTL, id and source as given, total length and checksum left 0. */
static void iphdr(unsigned char *p, int proto, int ttl, int id, const unsigned char *src) {
    for (int i = 0; i < 20; i++) p[i] = 0;
    p[0] = 0x45; p[4] = (unsigned char)(id >> 8); p[5] = (unsigned char)id; p[8] = (unsigned char)ttl; p[9] = (unsigned char)proto;
    if (src) { p[12] = src[0]; p[13] = src[1]; p[14] = src[2]; p[15] = src[3]; }
    p[16] = 127; p[19] = 1;
}
static void echo(unsigned char *e, int id) {
    for (int i = 0; i < 8; i++) e[i] = 0;
    e[0] = 8; e[4] = (unsigned char)(id >> 8); e[5] = (unsigned char)id; e[7] = 1;
    fill_sum(e, 8, 2);
}
/* The queued copy of the echo request with id `id` (IP header included), its length, or -1. */
static long find_echo(long s, int id) {
    for (int i = 0; i < 8; i++) {
        long n = recvfrom_(s, buf, sizeof buf, 0);
        if (n < 0) return -1;
        int ihl = (buf[0] & 15) * 4;
        if (n >= ihl + 8 && buf[ihl] == 8 && buf[ihl + 4] == (unsigned char)(id >> 8) && buf[ihl + 5] == (unsigned char)id) return n;
    }
    return -1;
}
int main(void) {
    print("hello396: IP_HDRINCL lets a raw IPv4 socket write the IP header\n");
    long s = rsock4();
    long g0 = geti(s, 0, 3);
    long g1s = seti(s, 0, 3, 1);
    long g1 = geti(s, 0, 3);
    long g2s = seti(s, 0, 3, 0);
    long g2 = geti(s, 0, 3);
    snprintf(msg, sizeof msg, "G: socket %ld; IP_HDRINCL reads %ld (0), set 1 %ld reads %ld (1), set 0 %ld reads %ld (0)", s, g0, g1s, g1, g2s, g2);
    check(s >= 0 && g0 == 0 && g1s == 0 && g1 == 1 && g2s == 0 && g2 == 0, msg);

    long u = usock();
    long us = seti(u, 0, 3, 1);
    long ug = geti(u, 0, 3);
    snprintf(msg, sizeof msg, "U: on a UDP socket set %ld (-92), get %ld (0)", us, ug);
    check(us == -92 && ug == 0, msg);

    seti(s, 0, 2, 9);
    seti(s, 0, 3, 1);
    unsigned char pkt[64];
    iphdr(pkt, 1, 5, 0x1234, 0);
    echo(pkt + 20, 0x3961);
    drain(s);
    long sent = sendto_(s, pkt, 28, to_lo, 16);
    nap();
    long n = find_echo(s, 0x3961);
    int ok_sum = n >= 20 && sum16(buf, 20) == 0xffff;
    snprintf(msg, sizeof msg, "I: send %ld (28); copy %ld (28): TTL %d (5), id 0x%02x%02x (0x1234), source %d.%d.%d.%d (127.0.0.1), length %d (28), checksum ok %d",
             sent, n, n > 0 ? buf[8] : -1, buf[4], buf[5], buf[12], buf[13], buf[14], buf[15], n > 0 ? (buf[2] << 8 | buf[3]) : -1, ok_sum);
    check(sent == 28 && n == 28 && buf[8] == 5 && buf[4] == 0x12 && buf[5] == 0x34 && buf[12] == 127 && buf[15] == 1 &&
              (buf[2] << 8 | buf[3]) == 28 && ok_sum, msg);

    unsigned char ub[16] = { 2, 0, 0x9a, 0xb0, 127, 0, 0, 1 };
    long ubd = bind_(u, ub, 16);
    unsigned char src[4] = { 127, 0, 0, 1 };
    iphdr(pkt, 17, 64, 0, src);
    unsigned char *uh = pkt + 20;
    uh[0] = 0x0f; uh[1] = 0xa0; uh[2] = 0x9a; uh[3] = 0xb0; uh[4] = 0; uh[5] = 12; uh[6] = 0; uh[7] = 0;
    memcpy(uh + 8, "h396", 4);
    long us2 = sendto_(s, pkt, 32, to_lo, 16);
    nap();
    unsigned char from[16] = { 0 };
    long got = recvfrom_(u, buf, sizeof buf, from);
    snprintf(msg, sizeof msg, "P: bind %ld; send %ld (32); the UDP socket got %ld (4) \"%.4s\" from port %d (4000)", ubd, us2, got, got == 4 ? (char *)buf : "",
             from[2] << 8 | from[3]);
    check(ubd == 0 && us2 == 32 && got == 4 && memcmp(buf, "h396", 4) == 0 && (from[2] << 8 | from[3]) == 4000, msg);
    close_(u);

    long s19 = sendto_(s, pkt, 19, to_lo, 16);
    iphdr(pkt, 1, 5, 0, 0);
    pkt[0] = 0x4f;
    long sihl = sendto_(s, pkt, 28, to_lo, 16);
    snprintf(msg, sizeof msg, "S: 19 bytes %ld (-22); IHL 60 in a 28-byte send %ld (-22)", s19, sihl);
    check(s19 == -22 && sihl == -22, msg);

    seti(s, 0, 3, 0);
    unsigned char e[8];
    echo(e, 0x3962);
    drain(s);
    long so = sendto_(s, e, 8, to_lo, 16);
    nap();
    long on = find_echo(s, 0x3962);
    snprintf(msg, sizeof msg, "O: IP_HDRINCL off: send %ld (8); copy %ld (28) with the kernel's header, TTL %d (9)", so, on, on > 0 ? buf[8] : -1);
    check(so == 8 && on == 28 && buf[8] == 9, msg);
    close_(s);

    print(failures == 0 ? "hello396: PASS\n" : "hello396: FAIL\n");
    return failures == 0 ? 0 : 1;
}
