/* hello419: IP_MTU_DISCOVER (Linux ip_sock_set_mtu_discover, do_ip_getsockopt, __ip_make_skb, ip_queue_xmit, ip_dont_fragment,
 * ip_sk_ignore_df, ip_select_ident_segs). Raw sockets of protocols 17 and 6 see every loopback datagram, IP header included. Measured
 * on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   V. TCP, UDP and raw sockets read 1 (IP_PMTUDISC_WANT) by default; 0..5 are kept and read back; -1 and 6 are EINVAL;
 *   U. an unconnected UDP socket's datagrams carry DF under modes 1, 2 and 3 and none under 0, 4 and 5; under 2 and 3 (DF, no
 *      fragmenting) their id is 0, under the others it is numbered;
 *   T. a TCP connection's data segments carry DF under modes 1 and 2 only;
 *   R. a raw socket's (protocol 17) datagrams carry DF under modes 1, 2 and 3;
 *   A. a connection accepted from a listener in mode 2 reads 2. */
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
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return rc(getsockopt((int)s, lv, o, v, (socklen_t *)l)); }
static void close_(long s) { close((int)s); }
static long send_(long s, const void *b, long n) { return rc(send((int)s, b, (size_t)n, MSG_NOSIGNAL)); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return rc(sendto((int)s, b, (size_t)n, 0, a, (socklen_t)al)); }
static long recv_(long s, void *b, long n) { return rc(recv((int)s, b, (size_t)n, MSG_DONTWAIT)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
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
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getopt_(long s, int lv, int o, void *v, int *l) { return syscall5(133, s, lv, o, (long)v, (long)l); }
static void close_(long s) { syscall1(11, s); }
static long send_(long s, const void *b, long n) { return syscall6(44, s, (long)b, n, 0x4000, 0, 0); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0x4000, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(45, s, (long)b, n, 0x40, 0, 0); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello419:   ok   " : "hello419:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* One captured datagram: for UDP/TCP the ports, for ICMP the type and (errors) the quoted destination port or (echo) the ident. */
struct rec { int proto, sport, dport, tflags, len, id, df, itype; };
static struct rec recs[256];
static int nrecs;
static long raws[3];
static unsigned char pk[2048];
static void drain(void) {
    for (int round = 0; round < 3; round++) {
        nap();
        for (int k = 0; k < 3; k++) {
            for (;;) {
                long g = recv_(raws[k], pk, sizeof pk);
                if (g < 28 || nrecs >= 256) break;
                int ihl = (pk[0] & 15) * 4;
                struct rec *r = &recs[nrecs++];
                memset(r, 0, sizeof *r);
                r->proto = pk[9];
                r->id = (pk[4] << 8) | pk[5];
                r->df = (pk[6] & 0x40) != 0;
                int tot = (pk[2] << 8) | pk[3];
                unsigned char *l4 = pk + ihl;
                if (r->proto == 1) {
                    r->itype = l4[0];
                    if (l4[0] == 3) {
                        int qihl = (l4[8] & 15) * 4;
                        r->dport = (l4[8 + qihl + 2] << 8) | l4[8 + qihl + 3];
                    } else r->dport = (l4[4] << 8) | l4[5];
                } else {
                    r->sport = (l4[0] << 8) | l4[1];
                    r->dport = (l4[2] << 8) | l4[3];
                    if (r->proto == 6) { r->tflags = l4[13]; r->len = tot - ihl - (l4[12] >> 4) * 4; } else r->len = tot - ihl - 8;
                }
            }
        }
    }
}
/* The ids of captured datagrams of `proto` matching sport/dport (-1: any) with payload (TCP: len > 0 when `data`). */
static int pick(int proto, int sport, int dport, int data, int *ids, int *df, int max) {
    int n = 0;
    for (int i = 0; i < nrecs && n < max; i++) {
        struct rec *r = &recs[i];
        if (r->proto != proto || (sport >= 0 && r->sport != sport) || (dport >= 0 && r->dport != dport)) continue;
        if (data && r->len <= 0) continue;
        ids[n] = r->id;
        df[n] = r->df;
        n++;
    }
    return n;
}
static unsigned char lo_a[16];
static void addr(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
static int geti(long s) { int v = -7; int l = 4; long r = getopt_(s, 0, 10, &v, &l); return r < 0 ? (int)r : v; }
static long seti(long s, int v) { return setopt(s, 0, 10, &v, 4); }
int main(void) {
    print("hello419: IP_MTU_DISCOVER\n");
    raws[0] = sock(2, 3, 17);
    raws[1] = sock(2, 3, 6);
    raws[2] = sock(2, 3, 1);
    snprintf(msg, sizeof msg, "raw sockets %ld %ld %ld", raws[0], raws[1], raws[2]);
    check(raws[0] >= 0 && raws[1] >= 0 && raws[2] >= 0, msg);
    if (raws[0] < 0 || raws[1] < 0 || raws[2] < 0) { print("hello419: FAIL\n"); return 1; }
    int ids[8], df[8];

    long t = sock(2, 1, 0), u = sock(2, 2, 0), w = sock(2, 3, 17);
    int dt = geti(t), du = geti(u), dw = geti(w);
    int kept = 1;
    for (int m = 0; m <= 5; m++) if (seti(u, m) != 0 || geti(u) != m) kept = 0;
    long e1 = seti(u, -1), e2 = seti(u, 6);
    snprintf(msg, sizeof msg, "V: defaults tcp %d udp %d raw %d (1 1 1); 0..5 kept %d (1); -1 %ld, 6 %ld (-22 -22), still %d (5)", dt, du, dw, kept, e1, e2, geti(u));
    check(dt == 1 && du == 1 && dw == 1 && kept && e1 == -22 && e2 == -22 && geti(u) == 5, msg);
    close_(t);
    close_(u);
    close_(w);

    long r = sock(2, 2, 0);
    addr(lo_a, 40521);
    bind_(r, lo_a, 16);
    static const int udp_df[6] = { 0, 1, 1, 1, 0, 0 }, udp_zero[6] = { 0, 0, 1, 1, 0, 0 };
    char line[400];
    int ok = 1, n;
    line[0] = 0;
    for (int m = 0; m <= 5; m++) {
        drain();
        nrecs = 0;
        long s = sock(2, 2, 0);
        seti(s, m);
        for (int i = 0; i < 2; i++) { sendto_(s, "m419", 4, lo_a, 16); drain(); }
        n = pick(17, -1, 40521, 0, ids, df, 8);
        int zero = n == 2 && ids[0] == 0 && ids[1] == 0;
        if (n != 2 || df[0] != udp_df[m] || df[1] != udp_df[m] || zero != udp_zero[m]) ok = 0;
        snprintf(line + strlen(line), sizeof line - strlen(line), " %d:%d/%d,%d/%d", m, n ? df[0] : -1, n ? ids[0] : -1, n > 1 ? df[1] : -1, n > 1 ? ids[1] : -1);
        close_(s);
    }
    snprintf(msg, sizeof msg, "U: mode:DF/id,DF/id%s (DF in 1 2 3, id 0 in 2 3)", line);
    check(ok, msg);

    static const int raw_df[6] = { 0, 1, 1, 1, 0, 0 };
    ok = 1;
    line[0] = 0;
    for (int m = 0; m <= 5; m++) {
        drain();
        nrecs = 0;
        long s = sock(2, 3, 17);
        seti(s, m);
        unsigned char dg[9] = { 0x9c, 0x49, 0x9e, 0x49, 0, 9, 0, 0, 'z' };
        unsigned char ra[16];
        addr(ra, 0);
        sendto_(s, dg, 9, ra, 16);
        drain();
        n = pick(17, 40009, 40521, 0, ids, df, 8);
        if (n < 1 || df[0] != raw_df[m]) ok = 0;
        snprintf(line + strlen(line), sizeof line - strlen(line), " %d:%d", m, n ? df[0] : -1);
        close_(s);
    }
    snprintf(msg, sizeof msg, "R: raw mode:DF%s (DF in 1 2 3)", line);
    check(ok, msg);
    close_(r);

    long l = sock(2, 1, 0);
    int one = 1;
    setopt(l, 1, 2, &one, 4);
    addr(lo_a, 40522);
    bind_(l, lo_a, 16);
    listen_(l, 8);
    static const int tcp_df[6] = { 0, 1, 1, 0, 0, 0 };
    ok = 1;
    line[0] = 0;
    for (int m = 0; m <= 5; m++) {
        long c = sock(2, 1, 0);
        seti(c, m);
        connect_(c, lo_a, 16);
        long p = -11;
        for (int i = 0; i < 100 && p < 0; i++) { p = accept_(l); if (p < 0) nap(); }
        drain();
        nrecs = 0;
        send_(c, "d419", 4);
        drain();
        n = 0;
        for (int i = 0; i < nrecs && n < 8; i++)
            if (recs[i].proto == 6 && recs[i].dport == 40522 && recs[i].len > 0) { df[n] = recs[i].df; n++; }
        if (n < 1 || df[0] != tcp_df[m]) ok = 0;
        snprintf(line + strlen(line), sizeof line - strlen(line), " %d:%d", m, n ? df[0] : -1);
        char b[8];
        if (p >= 0) { recv_(p, b, sizeof b); close_(p); }
        close_(c);
    }
    snprintf(msg, sizeof msg, "T: tcp mode:DF%s (DF in 1 2)", line);
    check(ok, msg);

    seti(l, 2);
    long c2 = sock(2, 1, 0);
    connect_(c2, lo_a, 16);
    long p2 = -11;
    for (int i = 0; i < 100 && p2 < 0; i++) { p2 = accept_(l); if (p2 < 0) nap(); }
    int va = p2 >= 0 ? geti(p2) : (int)p2;
    snprintf(msg, sizeof msg, "A: listener in mode 2, accepted connection reads %d (2)", va);
    check(va == 2, msg);
    if (p2 >= 0) close_(p2);
    close_(c2);
    close_(l);
    drain();

    print(failures == 0 ? "hello419: PASS\n" : "hello419: FAIL\n");
    return failures == 0 ? 0 : 1;
}
