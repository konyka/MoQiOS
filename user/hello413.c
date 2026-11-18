/* hello413: how long a listener's half-open connection retransmits its SYN-ACK (Linux reqsk_timer_handler, syn_ack_recalc,
 * tcp_reqsk_timeout, net.ipv4.tcp_synack_retries 5; TCP_SYNCNT on the listener replaces it). The SYN-ACK goes out after 1 s,
 * then the wait doubles; after max retransmissions the request is dropped, and an ACK arriving later no longer completes it. The
 * client is forged with an IPPROTO_RAW socket from a port where a listener with a full accept queue sits, so its SYN-ACKs reach
 * no connection: MoQiOS drops them there, Linux answers them with a RST, so on the host the RSTs are dropped with nft (see
 * hello407). Measured on the host (build with -DHOST, run as root in
 * `unshare --map-auto --map-root-user -n` with lo up and RSTs dropped):
 *   R. a listener with TCP_SYNCNT 2: 3 SYN-ACKs in 11 s, the first retransmission 0.7 to 1.6 s after the first, the next 1.5 to
 *      3 s after that; the final ACK sent after that is not accepted (accept EAGAIN);
 *   A. the same listener, final ACK sent right after the first SYN-ACK: accept returns the connection;
 *   D. a listener left alone: 5 SYN-ACKs in the first 16 s (1, 2, 4, 8 s apart). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, MSG_NOSIGNAL, a, (socklen_t)al)); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return rc(recvfrom((int)s, b, (size_t)n, MSG_DONTWAIT, a, (socklen_t *)al)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static void close_(long s) { close((int)s); }
#define NONBLOCK SOCK_NONBLOCK
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0x4000, (long)a, al); }
static long recvfrom_(long s, void *b, long n, void *a, int *al) { return syscall6(122, s, (long)b, n, 0x40, (long)a, (long)al); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(228, 1, (long)t); return t[0] * 1000 + t[1] / 1000000; }
static void close_(long s) { syscall1(11, s); }
#define NONBLOCK 0x800
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello413:   ok   " : "hello413:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static unsigned char seg[1600];
static long rt, rr;
static void mk4(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static void drain(void) { unsigned char a[16]; int l = 16; while (recvfrom_(rt, seg, sizeof seg, a, &l) >= 0) l = 16; }
static unsigned int rd32(const unsigned char *p) { return (unsigned int)(p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]); }
static void wr32(unsigned char *p, unsigned int v) { p[0] = (unsigned char)(v >> 24); p[1] = (unsigned char)(v >> 16); p[2] = (unsigned char)(v >> 8); p[3] = (unsigned char)v; }
/* Send a 20-byte TCP header 127.0.0.1:sport -> 127.0.0.1:dport with `flags`, seq and ack. */
static void forge(int sport, int dport, int flags, unsigned int sq, unsigned int ak) {
    unsigned char p[40];
    memset(p, 0, sizeof p);
    p[0] = 0x45; p[3] = 40; p[8] = 64; p[9] = 6; p[12] = 127; p[15] = 1; p[16] = 127; p[19] = 1;
    unsigned char *t = p + 20;
    t[0] = (unsigned char)(sport >> 8); t[1] = (unsigned char)sport; t[2] = (unsigned char)(dport >> 8); t[3] = (unsigned char)dport;
    wr32(t + 4, sq);
    wr32(t + 8, ak);
    t[12] = 0x50; t[13] = (unsigned char)flags; t[14] = 0xff; t[15] = 0xff;
    unsigned int s = 0x7f00 + 0x0001 + 0x7f00 + 0x0001 + 6 + 20;
    for (int i = 0; i < 20; i += 2) s += (unsigned int)(t[i] << 8 | t[i + 1]);
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    s = ~s & 0xffff;
    t[16] = (unsigned char)(s >> 8); t[17] = (unsigned char)s;
    unsigned char d[16];
    mk4(d, 0);
    sendto_(rr, p, 40, d, 16);
}
/* Watch for SYN-ACKs from `lport` to `cport` for `limit` ms: how many, the time of each (ms from the start) in `at`, the ISN in *isn. */
static int count_synacks(int lport, int cport, long limit, long *at, int max, unsigned int *isn) {
    long t0 = now_ms();
    int n = 0;
    unsigned char a[16];
    while (now_ms() - t0 < limit) {
        int l = 16;
        long r = recvfrom_(rt, seg, sizeof seg, a, &l);
        if (r <= 0) { nap(); continue; }
        int off = (seg[0] & 15) * 4;
        if ((seg[off] << 8 | seg[off + 1]) != lport || (seg[off + 2] << 8 | seg[off + 3]) != cport) continue;
        if ((seg[off + 13] & 0x12) != 0x12) continue;
        if (n < max) at[n] = now_ms() - t0;
        *isn = rd32(seg + off + 4);
        n++;
    }
    return n;
}
/* A full listener on `port` (backlog 1 with two connections queued): the SYN-ACKs the forged clients get land there. */
static long full_listener(int port, long *kid) {
    long l = sock(2, 1, 0);
    unsigned char a[16];
    mk4(a, port);
    bind_(l, a, 16);
    listen_(l, 1);
    for (int i = 0; i < 2; i++) {
        kid[i] = sock(2, 1 | NONBLOCK, 0);
        connect_(kid[i], a, 16);
    }
    for (int i = 0; i < 10; i++) nap();
    return l;
}
static long listener(int port, int syncnt) {
    long l = sock(2, 1 | NONBLOCK, 0);
    if (syncnt > 0) seti(l, 6, 7, syncnt);
    unsigned char a[16];
    mk4(a, port);
    bind_(l, a, 16);
    listen_(l, 4);
    return l;
}
int main(void) {
    print("hello413: SYN-ACK retransmissions of a half-open connection\n");
    rt = sock(2, 3, 6); rr = sock(2, 3, 255);
    long at[16];
    unsigned int isn = 0;
    long kid[2];
    long F = full_listener(40520, kid);

    long l = listener(40421, 2);
    drain();
    forge(40520, 40421, 0x02, 0x1000, 0);
    int n = count_synacks(40421, 40520, 11000, at, 16, &isn);
    forge(40520, 40421, 0x10, 0x1001, isn + 1);
    for (int i = 0; i < 10; i++) nap();
    long ra = accept_(l);
    long g1 = n >= 2 ? at[1] - at[0] : -1, g2 = n >= 3 ? at[2] - at[1] : -1;
    snprintf(msg, sizeof msg, "R: TCP_SYNCNT 2: %d SYN-ACKs in 11 s, gaps %ld %ld ms; accept after the late ACK %ld (3, 700..1600, 1500..3000, -11)", n, g1, g2, ra);
    check(n == 3 && g1 >= 700 && g1 <= 1600 && g2 >= 1500 && g2 <= 3000 && ra == -11, msg);
    if (ra >= 0) close_(ra);
    close_(l);

    l = listener(40422, 2);
    drain();
    forge(40520, 40422, 0x02, 0x5000, 0);
    int an = 0;
    {
        long t0 = now_ms();
        unsigned char a[16];
        while (now_ms() - t0 < 3000 && an == 0) {
            int ll = 16;
            long r = recvfrom_(rt, seg, sizeof seg, a, &ll);
            if (r <= 0) { nap(); continue; }
            int off = (seg[0] & 15) * 4;
            if ((seg[off] << 8 | seg[off + 1]) == 40422 && (seg[off + 13] & 0x12) == 0x12) { isn = rd32(seg + off + 4); an = 1; }
        }
    }
    forge(40520, 40422, 0x10, 0x5001, isn + 1);
    long aa = -1;
    for (int i = 0; i < 50 && aa < 0; i++) { aa = accept_(l); if (aa < 0) nap(); }
    snprintf(msg, sizeof msg, "A: TCP_SYNCNT 2, final ACK after the first SYN-ACK (%d seen): accept %ld (>= 0)", an, aa);
    check(an == 1 && aa >= 0, msg);
    if (aa >= 0) close_(aa);
    close_(l);

    l = listener(40423, 0);
    drain();
    forge(40520, 40423, 0x02, 0x9000, 0);
    int dn = count_synacks(40423, 40520, 16500, at, 16, &isn);
    char gaps[120] = "";
    for (int i = 1; i < dn && i < 6; i++) snprintf(gaps + strlen(gaps), sizeof gaps - strlen(gaps), " %ld", at[i] - at[i - 1]);
    int dok = dn == 5;
    for (int i = 1; dok && i < 5; i++) { long g = at[i] - at[i - 1], w = 1000L << (i - 1); dok = g >= w * 7 / 10 && g <= w * 16 / 10; }
    snprintf(msg, sizeof msg, "D: default listener: %d SYN-ACKs in 16.5 s, gaps%s ms (5, 1000 2000 4000 8000)", dn, gaps);
    check(dok, msg);
    close_(l);

    close_(kid[0]); close_(kid[1]); close_(F); close_(rt); close_(rr);
    print(failures == 0 ? "hello413: PASS\n" : "hello413: FAIL\n");
    return failures == 0 ? 0 : 1;
}
