/* hello418: the IPv4 id and DF bit of headers the kernel writes (Linux ip_select_ident_segs, __ip_select_ident, ip_build_and_send_pkt,
 * __ip_make_skb). Raw sockets of protocols 17, 6 and 1 see every loopback datagram, IP header included. Measured on the host
 * (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   N. two datagrams of an unconnected UDP socket carry DF and different ids (the hashed counter, which jumps ahead after a pause);
 *   U. three datagrams of a connected UDP socket carry DF and ids one apart (the socket's own counter, random at connect);
 *   R. a second connected UDP socket counts from its own starting point;
 *   T. three data segments of a TCP connection carry DF and ids that grow by one per segment the client sent (a retransmission
 *      included: it repeats a sequence number and takes the next id);
 *   S. the SYN-ACK and the RST answering a SYN to a closed port carry DF and id 0;
 *   E. two ICMP port unreachables carry no DF and ids one apart (the hashed counter of their addresses);
 *   P. an echo request sent on a raw socket carries DF, the kernel's echo reply has none. */
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
static void close_(long s) { syscall1(11, s); }
static long send_(long s, const void *b, long n) { return syscall6(44, s, (long)b, n, 0x4000, 0, 0); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0x4000, (long)a, al); }
static long recv_(long s, void *b, long n) { return syscall6(45, s, (long)b, n, 0x40, 0, 0); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[900];
static void check(int ok, const char *w) {
    print(ok ? "hello418:   ok   " : "hello418:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
/* One captured datagram: for UDP/TCP the ports, for ICMP the type and (errors) the quoted destination port or (echo) the ident. */
struct rec { int proto, sport, dport, tflags, len, id, df, itype; unsigned seq; };
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
                    if (r->proto == 6) {
                        r->tflags = l4[13];
                        r->len = tot - ihl - (l4[12] >> 4) * 4;
                        r->seq = (unsigned)l4[4] << 24 | (unsigned)l4[5] << 16 | (unsigned)l4[6] << 8 | l4[7];
                    } else r->len = tot - ihl - 8;
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
static int step(int a, int b) { return (b - a) & 0xffff; }
static unsigned char lo_a[16];
static void addr(unsigned char *a, int port) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    a[4] = 127;
    a[7] = 1;
}
/* The first captured TCP segment from `sport` to `dport` (-1: any) whose flags include all of `want`; its index or -1. */
static int seg(int sport, int dport, int want) {
    for (int i = 0; i < nrecs; i++)
        if (recs[i].proto == 6 && (sport < 0 || recs[i].sport == sport) && (dport < 0 || recs[i].dport == dport) && (recs[i].tflags & want) == want) return i;
    return -1;
}
static int icmp_of(int type, int key, int *ids, int *df, int max) {
    int n = 0;
    for (int i = 0; i < nrecs && n < max; i++)
        if (recs[i].proto == 1 && recs[i].itype == type && recs[i].dport == key) { ids[n] = recs[i].id; df[n] = recs[i].df; n++; }
    return n;
}
int main(void) {
    print("hello418: IPv4 id and DF of kernel-built headers\n");
    raws[0] = sock(2, 3, 17);
    raws[1] = sock(2, 3, 6);
    raws[2] = sock(2, 3, 1);
    snprintf(msg, sizeof msg, "raw sockets %ld %ld %ld", raws[0], raws[1], raws[2]);
    check(raws[0] >= 0 && raws[1] >= 0 && raws[2] >= 0, msg);
    if (raws[0] < 0 || raws[1] < 0 || raws[2] < 0) { print("hello418: FAIL\n"); return 1; }
    drain();
    nrecs = 0;
    int ids[8], df[8];

    long r = sock(2, 2, 0);
    addr(lo_a, 40521);
    bind_(r, lo_a, 16);
    long w = sock(2, 2, 0);
    for (int i = 0; i < 2; i++) { sendto_(w, "w418", 4, lo_a, 16); drain(); }
    int n = pick(17, -1, 40521, 0, ids, df, 8);
    snprintf(msg, sizeof msg, "N: %d datagrams of an unconnected socket, ids %d %d, DF %d%d (shared counter: different ids, DF)", n, ids[0], ids[1], df[0], df[1]);
    check(n == 2 && ids[0] != ids[1] && df[0] && df[1], msg);
    close_(w);
    nrecs = 0;
    long u = sock(2, 2, 0);
    connect_(u, lo_a, 16);
    for (int i = 0; i < 3; i++) { send_(u, "u418", 4); drain(); }
    n = pick(17, -1, 40521, 0, ids, df, 8);
    int u_last = n >= 3 ? ids[2] : -1;
    snprintf(msg, sizeof msg, "U: %d datagrams of one connected socket, ids %d %d %d, DF %d%d%d (one apart, DF)", n, ids[0], ids[1], ids[2], df[0], df[1], df[2]);
    check(n == 3 && step(ids[0], ids[1]) == 1 && step(ids[1], ids[2]) == 1 && df[0] && df[1] && df[2], msg);
    nrecs = 0;
    long u2 = sock(2, 2, 0);
    connect_(u2, lo_a, 16);
    for (int i = 0; i < 2; i++) { send_(u2, "v418", 4); drain(); }
    n = pick(17, -1, 40521, 0, ids, df, 8);
    snprintf(msg, sizeof msg, "R: a second socket's ids %d %d after the first's %d (its own counter, DF %d%d)", ids[0], ids[1], u_last, df[0], df[1]);
    check(n == 2 && step(ids[0], ids[1]) == 1 && step(u_last, ids[0]) != 1 && df[0] && df[1], msg);
    close_(u2);
    close_(u);
    close_(r);

    nrecs = 0;
    long l = sock(2, 1, 0);
    int one = 1;
    setopt(l, 1, 2, &one, 4);
    addr(lo_a, 40522);
    bind_(l, lo_a, 16);
    listen_(l, 4);
    long c = sock(2, 1, 0);
    setopt(c, 6, 1, &one, 4);
    connect_(c, lo_a, 16);
    long p = -11;
    for (int i = 0; i < 100 && p < 0; i++) { p = accept_(l); if (p < 0) nap(); }
    drain();
    int sa = seg(40522, -1, 0x12);
    snprintf(msg, sizeof msg, "S: SYN-ACK id %d DF %d (0, DF)", sa >= 0 ? recs[sa].id : -1, sa >= 0 ? recs[sa].df : -1);
    check(sa >= 0 && recs[sa].id == 0 && recs[sa].df, msg);
    int base = nrecs;
    for (int i = 0; i < 3; i++) { send_(c, "t418", 4); drain(); }
    /* A retransmission or tail-loss probe (a loaded host can delay the ACK) is one more segment with the same sequence number;
     * it takes the next id too (Linux, ip_select_ident_segs), so every data segment is one apart and three sequences are sent. */
    n = 0;
    unsigned seqs[8];
    int nseq = 0, ones = 1, alldf = 1;
    for (int i = base; i < nrecs && n < 8; i++) {
        if (recs[i].proto != 6 || recs[i].dport != 40522 || recs[i].len <= 0) continue;
        ids[n] = recs[i].id;
        df[n] = recs[i].df;
        if (n > 0 && step(ids[n - 1], ids[n]) != 1) ones = 0;
        if (!df[n]) alldf = 0;
        int seen = 0;
        for (int j = 0; j < nseq; j++) if (seqs[j] == recs[i].seq) seen = 1;
        if (!seen) seqs[nseq++] = recs[i].seq;
        n++;
    }
    char idtext[200] = "";
    for (int i = 0, o = 0, k = base; i < n && k < nrecs; k++) {
        if (recs[k].proto != 6 || recs[k].dport != 40522 || recs[k].len <= 0) continue;
        o += snprintf(idtext + o, sizeof idtext - (size_t)o, "%s%d/seq%u", i ? " " : "", ids[i], recs[k].seq);
        i++;
    }
    snprintf(msg, sizeof msg, "T: %d data segments with %d sequences, ids %s, one apart %d, DF %d (3 sequences, ids one apart, DF)", n, nseq,
             idtext, ones, alldf);
    check(n >= 3 && nseq == 3 && ones && alldf, msg);
    char b[16];
    recv_(p, b, sizeof b);
    close_(c);
    if (p >= 0) close_(p);
    close_(l);
    drain();

    nrecs = 0;
    long k = sock(2, 1, 0);
    addr(lo_a, 40599);
    long cr = connect_(k, lo_a, 16);
    drain();
    int rs = seg(40599, -1, 0x04);
    snprintf(msg, sizeof msg, "S: connect to a closed port %ld, the RST has id %d DF %d (0, DF)", cr, rs >= 0 ? recs[rs].id : -1, rs >= 0 ? recs[rs].df : -1);
    check(cr == -111 && rs >= 0 && recs[rs].id == 0 && recs[rs].df, msg);
    close_(k);

    nrecs = 0;
    long e = sock(2, 2, 0);
    for (int i = 0; i < 2; i++) { sendto_(e, "e418", 4, lo_a, 16); drain(); }
    n = icmp_of(3, 40599, ids, df, 8);
    snprintf(msg, sizeof msg, "E: %d port unreachables, ids %d %d, DF %d%d (no DF, different ids)", n, ids[0], ids[1], df[0], df[1]);
    check(n == 2 && ids[0] != ids[1] && !df[0] && !df[1], msg);
    close_(e);

    nrecs = 0;
    unsigned char ping[16];
    memset(ping, 0, sizeof ping);
    ping[0] = 8;
    ping[4] = 0x41;
    ping[5] = 0x18;
    ping[7] = 1;
    unsigned long sum = 0;
    for (int i = 0; i < 16; i += 2) sum += (ping[i] << 8) | ping[i + 1];
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    ping[2] = (unsigned char)(~sum >> 8);
    ping[3] = (unsigned char)~sum;
    addr(lo_a, 0);
    sendto_(raws[2], ping, 16, lo_a, 16);
    drain();
    int qid[4], qdf[4];
    int nq = icmp_of(8, 0x4118, qid, qdf, 4);
    n = icmp_of(0, 0x4118, ids, df, 8);
    snprintf(msg, sizeof msg, "P: echo request DF %d, echo reply DF %d id %d (DF, then none)", nq ? qdf[0] : -1, n ? df[0] : -1, n ? ids[0] : -1);
    check(nq == 1 && qdf[0] && n == 1 && !df[0], msg);

    print(failures == 0 ? "hello418: PASS\n" : "hello418: FAIL\n");
    return failures == 0 ? 0 : 1;
}
