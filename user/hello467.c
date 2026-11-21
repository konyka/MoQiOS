/* hello467: IPv4 options on TCP sockets (Linux do_ip_setsockopt IP_OPTIONS on an inet_connection_sock sets icsk_ext_hdr_len and
 * re-syncs the MSS; ip_queue_xmit builds the options into every segment; tcp_v4_save_options keeps a SYN's echoed options for the
 * connection accepted from it). An observer raw TCP socket sees every segment sent to 127.0.0.1. Measured on the host (build with
 * -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up, MTU 1500):
 *   A. a client with a 7-byte record route (getsockopt 8 bytes 07 07 04 00 ...) connects: its SYN and the final ACK have a 28-byte
 *      header with 07 07 08 7f 00 00 01 00; the accepted socket reads back 07 07 08 7f 00 00 01 00 (the SYN's route, echoed) and
 *      its SYN-ACK and data carry the same; TCP_MAXSEG is 1440 on both (B's 1448 less the 8 bytes);
 *   B. options on the listener are not inherited: the next connection's segments have a 20-byte header, the accepted socket reads
 *      0 bytes and TCP_MAXSEG is 1448;
 *   C. IP_OPTIONS set on a connected socket: its next segment carries them and TCP_MAXSEG drops to 1440; cleared with 0 bytes,
 *      the next segment has none and TCP_MAXSEG is 1448 again;
 *   D. a malformed IP_OPTIONS (07 02) is EINVAL. */
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
static long write_(long s, const void *b, long n) { return rc(write((int)s, b, (size_t)n)); }
static long recv_(long s, void *b, long n, int f) { return rc(recv((int)s, b, (size_t)n, f)); }
static void nap(void) { usleep(20000); }
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
static long write_(long s, const void *b, long n) { return syscall3(1, s, (long)b, n); }
static long recv_(long s, void *b, long n, int f) { return syscall6(122, s, (long)b, n, f, 0, 0); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello467:   ok   " : "hello467:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long obs;
/* Segments the observer saw from port `sport` with TCP flags `fl` (0: any; ECE and CWR are not compared): how many, and the IP header length and options of
 * the last one in hl / ho. Everything queued is drained. */
static int hl;
static unsigned char ho[40];
static int seen(int sport, int fl) {
    int n = 0;
    static unsigned char d[2048];
    for (;;) {
        long r = recv_(obs, d, sizeof d, 0x40);
        if (r < 20) break;
        int ihl = (d[0] & 15) * 4;
        if (r < ihl + 20) continue;
        int sp = d[ihl] << 8 | d[ihl + 1];
        if (sp != sport || (fl && (d[ihl + 13] & 0x3f) != fl)) continue;
        n++;
        hl = ihl;
        memcpy(ho, d + 20, (unsigned long)(ihl - 20));
    }
    return n;
}
static int maxseg(long s) {
    int m = 0, l = 4;
    getopt_(s, 6, 2, &m, &l);
    return m;
}
static int port_of(long s) {
    unsigned char a[16];
    int l = 16;
#ifdef HOST
    socklen_t sl = 16;
    getsockname((int)s, (struct sockaddr *)a, &sl);
#else
    syscall3(126, s, (long)a, (long)&l);
#endif
    (void)l;
    return a[2] << 8 | a[3];
}
static int eq(const unsigned char *x, const unsigned char *y, int n) { return memcmp(x, y, (unsigned long)n) == 0; }
int main(void) {
    print("hello467: IPv4 options on TCP sockets\n");
    unsigned char a[16];
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4670 >> 8; a[3] = 4670 & 0xff; a[4] = 127; a[7] = 1;
    obs = sock(2, 3, 6);
    long l = sock(2, 1, 0);
    int one = 1;
    setopt_(l, 1, 2, &one, 4);
    long b = bind_(l, a, 16), li = listen_(l, 4);
    snprintf(msg, sizeof msg, "setup: observer %ld listener %ld bind %ld listen %ld (>=0 >=0 0 0)", obs, l, b, li);
    check(obs >= 0 && l >= 0 && b == 0 && li == 0, msg);

    static const unsigned char rr7[7] = { 7, 7, 4, 0, 0, 0, 0 };
    static const unsigned char rr_pad[8] = { 7, 7, 4, 0, 0, 0, 0, 0 };
    static const unsigned char rr_got[8] = { 7, 7, 8, 127, 0, 0, 1, 0 };
    long c = sock(2, 1, 0);
    long a1 = setopt_(c, 0, 4, rr7, 7);
    unsigned char ob[40];
    int ol = 40;
    long a2 = getopt_(c, 0, 4, ob, &ol);
    int a_get = a2 == 0 && ol == 8 && eq(ob, rr_pad, 8);
    long a3 = connect_(c, a, 16);
    long s = accept_(l);
    nap();
    int cport = port_of(c);
    int syn = seen(cport, 0x02);
    int syn_ok = syn == 1 && hl == 28 && eq(ho, rr_got, 8);
    ol = 40;
    long a4 = getopt_(s, 0, 4, ob, &ol);
    int s_get = a4 == 0 && ol == 8 && eq(ob, rr_got, 8);
    write_(s, "x", 1);
    nap();
    int data = seen(4670, 0x18);
    int data_ok = data == 1 && hl == 28 && eq(ho, rr_got, 8);
    int m1 = maxseg(c), m2 = maxseg(s);

    static const unsigned char ts[8] = { 0x44, 8, 5, 0, 0, 0, 0, 0 };
    long b1 = setopt_(l, 0, 4, ts, 8);
    long c2 = sock(2, 1, 0);
    long b2 = connect_(c2, a, 16);
    long s2 = accept_(l);
    nap();
    int c2port = port_of(c2);
    int syn2 = seen(c2port, 0x02);
    int syn2_hl = hl;
    ol = 40;
    long b3 = getopt_(s2, 0, 4, ob, &ol);
    int m3 = maxseg(s2);
    /* The MSS without options (1448 on the host, where timestamps take 12 bytes) less the 8 bytes of record route. */
    snprintf(msg, sizeof msg, "A: client set %ld get right %d connect %ld accept %ld; SYN %d right %d; accepted get right %d, its data %d right %d; MAXSEG %d %d = %d - 8 (0 1 0 >=0 1 1 1 1 1)",
             a1, a_get, a3, s, syn, syn_ok, s_get, data, data_ok, m1, m2, m3);
    check(a1 == 0 && a_get && a3 == 0 && s >= 0 && syn_ok && s_get && data_ok && m1 == m3 - 8 && m2 == m3 - 8, msg);
    snprintf(msg, sizeof msg, "B: listener options set %ld; connect %ld accept %ld; SYN %d header %d; accepted get %ld len %d MAXSEG %d (0 0 >=0 1 20 0 0 1448 on the host)", b1, b2, s2, syn2,
             syn2_hl, b3, ol, m3);
    check(b1 == 0 && b2 == 0 && s2 >= 0 && syn2 == 1 && syn2_hl == 20 && b3 == 0 && ol == 0 && m3 > 1000, msg);

    setopt_(c2, 6, 1, &one, 4); /* TCP_NODELAY: each write leaves at once, whatever is unacknowledged */
    long c1 = setopt_(c2, 0, 4, rr_pad, 8);
    int m4 = maxseg(c2);
    write_(c2, "y", 1);
    nap();
    int d1 = seen(c2port, 0x18);
    int d1_ok = d1 == 1 && hl == 28 && eq(ho, rr_got, 8);
    long c3 = setopt_(c2, 0, 4, 0, 0);
    int m5 = maxseg(c2);
    write_(c2, "z", 1);
    nap();
    int d2 = seen(c2port, 0x18);
    int d2_hl = hl;
    snprintf(msg, sizeof msg, "C: set on a connection %ld MAXSEG %d, next segment %d right %d; cleared %ld MAXSEG %d, next segment %d header %d (0 %d 1 1 0 %d 1 20)", c1, m4, d1, d1_ok, c3, m5,
             d2, d2_hl, m3 - 8, m3);
    check(c1 == 0 && m4 == m3 - 8 && d1_ok && c3 == 0 && m5 == m3 && d2 == 1 && d2_hl == 20, msg);

    static const unsigned char bad[2] = { 7, 2 };
    long e1 = setopt_(c2, 0, 4, bad, 2);
    snprintf(msg, sizeof msg, "D: malformed %ld (-22)", e1);
    check(e1 == -22, msg);

    print(failures ? "hello467: FAIL\n" : "hello467: PASS\n");
    return failures ? 1 : 0;
}
