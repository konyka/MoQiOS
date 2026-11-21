/* hello471: how many reassembled datagrams a socket keeps is its SO_RCVBUF's business, and many datagrams reassemble at once (Linux
 * __udp_enqueue_schedule_skb charges skb->truesize against sk_rcvbuf; __sock_queue_rcv_skb for raw sockets; ipfrag_high_thresh 4 MiB
 * for reassembly). Measured on the host (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n`, lo MTU 1500):
 *   A. twenty 60000-byte UDP datagrams to a socket with the default SO_RCVBUF (212992): 2 are queued;
 *   B. with SO_RCVBUF 4 MiB: as many as the doubled, rmem_max-capped value read back holds at 94464 bytes each (truesize of a
 *      60000-byte datagram), at least one: 4 with rmem_max 212992 (this kernel's and a stock Linux's), all 20 with rmem_max 4 MiB;
 *      this kernel also stops at 8 queued datagrams per socket;
 *   C. a raw socket of protocol 253 with the default buffer gets 3 of twenty 60000-byte datagrams, and all of eight 1000-byte ones;
 *   D. eight UDP datagrams sent as interleaved fragments (every first piece, then every second one, through IPPROTO_RAW) all
 *      reassemble and arrive: more than the four reassembly queues this kernel used to have. */
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
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n, int f) { return rc(recv((int)s, b, (size_t)n, f)); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { socklen_t sl = (socklen_t)*l; long r = rc(getsockopt((int)s, lv, o, v, &sl)); *l = (int)sl; return r; }
static void nap(void) { usleep(50000); }
#define QUEUE_CAP 1000
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long recv_(long s, void *b, long n, int f) { return syscall6(122, s, (long)b, n, f, 0, 0); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void nap(void) { long t[2] = { 0, 50000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#define QUEUE_CAP 8
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello471:   ok   " : "hello471:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static char b[65536];
static int drain(long s) {
    nap();
    int n = 0;
    while (recv_(s, b, sizeof b, 0x40) > 0) n++;
    return n;
}
static unsigned char a[16];
static void port(int p) { a[2] = (unsigned char)(p >> 8); a[3] = (unsigned char)p; }
static unsigned short ck(const unsigned char *h, int n) {
    unsigned long s = 0;
    for (int i = 0; i < n; i += 2) s += (unsigned)(h[i] << 8 | h[i + 1]);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (unsigned short)~s;
}
/* One fragment of UDP datagram `id` (2000 bytes of payload) to 127.0.0.1:4712: the first 1480 bytes, or the 528 after them. */
static long frag(long raw, int id, int second) {
    static unsigned char p[1600];
    memset(p, 0, sizeof p);
    int off = second ? 1480 : 0, n = second ? 528 : 1480, tot = 20 + n;
    p[0] = 0x45; p[2] = (unsigned char)(tot >> 8); p[3] = (unsigned char)tot;
    p[4] = (unsigned char)(id >> 8); p[5] = (unsigned char)id;
    int fo = (off / 8) | (second ? 0 : 0x2000);
    p[6] = (unsigned char)(fo >> 8); p[7] = (unsigned char)fo;
    p[8] = 64; p[9] = 17; p[12] = 127; p[15] = 1; p[16] = 127; p[19] = 1;
    if (!second) { p[20] = 0x12; p[21] = 0x34; p[22] = 4712 >> 8; p[23] = 4712 & 0xff; p[24] = 2008 >> 8; p[25] = 2008 & 0xff; }
    unsigned short c = ck(p, 20);
    p[10] = (unsigned char)(c >> 8); p[11] = (unsigned char)c;
    return sendto_(raw, p, tot, a, 16);
}
int main(void) {
    print("hello471: SO_RCVBUF bounds reassembled datagrams; many reassemble at once\n");
    memset(a, 0, 16);
    a[0] = 2; a[4] = 127; a[7] = 1;
    long r = sock(2, 2, 0), s = sock(2, 2, 0);
    port(4710);
    long br = bind_(r, a, 16);
    for (int i = 0; i < 20; i++) sendto_(s, b, 60000, a, 16);
    int na = drain(r);
    snprintf(msg, sizeof msg, "A: bind %ld; default SO_RCVBUF: %d of 20 60000-byte datagrams (0 2)", br, na);
    check(br == 0 && na == 2, msg);

    int v = 4 << 20;
    long sv = setopt_(r, 1, 8, &v, 4);
    for (int i = 0; i < 20; i++) sendto_(s, b, 60000, a, 16);
    int nb = drain(r);
    int rb = 0, rbl = 4;
    getopt_(r, 1, 8, &rb, &rbl);
    int want_b = 1;
    while ((want_b + 1) * 94464L <= rb && want_b < 20) want_b++;
    if (want_b > QUEUE_CAP) want_b = QUEUE_CAP;
    snprintf(msg, sizeof msg, "B: SO_RCVBUF 4 MiB %ld reads %d: %d of 20 (0 %d)", sv, rb, nb, want_b);
    check(sv == 0 && nb == want_b, msg);

    long rr = sock(2, 3, 253), rs = sock(2, 3, 253);
    port(0);
    for (int i = 0; i < 20; i++) sendto_(rs, b, 60000, a, 16);
    int nc = drain(rr);
    for (int i = 0; i < 8; i++) sendto_(rs, b, 1000, a, 16);
    int nc2 = drain(rr);
    snprintf(msg, sizeof msg, "C: raw sockets %ld %ld; 60000-byte %d of 20, 1000-byte %d of 8 (>=0 >=0 3 8)", rr, rs, nc, nc2);
    check(rr >= 0 && rs >= 0 && nc == 3 && nc2 == 8, msg);

    long u = sock(2, 2, 0);
    port(4712);
    bind_(u, a, 16);
    setopt_(u, 1, 8, &v, 4);
    long raw = sock(2, 3, 255);
    port(0);
    for (int i = 0; i < 8; i++) frag(raw, 3000 + i, 0);
    for (int i = 0; i < 8; i++) frag(raw, 3000 + i, 1);
    int nd = drain(u);
    snprintf(msg, sizeof msg, "D: IPPROTO_RAW %ld; eight interleaved fragmented datagrams: %d arrive (>=0 8)", raw, nd);
    check(raw >= 0 && nd == 8, msg);

    print(failures ? "hello471: FAIL\n" : "hello471: PASS\n");
    return failures ? 1 : 0;
}
