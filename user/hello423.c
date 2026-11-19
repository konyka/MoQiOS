/* hello423: IPv4 UDP sendmsg control messages (Linux udp_sendmsg -> ip_cmsg_send, __sock_cmsg_send). IP_TTL (an int, 1..255) and
 * IP_TOS (an int or one byte, 0..255) override the socket's values for that one datagram; IP_PKTINFO (exactly a struct in_pktinfo)
 * names the source address (ipi_spec_dst; ipi_addr is ignored) and the outgoing interface (ipi_ifindex, 0 for none). A malformed
 * message or an unknown IP-level type is EINVAL; SCM_RIGHTS / SCM_CREDENTIALS and other levels are skipped; a control buffer shorter
 * than one header holds no message. Destination errors come first.
 * Measured on the host (build with -DHOST, run in `unshare --map-auto --map-root-user -n` with lo up):
 *   O. a plain sendmsg carries the socket's IP_TTL 33 / IP_TOS 0x28; IP_TTL 7 gives ttl 7; IP_TOS 0x4b (int) and 0x51 (one byte) give
 *      that tos; IP_TTL 9 with IP_TOS 0x60 gives both; the next plain send is back to 33 / 0x28;
 *   E. EINVAL for: IP_TTL 0, 256, a 1-byte IP_TTL; IP_TOS 256, -1, 2 bytes; IP level type 99; cmsg_len 12; cmsg_len past the end;
 *      SOL_SOCKET type 99; IP_PKTINFO of 16 bytes;
 *   S. skipped: SOL_TCP type 1, SCM_RIGHTS, an 8-byte control buffer (each datagram arrives with 33 / 0x28);
 *   P. IP_PKTINFO spec_dst 127.0.0.5 sends from 127.0.0.5 (ipi_addr 127.0.0.7... ignored: spec_dst 127.0.0.7 sends from 127.0.0.7);
 *      ifindex 1 sends; ifindex 99 is ENODEV; spec_dst 192.0.2.1 (not ours) is ENETUNREACH; neither error sends anything;
 *   D. an unconnected socket without a destination and with a bad IP_TTL is EDESTADDRREQ. */
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
static long setopt(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static void close_(long s) { close((int)s); }
static long sendmsg_(long s, long *m, int fl) { return rc(sendmsg((int)s, (struct msghdr *)m, fl)); }
static long recvmsg_(long s, long *m, int fl) { return rc(recvmsg((int)s, (struct msghdr *)m, fl)); }
static void nap(void) { struct timespec t = { 0, 20000000 }; nanosleep(&t, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long setopt(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static void close_(long s) { syscall1(11, s); }
static long sendmsg_(long s, long *m, int fl) { return syscall3(46, s, (long)m, fl); }
static long recvmsg_(long s, long *m, int fl) { return syscall3(130, s, (long)m, fl); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
#endif
static int failures;
static char msg[1600];
static void check(int ok, const char *w) {
    print(ok ? "hello423:   ok   " : "hello423:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long seti(long s, int lv, int o, int v) { return setopt(s, lv, o, &v, 4); }
static void mk4(unsigned char *a, int port, int last) {
    memset(a, 0, 16);
    a[0] = 2;
    a[2] = (unsigned char)(port >> 8);
    a[3] = (unsigned char)port;
    if (last) { a[4] = 127; a[7] = (unsigned char)last; }
}
static unsigned char cbuf[256];
/* Append a control message at `off` (cmsg_len `len`, or the exact length when 0); returns the next offset. */
static int put(int off, int lv, int ty, const void *d, int dl, long len) {
    memset(cbuf + off, 0, 16 + ((dl + 7) & ~7));
    long l = len ? len : 16 + dl;
    memcpy(cbuf + off, &l, 8);
    memcpy(cbuf + off + 8, &lv, 4);
    memcpy(cbuf + off + 12, &ty, 4);
    memcpy(cbuf + off + 16, d, (size_t)dl);
    return off + 16 + ((dl + 7) & ~7);
}
static unsigned char to[16];
static long tx;
static long snd_to(long s, const unsigned char *dst, long clen) {
    static char data[4] = { 'p', 'i', 'n', 'g' };
    long iov[2] = { (long)data, 4 };
    long m[7] = { (long)dst, dst ? 16 : 0, (long)iov, 1, clen ? (long)cbuf : 0, clen, 0 };
    return sendmsg_(s, m, 0);
}
static long snd(long clen) { return snd_to(tx, to, clen); }
static long rx;
static int r_ttl, r_tos;
static unsigned char r_from[4];
/* Receive one datagram on rx without waiting: its length (-11 when none came), TTL, TOS and source in r_ttl, r_tos, r_from. */
static long rcv(void) {
    for (int i = 0; i < 3; i++) nap();
    static char d[16];
    static unsigned char c[128];
    unsigned char from[16];
    long iov[2] = { (long)d, 16 };
    long m[7] = { (long)from, 16, (long)iov, 1, (long)c, 128, 0 };
    r_ttl = r_tos = -1;
    memset(from, 0, sizeof from);
    long r = recvmsg_(rx, m, 0x40);
    if (r < 0) return r;
    long cl = m[5];
    for (long off = 0; off + 16 <= cl;) {
        long l = 0;
        int ty = 0;
        memcpy(&l, c + off, 8);
        memcpy(&ty, c + off + 12, 4);
        if (ty == 2) memcpy(&r_ttl, c + off + 16, 4);
        if (ty == 1) r_tos = c[off + 16];
        if (l < 16) break;
        off += (l + 7) & ~7L;
    }
    memcpy(r_from, from + 4, 4);
    return r;
}
int main(void) {
    print("hello423: IPv4 UDP sendmsg control messages\n");
    unsigned char ra[16];
    mk4(ra, 40423, 0);
    mk4(to, 40423, 1);
    rx = sock(2, 2, 0);
    long b = bind_(rx, ra, 16);
    seti(rx, 0, 12, 1);
    seti(rx, 0, 13, 1);
    tx = sock(2, 2, 0);
    seti(tx, 0, 2, 33);
    seti(tx, 0, 1, 0x28);
    int v;
    unsigned char one;

    long s0 = snd(0), g0 = rcv(); int t0 = r_ttl, q0 = r_tos;
    v = 7; long s1 = snd(put(0, 0, 2, &v, 4, 0)), g1 = rcv(); int t1 = r_ttl, q1 = r_tos;
    v = 0x4b; long s2 = snd(put(0, 0, 1, &v, 4, 0)), g2 = rcv(); int t2 = r_ttl, q2 = r_tos;
    one = 0x51; long s3 = snd(put(0, 0, 1, &one, 1, 0)), g3 = rcv(); int t3 = r_ttl, q3 = r_tos;
    v = 9; int o = put(0, 0, 2, &v, 4, 0); v = 0x60; o = put(o, 0, 1, &v, 4, 0);
    long s4 = snd(o), g4 = rcv(); int t4 = r_ttl, q4 = r_tos;
    long s5 = snd(0), g5 = rcv(); int t5 = r_ttl, q5 = r_tos;
    snprintf(msg, sizeof msg, "O: bind %ld; plain %ld/%ld %d 0x%x; ttl7 %ld/%ld %d 0x%x; tos 0x4b %ld/%ld %d 0x%x; 1-byte tos 0x51 %ld/%ld %d 0x%x; both %ld/%ld %d 0x%x; plain again %ld/%ld %d 0x%x "
             "(0; 0/4 33 0x28; 0/4 7 0x28; 0/4 33 0x4b; 0/4 33 0x51; 0/4 9 0x60; 0/4 33 0x28)",
             b, s0, g0, t0, q0, s1, g1, t1, q1, s2, g2, t2, q2, s3, g3, t3, q3, s4, g4, t4, q4, s5, g5, t5, q5);
    check(b == 0 && s0 == 4 && g0 == 4 && t0 == 33 && q0 == 0x28 && s1 == 4 && g1 == 4 && t1 == 7 && q1 == 0x28 && s2 == 4 && g2 == 4 && t2 == 33 &&
          q2 == 0x4b && s3 == 4 && g3 == 4 && t3 == 33 && q3 == 0x51 && s4 == 4 && g4 == 4 && t4 == 9 && q4 == 0x60 && s5 == 4 && g5 == 4 && t5 == 33 &&
          q5 == 0x28, msg);

    long e[11];
    unsigned char pi[12];
    v = 0; e[0] = snd(put(0, 0, 2, &v, 4, 0));
    v = 256; e[1] = snd(put(0, 0, 2, &v, 4, 0));
    one = 5; e[2] = snd(put(0, 0, 2, &one, 1, 0));
    v = 256; e[3] = snd(put(0, 0, 1, &v, 4, 0));
    v = -1; e[4] = snd(put(0, 0, 1, &v, 4, 0));
    v = 3; e[5] = snd(put(0, 0, 1, &v, 2, 0));
    v = 3; e[6] = snd(put(0, 0, 99, &v, 4, 0));
    v = 3; e[7] = snd(put(0, 0, 2, &v, 4, 12));
    v = 3; put(0, 0, 2, &v, 4, 64); e[8] = snd(24);
    v = 3; e[9] = snd(put(0, 1, 99, &v, 4, 0));
    memset(pi, 0, sizeof pi); e[10] = snd(put(0, 0, 8, pi, 12, 32));
    long ge = rcv();
    snprintf(msg, sizeof msg, "E: ttl 0 %ld, 256 %ld, 1 byte %ld; tos 256 %ld, -1 %ld, 2 bytes %ld; type 99 %ld; cmsg_len 12 %ld; past the end %ld; SOL_SOCKET 99 %ld; "
             "PKTINFO 16 bytes %ld; nothing sent %ld (all -22; -11)", e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9], e[10], ge);
    int eok = ge == -11;
    for (int i = 0; i < 11; i++) eok = eok && e[i] == -22;
    check(eok, msg);

    v = 3; long k0 = snd(put(0, 6, 1, &v, 4, 0)), h0 = rcv(); int kt0 = r_ttl, kq0 = r_tos;
    v = 3; long k1 = snd(put(0, 1, 1, &v, 4, 0)), h1 = rcv(); int kt1 = r_ttl, kq1 = r_tos;
    long k2 = snd(8), h2 = rcv(); int kt2 = r_ttl, kq2 = r_tos;
    snprintf(msg, sizeof msg, "S: SOL_TCP %ld/%ld %d 0x%x; SCM_RIGHTS %ld/%ld %d 0x%x; 8-byte buffer %ld/%ld %d 0x%x (4/4 33 0x28 each)",
             k0, h0, kt0, kq0, k1, h1, kt1, kq1, k2, h2, kt2, kq2);
    check(k0 == 4 && h0 == 4 && kt0 == 33 && kq0 == 0x28 && k1 == 4 && h1 == 4 && kt1 == 33 && kq1 == 0x28 && k2 == 4 && h2 == 4 && kt2 == 33 && kq2 == 0x28, msg);

    memset(pi, 0, sizeof pi); pi[4] = 127; pi[7] = 5;
    long p0 = snd(put(0, 0, 8, pi, 12, 0)), j0 = rcv(); int f0 = r_from[3], f0a = r_from[0];
    memset(pi, 0, sizeof pi); pi[4] = 127; pi[7] = 7; pi[8] = 127; pi[11] = 9;
    long p1 = snd(put(0, 0, 8, pi, 12, 0)), j1 = rcv(); int f1 = r_from[3];
    memset(pi, 0, sizeof pi); pi[0] = 1;
    long p2 = snd(put(0, 0, 8, pi, 12, 0)), j2 = rcv(); int f2 = r_from[3];
    memset(pi, 0, sizeof pi); pi[0] = 99;
    long p3 = snd(put(0, 0, 8, pi, 12, 0));
    memset(pi, 0, sizeof pi); pi[4] = 192; pi[6] = 2; pi[7] = 1;
    long p4 = snd(put(0, 0, 8, pi, 12, 0));
    long j3 = rcv();
    snprintf(msg, sizeof msg, "P: spec_dst 127.0.0.5 %ld/%ld from %d.x.x.%d; spec_dst 127.0.0.7 addr 127.0.0.9 %ld/%ld from .%d; ifindex 1 %ld/%ld from .%d; ifindex 99 %ld; "
             "spec_dst 192.0.2.1 %ld; then nothing %ld (4/4 127.5; 4/4 .7; 4/4 .1; -19; -101; -11)", p0, j0, f0a, f0, p1, j1, f1, p2, j2, f2, p3, p4, j3);
    check(p0 == 4 && j0 == 4 && f0a == 127 && f0 == 5 && p1 == 4 && j1 == 4 && f1 == 7 && p2 == 4 && j2 == 4 && f2 == 1 && p3 == -19 && p4 == -101 && j3 == -11, msg);

    long un = sock(2, 2, 0);
    v = 0; long dn = snd_to(un, 0, put(0, 0, 2, &v, 4, 0));
    snprintf(msg, sizeof msg, "D: no destination and a bad IP_TTL: %ld (-89)", dn);
    check(dn == -89, msg);

    close_(un);
    close_(tx);
    close_(rx);
    print(failures == 0 ? "hello423: PASS\n" : "hello423: FAIL\n");
    return failures == 0 ? 0 : 1;
}
