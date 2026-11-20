/* hello451: IPv4 fragment reassembly (Linux ip_defrag → ip_frag_queue / inet_frag_queue_insert / ip_frag_reasm). UDP datagrams to
 * 127.0.0.1:4510 are cut by hand and written through an IPPROTO_RAW socket (IP_HDRINCL); a UDP socket bound there sees what
 * reassembly makes of them. Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with
 * only lo up):
 *   A. a 3000-byte datagram in three pieces (1480 + 1480 + 48), in order, arrives whole with the right bytes;
 *   B. the same pieces last first, then first, then middle: whole;
 *   C. a piece sent twice (a duplicate) does not spoil it: whole;
 *   D. a middle piece that overlaps the first by 8 bytes discards the datagram: nothing arrives, even after the missing piece;
 *   E. two datagrams with different ids interleaved both arrive;
 *   F. pieces of one datagram never completed (the last is missing) deliver nothing;
 *   G. an unfragmented datagram after all this still arrives (nothing left over is mistaken for it). */
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
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static void nap(void) { struct timespec t = { 0, 30000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(122, s, (long)b, n, 0x40, 0, 0); }
static void nap(void) { long t[2] = { 0, 30000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[300];
static void check(int ok, const char *w) {
    print(ok ? "hello451:   ok   " : "hello451:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long rawfd, udp;
static unsigned char lo[16];
static unsigned char dgram[3008];
static unsigned char got[4096];
static unsigned short csum(const unsigned char *p, int n, unsigned int s) {
    for (int i = 0; i + 1 < n; i += 2) s += (unsigned int)(p[i] << 8 | p[i + 1]);
    if (n & 1) s += (unsigned int)(p[n - 1] << 8);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (unsigned short)~s;
}
/* A UDP datagram 127.0.0.1:4511 -> 127.0.0.1:4510 with 3000 payload bytes seeded by `seed`, into dgram (8 + 3000 bytes). */
static void build(int seed) {
    for (int i = 0; i < 3000; i++) dgram[8 + i] = (unsigned char)(i * 7 + seed);
    int ul = 3008;
    dgram[0] = 4511 >> 8; dgram[1] = 4511 & 0xff; dgram[2] = 4510 >> 8; dgram[3] = 4510 & 0xff;
    dgram[4] = (unsigned char)(ul >> 8); dgram[5] = (unsigned char)ul; dgram[6] = 0; dgram[7] = 0;
    unsigned int ps = 0x7f00 + 0x0001 + 0x7f00 + 0x0001 + 17 + (unsigned int)ul;
    unsigned short c = csum(dgram, ul, ps);
    if (c == 0) c = 0xffff;
    dgram[6] = (unsigned char)(c >> 8); dgram[7] = (unsigned char)c;
}
/* Piece [off, off+len) of dgram as an IPv4 fragment with id `id`, MF when `more`. */
static void frag(int id, int off, int len, int more) {
    unsigned char p[1600];
    memset(p, 0, 20);
    int tot = 20 + len;
    p[0] = 0x45; p[2] = (unsigned char)(tot >> 8); p[3] = (unsigned char)tot;
    p[4] = (unsigned char)(id >> 8); p[5] = (unsigned char)id;
    int fo = (off / 8) | (more ? 0x2000 : 0);
    p[6] = (unsigned char)(fo >> 8); p[7] = (unsigned char)fo;
    p[8] = 64; p[9] = 17;
    p[12] = 127; p[15] = 1; p[16] = 127; p[19] = 1;
    unsigned short c = csum(p, 20, 0);
    p[10] = (unsigned char)(c >> 8); p[11] = (unsigned char)c;
    memcpy(p + 20, dgram + off, (unsigned long)len);
    sendto_(rawfd, p, tot, lo, 16);
}
/* The next datagram on the UDP socket: its length, and whether it is dgram's payload. */
static long take(int *same) {
    nap();
    long n = recv_(udp, got, sizeof got);
    *same = n == 3000 && memcmp(got, dgram + 8, 3000) == 0;
    return n;
}
int main(void) {
    print("hello451: IPv4 fragment reassembly\n");
    memset(lo, 0, 16);
    lo[0] = 2; lo[4] = 127; lo[7] = 1;
    rawfd = sock(2, 3, 255);
    udp = sock(2, 2, 0);
    unsigned char ua[16];
    memcpy(ua, lo, 16);
    ua[2] = 4510 >> 8; ua[3] = 4510 & 0xff;
    long ub = bind_(udp, ua, 16);
    int same;

    build(1);
    frag(100, 0, 1480, 1);
    frag(100, 1480, 1480, 1);
    frag(100, 2960, 48, 0);
    long a = take(&same);
    snprintf(msg, sizeof msg, "A: raw %d bind %ld; three pieces in order: %ld bytes, same %d (3000 1)", rawfd >= 0, ub, a, same);
    check(rawfd >= 0 && ub == 0 && a == 3000 && same, msg);

    build(2);
    frag(101, 2960, 48, 0);
    frag(101, 0, 1480, 1);
    frag(101, 1480, 1480, 1);
    long b = take(&same);
    snprintf(msg, sizeof msg, "B: last, first, middle: %ld bytes, same %d (3000 1)", b, same);
    check(b == 3000 && same, msg);

    build(3);
    frag(102, 0, 1480, 1);
    frag(102, 0, 1480, 1);
    frag(102, 1480, 1480, 1);
    frag(102, 2960, 48, 0);
    long c = take(&same);
    long c2 = recv_(udp, got, sizeof got);
    snprintf(msg, sizeof msg, "C: the first piece twice: %ld bytes, same %d, then %ld (3000 1 -11)", c, same, c2);
    check(c == 3000 && same && c2 == -11, msg);

    build(4);
    frag(103, 0, 1480, 1);
    frag(103, 1472, 1480, 1);
    frag(103, 2960, 48, 0);
    frag(103, 1480, 1480, 1);
    long d = take(&same);
    snprintf(msg, sizeof msg, "D: a middle piece overlapping the first: %ld (-11)", d);
    check(d == -11, msg);

    build(5);
    frag(104, 0, 1480, 1);
    unsigned char keep[3008];
    memcpy(keep, dgram, sizeof keep);
    build(6);
    frag(105, 0, 1480, 1);
    frag(105, 1480, 1480, 1);
    memcpy(dgram, keep, sizeof keep);
    frag(104, 1480, 1480, 1);
    frag(104, 2960, 48, 0);
    long e1 = take(&same);
    int s1 = same;
    build(6);
    frag(105, 2960, 48, 0);
    long e2 = take(&same);
    snprintf(msg, sizeof msg, "E: two datagrams interleaved: %ld same %d, %ld same %d (3000 1 3000 1)", e1, s1, e2, same);
    check(e1 == 3000 && s1 && e2 == 3000 && same, msg);

    build(7);
    frag(106, 0, 1480, 1);
    frag(106, 1480, 1480, 1);
    long f = take(&same);
    snprintf(msg, sizeof msg, "F: the last piece never sent: %ld (-11)", f);
    check(f == -11, msg);

    long us = sock(2, 2, 0);
    long g1 = sendto_(us, "whole", 5, ua, 16);
    nap();
    long g = recv_(udp, got, sizeof got);
    snprintf(msg, sizeof msg, "G: an unfragmented datagram: sent %ld, got %ld \"%.5s\" (5 5 whole)", g1, g, g == 5 ? (char *)got : "");
    check(g1 == 5 && g == 5 && memcmp(got, "whole", 5) == 0, msg);

    print(failures ? "hello451: FAIL\n" : "hello451: PASS\n");
    return failures ? 1 : 0;
}
