/* hello469: IP_PKTOPTIONS on TCP sockets (Linux do_ip_getsockopt IP_PKTOPTIONS: for SOCK_STREAM only, the control messages a
 * stream socket would get: IP_PKTINFO with inet_rcv_saddr and mc_index, IP_TTL with mc_ttl, IP_TOS with rcv_tos as an int;
 * tcp_v4_syn_recv_sock sets mc_index, mc_ttl and rcv_tos of an accepted socket from the SYN). Measured on the host (build with
 * -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   A. nothing asked for: 0 bytes;
 *   B. a client with IP_TOS 0x28, IP_TTL 33 and IP_PKTINFO / IP_RECVTTL / IP_RECVTOS on: before connect 80 bytes, pktinfo all
 *      zero, TTL 1, TOS 0; connected, pktinfo ifindex 0 with 127.0.0.1 twice;
 *   C. the accepted socket with the three options on: pktinfo ifindex 1 with 127.0.0.1 twice, TTL 33 and TOS 0x28 (the SYN's);
 *   D. a 40-byte buffer gets only the 32-byte IP_PKTINFO; a 16-byte one a cut 16-byte header;
 *   E. a UDP socket's IP_PKTOPTIONS and setsockopt(IP_PKTOPTIONS) are ENOPROTOOPT. */
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
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
#endif
static int failures;
static char msg[500];
static void check(int ok, const char *w) {
    print(ok ? "hello469:   ok   " : "hello469:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char po[256];
static int plen;
static long pkt(long s, int cap) {
    memset(po, 0xee, sizeof po);
    plen = cap;
    return getopt_(s, 0, 9, po, &plen);
}
/* The data of the message of type `ty` in po[0..plen], or 0. */
static unsigned char *find(int ty) {
    for (int off = 0; off + 16 <= plen;) {
        long l = 0;
        int lv = 0, t = 0;
        memcpy(&l, po + off, 8);
        memcpy(&lv, po + off + 8, 4);
        memcpy(&t, po + off + 12, 4);
        if (lv == 0 && t == ty) return po + off + 16;
        if (l < 16) break;
        off += (int)((l + 7) & ~7L);
    }
    return 0;
}
static int i32(const unsigned char *p) {
    int v;
    memcpy(&v, p, 4);
    return v;
}
static long seti(long s, int o, int v) { return setopt_(s, 0, o, &v, 4); }
static const unsigned char lo4[4] = { 127, 0, 0, 1 };
static const unsigned char zero4[4] = { 0, 0, 0, 0 };
int main(void) {
    print("hello469: IP_PKTOPTIONS on TCP sockets\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4690 >> 8; a[3] = 4690 & 0xff; a[4] = 127; a[7] = 1;
    long l = sock(2, 1, 0);
    int one = 1;
    setopt_(l, 1, 2, &one, 4);
    long b = bind_(l, a, 16), li = listen_(l, 4);
    long c = sock(2, 1, 0);
    long a1 = pkt(c, 256);
    snprintf(msg, sizeof msg, "A: bind %ld listen %ld; nothing asked for: %ld len %d (0 0 0 0)", b, li, a1, plen);
    check(b == 0 && li == 0 && a1 == 0 && plen == 0, msg);

    seti(c, 1, 0x28);
    seti(c, 2, 33);
    seti(c, 8, 1);
    seti(c, 12, 1);
    seti(c, 13, 1);
    long b1 = pkt(c, 256);
    unsigned char *pi = find(8), *tt = find(2), *ts = find(1);
    int pre = b1 == 0 && plen == 80 && pi && i32(pi) == 0 && !memcmp(pi + 4, zero4, 4) && !memcmp(pi + 8, zero4, 4) && tt && i32(tt) == 1 && ts && i32(ts) == 0;
    long cr = connect_(c, a, 16);
    long s = accept_(l);
    long b2 = pkt(c, 256);
    pi = find(8);
    int post = b2 == 0 && plen == 80 && pi && i32(pi) == 0 && !memcmp(pi + 4, lo4, 4) && !memcmp(pi + 8, lo4, 4);
    snprintf(msg, sizeof msg, "B: client before connect %ld len %d right %d; connect %ld accept %ld; after %ld len %d right %d (0 80 1 0 >=0 0 80 1)", b1, plen, pre, cr, s, b2, plen, post);
    check(pre && cr == 0 && s >= 0 && post, msg);

    seti(s, 8, 1);
    seti(s, 12, 1);
    seti(s, 13, 1);
    long c1 = pkt(s, 256);
    pi = find(8);
    tt = find(2);
    ts = find(1);
    int ok_c = c1 == 0 && plen == 80 && pi && i32(pi) == 1 && !memcmp(pi + 4, lo4, 4) && !memcmp(pi + 8, lo4, 4) && tt && i32(tt) == 33 && ts && i32(ts) == 0x28;
    snprintf(msg, sizeof msg, "C: accepted %ld len %d ifindex %d ttl %d tos %d right %d (0 80 1 33 40 1)", c1, plen, pi ? i32(pi) : -1, tt ? i32(tt) : -1, ts ? i32(ts) : -1, ok_c);
    check(ok_c, msg);

    long d1 = pkt(s, 40);
    int d1len = plen;
    long d1l = 0;
    memcpy(&d1l, po, 8);
    long d2 = pkt(s, 16);
    long d2l = 0;
    memcpy(&d2l, po, 8);
    snprintf(msg, sizeof msg, "D: 40-byte buffer %ld len %d cmsg_len %ld; 16-byte %ld len %d cmsg_len %ld (0 32 28 0 16 16)", d1, d1len, d1l, d2, plen, d2l);
    check(d1 == 0 && d1len == 32 && d1l == 28 && d2 == 0 && plen == 16 && d2l == 16, msg);

    long u = sock(2, 2, 0);
    long e1 = pkt(u, 64);
    long e2 = seti(s, 9, 1);
    snprintf(msg, sizeof msg, "E: UDP %ld, setsockopt %ld (-92 -92)", e1, e2);
    check(e1 == -92 && e2 == -92, msg);

    print(failures ? "hello469: FAIL\n" : "hello469: PASS\n");
    return failures ? 1 : 0;
}
