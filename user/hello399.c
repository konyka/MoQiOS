/* hello399: ICMP_FILTER on IPv4 raw ICMP sockets (Linux net/ipv4/raw.c raw_seticmpfilter / raw_geticmpfilter / icmp_filter: SOL_RAW
 * (255) option 1 is a 32-bit mask, a set bit blocks that ICMP type, types 32 and up always pass). Measured on the host (build with
 * -DHOST, run as root in `unshare --map-auto --map-root-user -n` with only lo up):
 *   G. a new socket reads 0 with length 4; an 8-byte buffer still reads 4 bytes; a 2-byte one reads 2 bytes of the mask; a length
 *      of 0 reads nothing and a negative one is EINVAL;
 *   B. with bit 0 (echo reply) set, an echo request to 127.0.0.1 comes back as its own copy but the host's reply does not;
 *   R. with bit 8 (echo request) set, only the reply comes back;
 *   L. a 2-byte set changes the low two bytes only; a 6-byte set takes 4;
 *   N. SOL_RAW option 2 is ENOPROTOOPT both ways, and so is ICMP_FILTER on an IPv6 raw socket; a UDP socket cannot set it (ENOPROTOOPT);
 *   H. types 32 and up are never blocked: with every bit set, an ICMP message of type 40 the socket sends to 127.0.0.1 comes back. */
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
static long usock(void) { return rc(socket(AF_INET, SOCK_DGRAM, 0)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long rsock4(void) { return syscall3(117, 2, 3, 1); }
static long rsock6(void) { return syscall3(117, 10, 3, 58); }
static long usock(void) { return syscall3(117, 2, 2, 0); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static void close_(long s) { syscall1(11, s); }
#endif
static int failures;
static char msg[700];
static void check(int ok, const char *w) {
    print(ok ? "hello399:   ok   " : "hello399:   FAIL ");
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
static unsigned char buf[200];
static const unsigned char lo[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
static void drain(long s) { while (recv_(s, buf, sizeof buf) >= 0) {} }
static long set_mask(long s, unsigned int m) { return setopt(s, 255, 1, &m, 4); }
/* Send an ICMP message of `type` with id `id` to 127.0.0.1 and report which types with that id came back: bit 0 for `type`, bit 1
 * for an echo reply. */
static int round_trip(long s, int type, int id) {
    drain(s);
    mk_echo(type, id);
    sendto_(s, echo, 8, lo, 16);
    nap();
    int seen = 0;
    for (int i = 0; i < 8; i++) {
        long n = recv_(s, buf, sizeof buf);
        if (n < 0) break;
        if (n < 28 || (buf[24] << 8 | buf[25]) != id) continue;
        if (buf[20] == type) seen |= 1;
        else if (buf[20] == 0) seen |= 2;
    }
    return seen;
}
int main(void) {
    print("hello399: ICMP_FILTER on IPv4 raw ICMP sockets\n");
    long s = rsock4();
    unsigned char v[8];
    int l = 4;
    memset(v, 0xee, sizeof v);
    long g1 = getopt_(s, 255, 1, v, &l);
    unsigned int m0 = (unsigned int)(v[0] | v[1] << 8 | v[2] << 16 | (unsigned int)v[3] << 24);
    int l1 = l;
    set_mask(s, 0x12345678u);
    l = 8;
    memset(v, 0, sizeof v);
    long g2 = getopt_(s, 255, 1, v, &l);
    int l2 = l, v4 = v[4];
    l = 2;
    memset(v, 0, sizeof v);
    long g3 = getopt_(s, 255, 1, v, &l);
    int l3 = l, b0 = v[0], b1 = v[1], b2 = v[2];
    l = 0;
    long g4 = getopt_(s, 255, 1, v, &l);
    int l4 = l;
    l = -1;
    long g5 = getopt_(s, 255, 1, v, &l);
    snprintf(msg, sizeof msg, "G: socket %ld; new mask %ld 0x%x len %d (0, 4); 8-byte read %ld len %d (4) byte 4 untouched %d (0); 2-byte read %ld len %d (2) 0x%02x%02x (0x5678) byte 2 %d (0); length 0 %ld len %d (0 0); length -1 %ld (-22)",
             s, g1, m0, l1, g2, l2, v4, g3, l3, b1, b0, b2, g4, l4, g5);
    check(s >= 0 && g1 == 0 && m0 == 0 && l1 == 4 && g2 == 0 && l2 == 4 && v4 == 0 && g3 == 0 && l3 == 2 && b0 == 0x78 && b1 == 0x56 && b2 == 0 && g4 == 0 && l4 == 0 && g5 == -22, msg);

    long sb = set_mask(s, 1u << 0);
    int seen_b = round_trip(s, 8, 0x3991);
    snprintf(msg, sizeof msg, "B: mask 1<<0 set %ld (0); came back 0x%x (request only: 0x1)", sb, seen_b);
    check(sb == 0 && seen_b == 1, msg);

    long sr = set_mask(s, 1u << 8);
    int seen_r = round_trip(s, 8, 0x3992);
    snprintf(msg, sizeof msg, "R: mask 1<<8 set %ld (0); came back 0x%x (reply only: 0x2)", sr, seen_r);
    check(sr == 0 && seen_r == 2, msg);

    set_mask(s, 0x11111111u);
    unsigned char two[2] = { 0xaa, 0xbb };
    long ls2 = setopt(s, 255, 1, two, 2);
    unsigned int got2 = 0;
    l = 4;
    getopt_(s, 255, 1, &got2, &l);
    unsigned char six[6] = { 1, 2, 3, 4, 5, 6 };
    long ls6 = setopt(s, 255, 1, six, 6);
    unsigned int got6 = 0;
    l = 4;
    getopt_(s, 255, 1, &got6, &l);
    snprintf(msg, sizeof msg, "L: 2-byte set %ld -> 0x%08x (0x1111bbaa); 6-byte set %ld -> 0x%08x (0x04030201)", ls2, got2, ls6, got6);
    check(ls2 == 0 && got2 == 0x1111bbaau && ls6 == 0 && got6 == 0x04030201u, msg);

    unsigned int z = 0;
    l = 4;
    long n1 = setopt(s, 255, 2, &z, 4);
    long n2 = getopt_(s, 255, 2, &z, &l);
    long s6 = rsock6();
    l = 4;
    long n5 = setopt(s6, 255, 1, &z, 4);
    long n6 = getopt_(s6, 255, 1, &z, &l);
    close_(s6);
    long u = usock();
    long n3 = setopt(u, 255, 1, &z, 4);
    close_(u);
    snprintf(msg, sizeof msg, "N: SOL_RAW option 2 set %ld get %ld (-92 -92); IPv6 raw socket ICMP_FILTER set %ld get %ld (-92 -92); UDP socket set %ld (-92)", n1, n2, n5, n6, n3);
    check(n1 == -92 && n2 == -92 && n5 == -92 && n6 == -92 && n3 == -92, msg);

    set_mask(s, 0xffffffffu);
    int seen_h = round_trip(s, 40, 0x3993);
    int seen_h8 = round_trip(s, 8, 0x3994);
    snprintf(msg, sizeof msg, "H: every bit set: type 40 came back 0x%x (0x1); an echo request and its reply 0x%x (0)", seen_h, seen_h8);
    check(seen_h == 1 && seen_h8 == 0, msg);
    close_(s);

    print(failures == 0 ? "hello399: PASS\n" : "hello399: FAIL\n");
    return failures == 0 ? 0 : 1;
}
