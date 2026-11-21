/* hello464: IPv4 options of received datagrams, IP_RECVOPTS and IP_RETOPTS (Linux ip_rcv_options → __ip_options_compile,
 * ip_cmsg_recv_opts, ip_cmsg_recv_retopts → ip_options_echo + ip_options_undo). A raw IPPROTO_RAW socket writes UDP datagrams with
 * an 8-byte option block to 127.0.0.1:4640; the receiving UDP socket has IP_RECVOPTS and IP_RETOPTS on. Measured on the host
 * (build with -DHOST, run as root in `unshare --map-auto --map-root-user -n` with lo up):
 *   A. setsockopt IP_RECVOPTS / IP_RETOPTS 1: 0, both read back 1; a datagram without options brings no control message;
 *   B. NOP NOP NOP END: IP_RECVOPTS 01 01 01 00 00 00 00 00 (24 bytes), IP_RETOPTS empty (16 bytes);
 *   C. record route with one free slot (07 07 04 ...): the receiver records itself, both messages read 07 07 08 7f 00 00 01 00;
 *   D. a full record route (07 03 04 00): IP_RECVOPTS 07 03 04 00 00 00 00 00, IP_RETOPTS 07 03 04 00 (20 bytes);
 *   E. a timestamp (44 08 05 00, time only): the receiver writes its time and advances the pointer to 9 in both messages; the time
 *      is milliseconds since midnight UTC (within a second of CLOCK_REALTIME);
 *   F. a malformed option (record route of length 2) or a loose source route drops the datagram (EAGAIN). */
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
static long setopt_(long s, int lv, int o, const void *v, int l) { return rc(setsockopt((int)s, lv, o, v, (socklen_t)l)); }
static long getint(long s, int lv, int o) { int v = -1; socklen_t l = 4; long r = rc(getsockopt((int)s, lv, o, &v, &l)); return r < 0 ? r : v; }
static long recvmsg_(long s, void *m, int f) { return rc(recvmsg((int)s, m, f)); }
static void nap(void) { usleep(20000); }
#include <time.h>
static long now_ms(void) { struct timespec t; clock_gettime(CLOCK_REALTIME, &t); return (long)((t.tv_sec % 86400) * 1000 + t.tv_nsec / 1000000); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long sendto_(long s, const void *b, long n, const void *a, int al) { return syscall6(121, s, (long)b, n, 0, (long)a, al); }
static long setopt_(long s, int lv, int o, const void *v, int l) { return syscall5(132, s, lv, o, (long)v, l); }
static long getint(long s, int lv, int o) { int v = -1; int l = 4; long r = syscall5(133, s, lv, o, (long)&v, (long)&l); return r < 0 ? r : v; }
static long recvmsg_(long s, void *m, int f) { return syscall3(130, s, (long)m, f); }
static void nap(void) { long t[2] = { 0, 20000000 }; syscall1(104, 0); syscall2(35, (long)t, 0); }
static long now_ms(void) { long t[2] = { 0, 0 }; syscall2(SYS_clock_gettime, 0, (long)t); return (t[0] % 86400) * 1000 + t[1] / 1000000; }
#endif
static int failures;
static char msg[400];
static void check(int ok, const char *w) {
    print(ok ? "hello464:   ok   " : "hello464:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long raw, rcv;
static unsigned char a[16];
/* Send "x" to 127.0.0.1:4640 from port 4641 through the IPPROTO_RAW socket with the 8 option bytes `opt` (none when null). */
static long send_opts(const unsigned char *opt) {
    unsigned char p[40];
    memset(p, 0, sizeof p);
    int hl = opt ? 28 : 20;
    p[0] = (unsigned char)(0x40 | (hl / 4));
    p[3] = (unsigned char)(hl + 9);
    p[8] = 64; p[9] = 17;
    p[12] = 127; p[15] = 1; p[16] = 127; p[19] = 1;
    if (opt) memcpy(p + 20, opt, 8);
    unsigned char *u = p + hl;
    u[0] = 4641 >> 8; u[1] = 4641 & 0xff; u[2] = 4640 >> 8; u[3] = 4640 & 0xff; u[5] = 9; u[8] = 'x';
    return sendto_(raw, p, hl + 9, a, 16);
}
/* The next datagram: its length, and the IP_RECVOPTS (type 6) / IP_RETOPTS (type 7) payloads with their cmsg_len (-1 absent). */
static unsigned char ro[40], rr[40];
static long ro_len, rr_len;
static long next(void) {
    nap();
    static unsigned char ctl[256];
    char d[8];
    unsigned char mh[56];
    memset(mh, 0, sizeof mh);
    memset(ctl, 0, sizeof ctl);
    long iov[2] = { (long)d, 8 };
    long ip = (long)iov, one = 1, cp = (long)ctl, cl = sizeof ctl;
    memcpy(mh + 16, &ip, 8); memcpy(mh + 24, &one, 8); memcpy(mh + 32, &cp, 8); memcpy(mh + 40, &cl, 8);
    ro_len = rr_len = -1;
    long r = recvmsg_(rcv, mh, 0x40);
    if (r < 0) return r;
    long used;
    memcpy(&used, mh + 40, 8);
    for (long off = 0; off + 16 <= used;) {
        long len;
        int lv, ty;
        memcpy(&len, ctl + off, 8); memcpy(&lv, ctl + off + 8, 4); memcpy(&ty, ctl + off + 12, 4);
        if (len < 16) break;
        if (lv == 0 && ty == 6) { ro_len = len; memcpy(ro, ctl + off + 16, (unsigned long)(len - 16 > 40 ? 40 : len - 16)); }
        if (lv == 0 && ty == 7) { rr_len = len; memcpy(rr, ctl + off + 16, (unsigned long)(len - 16 > 40 ? 40 : len - 16)); }
        off += (len + 7) & ~7L;
    }
    return r;
}
static int eq(const unsigned char *x, const unsigned char *y, int n) { return memcmp(x, y, (unsigned long)n) == 0; }
int main(void) {
    print("hello464: IPv4 options, IP_RECVOPTS and IP_RETOPTS\n");
    memset(a, 0, 16);
    a[0] = 2; a[2] = 4640 >> 8; a[3] = 4640 & 0xff; a[4] = 127; a[7] = 1;
    rcv = sock(2, 2, 0);
    bind_(rcv, a, 16);
    raw = sock(2, 3, 255);
    int one = 1;
    long s1 = setopt_(rcv, 0, 6, &one, 4), s2 = setopt_(rcv, 0, 7, &one, 4);
    long g1 = getint(rcv, 0, 6), g2 = getint(rcv, 0, 7);
    long an = send_opts(0);
    long ar = next();
    snprintf(msg, sizeof msg, "A: raw %d; set %ld %ld, get %ld %ld; no options: send %ld recv %ld, messages %ld %ld (1; 0 0 1 1; 29 1 -1 -1)", raw >= 0, s1, s2, g1, g2, an, ar, ro_len,
             rr_len);
    check(raw >= 0 && s1 == 0 && s2 == 0 && g1 == 1 && g2 == 1 && an == 29 && ar == 1 && ro_len == -1 && rr_len == -1, msg);

    static const unsigned char nop[8] = { 1, 1, 1, 0, 0, 0, 0, 0 };
    send_opts(nop);
    long br = next();
    snprintf(msg, sizeof msg, "B: NOP NOP NOP END: recv %ld, IP_RECVOPTS %ld same %d, IP_RETOPTS %ld (1 24 1 16)", br, ro_len, eq(ro, nop, 8), rr_len);
    check(br == 1 && ro_len == 24 && eq(ro, nop, 8) && rr_len == 16, msg);

    static const unsigned char rrq[8] = { 7, 7, 4, 0, 0, 0, 0, 0 };
    static const unsigned char rra[8] = { 7, 7, 8, 127, 0, 0, 1, 0 };
    send_opts(rrq);
    long cr = next();
    snprintf(msg, sizeof msg, "C: record route: recv %ld, IP_RECVOPTS %ld %02x %02x %02x %02x, IP_RETOPTS %ld same %d (1 24 07 07 08 7f 24 1)", cr, ro_len, ro[0], ro[1], ro[2], ro[3],
             rr_len, eq(rr, rra, 8));
    check(cr == 1 && ro_len == 24 && eq(ro, rra, 8) && rr_len == 24 && eq(rr, rra, 8), msg);

    static const unsigned char full[8] = { 7, 3, 4, 0, 0, 0, 0, 0 };
    send_opts(full);
    long dr = next();
    snprintf(msg, sizeof msg, "D: full record route: recv %ld, IP_RECVOPTS %ld same %d, IP_RETOPTS %ld %02x %02x %02x %02x (1 24 1 20 07 03 04 00)", dr, ro_len, eq(ro, full, 8), rr_len, rr[0],
             rr[1], rr[2], rr[3]);
    check(dr == 1 && ro_len == 24 && eq(ro, full, 8) && rr_len == 20 && eq(rr, full, 4), msg);

    static const unsigned char ts[8] = { 0x44, 8, 5, 0, 0, 0, 0, 0 };
    send_opts(ts);
    long er = next();
    long when = now_ms();
    long stamp = (long)ro[4] << 24 | ro[5] << 16 | ro[6] << 8 | ro[7];
    long diff = when - stamp;
    if (diff < -43200000) diff += 86400000;
    if (diff > 43200000) diff -= 86400000;
    snprintf(msg, sizeof msg, "E: timestamp: recv %ld, IP_RECVOPTS %ld pointer %u, IP_RETOPTS %ld pointer %u; stamp %ld ms, clock %ld ms (1 24 9 24 9; within 1000)", er, ro_len, ro[2], rr_len,
             rr[2], stamp, when);
    check(er == 1 && ro_len == 24 && ro[0] == 0x44 && ro[2] == 9 && rr_len == 24 && rr[2] == 9 && diff >= -1000 && diff <= 1000, msg);

    static const unsigned char bad[8] = { 7, 2, 4, 0, 0, 0, 0, 0 };
    static const unsigned char lsrr[8] = { 0x83, 7, 4, 127, 0, 0, 1, 0 };
    send_opts(bad);
    long f1 = next();
    send_opts(lsrr);
    long f2 = next();
    snprintf(msg, sizeof msg, "F: malformed option %ld; loose source route %ld (-11 -11)", f1, f2);
    check(f1 == -11 && f2 == -11, msg);

    print(failures ? "hello464: FAIL\n" : "hello464: PASS\n");
    return failures ? 1 : 0;
}
